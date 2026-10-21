#!/usr/bin/env python3
"""Test separate R6 operator build inputs without Docker or binary execution.

Without arguments, run temporary synthetic regressions. To check released inputs:
  python3 test-operator-image-contract.py --dockerfile PATH --binary PATH

This is not image/archive or live mode acceptance. The Docker build context must
copy the verified binary under the filename zpr-web-dashboard.
Mode arguments are examples only; listener addresses are deployment configuration
and are not verified here.
"""

import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import struct
import sys
import tarfile
import tempfile
import unittest


DOCKERFILE_SHA256 = "3403a0ac9604b6077545155953f826641cab55b905eb1596724b88f19def0c6e"
BINARY_SHA256 = "f172476403cdf625e483374b317028b2acb5c1f6dfdc726261e5dad1d27fb6e7"
EXPECTED_IMAGE_ID = "sha256:45a7d5682fcd07613c7de7223a534e438fdac7f73ceedc7f9a05d2f2284aa848"
ENTRYPOINT = "/usr/local/bin/zpr-web-dashboard"
MODE_ARGUMENT_EXAMPLES = [
    ["-mode", "control-room"],
    ["-mode", "control-service"],
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def check_contract(dockerfile, binary, mode):
    instructions = []
    for line in dockerfile.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            instruction, _, value = line.partition(" ")
            if instruction.upper() != "LABEL":
                instructions.append((instruction.upper(), value.strip()))
    if instructions != [
        ("FROM", "scratch"),
        ("COPY", "zpr-web-dashboard " + ENTRYPOINT),
        ("USER", "1000:1000"),
        ("ENTRYPOINT", '["' + ENTRYPOINT + '"]'),
    ]:
        raise ValueError("separate operator Dockerfile contract mismatch")
    if stat.S_IMODE(mode) != 0o755:
        raise ValueError("operator binary must have mode 0755")
    if (len(binary) < 64 or binary[:7] != b"\x7fELF\x02\x01\x01"
            or struct.unpack_from("<H", binary, 18)[0] != 62):
        raise ValueError("operator binary must be ELF64 little-endian x86-64")
    offset = struct.unpack_from("<Q", binary, 32)[0]
    size, count = struct.unpack_from("<HH", binary, 54)
    if count == 0 or size < 56 or offset < 64 or offset + size * count > len(binary):
        raise ValueError("invalid ELF program header table")
    for index in range(count):
        header = offset + size * index
        kind = struct.unpack_from("<I", binary, header)[0]
        if kind in (2, 3):
            raise ValueError("scratch operator binary must have no dynamic segment/interpreter")


def check_released_inputs(dockerfile, binary):
    for path in (dockerfile, binary):
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"required input must be a regular non-symlink file: {path}")
    source, payload = dockerfile.read_bytes(), binary.read_bytes()
    if sha256(source) != DOCKERFILE_SHA256:
        raise ValueError("released Dockerfile SHA-256 mismatch")
    if sha256(payload) != BINARY_SHA256:
        raise ValueError("released binary SHA-256 mismatch")
    check_contract(source.decode("utf-8"), payload, binary.stat().st_mode)
    return {
        "dockerfile_sha256": sha256(source),
        "binary_sha256": sha256(payload),
        "copy_context_filename_required": "zpr-web-dashboard",
        "entrypoint": ENTRYPOINT,
        "mode_argument_examples": MODE_ARGUMENT_EXAMPLES,
        "expected_image_id_from_handoff": EXPECTED_IMAGE_ID,
        "image_identity_verified": False,
        "mode_execution_verified": False,
        "listen_address_verified": False,
    }


class OperatorImageContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dockerfile = (
            "FROM scratch\n"
            "COPY zpr-web-dashboard /usr/local/bin/zpr-web-dashboard\n"
            "USER 1000:1000\n"
            'ENTRYPOINT ["/usr/local/bin/zpr-web-dashboard"]\n'
        )
        self.binary = bytearray(120)
        self.binary[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<H", self.binary, 18, 62)
        struct.pack_into("<Q", self.binary, 32, 64)
        struct.pack_into("<HH", self.binary, 54, 56, 1)
        struct.pack_into("<I", self.binary, 64, 1)

    def test_separate_operator_contract_and_mode_argument_examples(self):
        check_contract(self.dockerfile, self.binary, 0o755)
        self.assertEqual(MODE_ARGUMENT_EXAMPLES[0], ["-mode", "control-room"])
        self.assertEqual(MODE_ARGUMENT_EXAMPLES[1], ["-mode", "control-service"])

    def test_rejects_component_image_path_and_fixed_mode(self):
        for source in (
            self.dockerfile.replace(ENTRYPOINT, "/app/bin/zpr-web-dashboard"),
            self.dockerfile.replace("COPY zpr-web-dashboard", "COPY missing-binary"),
            self.dockerfile.replace("1000:1000", "0:0"),
            self.dockerfile + 'CMD ["-mode", "simulator"]\n',
            self.dockerfile.replace("FROM scratch", "FROM zpr-multinode"),
        ):
            with self.subTest(source=source), self.assertRaises(ValueError):
                check_contract(source, self.binary, 0o755)

    def test_rejects_missing_nonexecutable_or_incompatible_binary(self):
        for payload, mode in ((b"", 0o755), (self.binary, 0o644),
                              (self.binary, 0o4755)):
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                check_contract(self.dockerfile, payload, mode)
        for offset, value in ((18, 183), (64, 3), (64, 2), (54, 0)):
            payload = bytearray(self.binary)
            struct.pack_into("<H", payload, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                check_contract(self.dockerfile, payload, 0o755)

    def test_released_input_check_rejects_missing_and_changed_inputs(self):
        dockerfile, binary = self.root / "Dockerfile", self.root / "zpr-web-dashboard"
        with self.assertRaisesRegex(ValueError, "regular non-symlink"):
            check_released_inputs(dockerfile, binary)
        dockerfile.write_text(self.dockerfile)
        binary.write_bytes(self.binary)
        binary.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "Dockerfile SHA-256"):
            check_released_inputs(dockerfile, binary)

    def test_pair_helper_identity_does_not_establish_operator_payload(self):
        spec = importlib.util.spec_from_file_location(
            "package_images", Path(__file__).with_name("package-demo-images.py"))
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        config = json.dumps({"os": "linux", "architecture": "amd64",
                             "config": {"Entrypoint": ["/app/bin/vs"]}}).encode()
        identity = "sha256:" + sha256(config)
        path = self.root / "synthetic-component.tar"
        reference = "synthetic-component:test"
        manifest = [{"Config": sha256(config) + ".json", "RepoTags": [reference]}]
        with tarfile.open(path, "w") as archive:
            for name, data in (("manifest.json", json.dumps(manifest).encode()),
                               (sha256(config) + ".json", config)):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        self.assertEqual(helper.docker_save_identity(path, reference), identity)
        self.assertNotEqual(identity, "sha256:" + BINARY_SHA256)
        with self.assertRaises(ValueError):
            check_contract("FROM synthetic-component\n", self.binary, 0o755)


if __name__ == "__main__":
    if "--dockerfile" in sys.argv or "--binary" in sys.argv:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--dockerfile", type=Path, required=True)
        parser.add_argument("--binary", type=Path, required=True)
        args = parser.parse_args()
        try:
            print(json.dumps(check_released_inputs(args.dockerfile, args.binary), indent=2))
        except (OSError, ValueError) as exc:
            parser.exit(1, f"operator build-input contract: {exc}\n")
    else:
        unittest.main()
