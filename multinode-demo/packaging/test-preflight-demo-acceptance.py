#!/usr/bin/env python3
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import Mock
import importlib.util


SCRIPT = Path(__file__).with_name("preflight-demo-acceptance.py")
SPEC = importlib.util.spec_from_file_location("preflight_demo_acceptance", SCRIPT)
PREFLIGHT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREFLIGHT)

RELEASE_ID = "offline-test-release"
ZPR_ID = "sha256:" + "a" * 64
SIMULATOR_ID = "sha256:" + "b" * 64
ZPR_DOCKER_ID = "sha256:" + "c" * 64
SIMULATOR_DOCKER_ID = "sha256:" + "d" * 64


def package_manifest(package_id, peer_package_id, image_id, docker_image_id,
                     peer_image_id, peer_docker_image_id, release_id=RELEASE_ID):
    return {
        "schema": PREFLIGHT.SCHEMA,
        "status": PREFLIGHT.STATUS,
        "release_id": release_id,
        "platform": PREFLIGHT.PLATFORM,
        "package_id": package_id,
        "required_peer_package_id": peer_package_id,
        "peer_image_id": peer_image_id,
        "peer_docker_image_id": peer_docker_image_id,
        "component": {
            "id": package_id,
            "image_reference": package_id + ":offline-candidate",
            "image_id": image_id,
            "docker_image_id": docker_image_id,
        },
    }


class PreflightDemoAcceptanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.zpr = self.write_package(
            "zpr-demo-test.tar",
            package_manifest(
                "zpr-demo-image", "simulator-image", ZPR_ID, ZPR_DOCKER_ID,
                SIMULATOR_ID, SIMULATOR_DOCKER_ID,
            ),
        )
        self.simulator = self.write_package(
            "simulator-test.tar",
            package_manifest(
                "simulator-image", "zpr-demo-image", SIMULATOR_ID,
                SIMULATOR_DOCKER_ID, ZPR_ID, ZPR_DOCKER_ID,
            ),
        )
        self.verifier = Mock()

    def tearDown(self):
        self.temp.cleanup()

    def write_package(self, name, manifest):
        path = self.root / name
        with tarfile.open(path, "w") as archive:
            manifest_bytes = json.dumps(manifest, sort_keys=True).encode("utf-8")
            manifest_info = tarfile.TarInfo("manifest.json")
            manifest_info.size = len(manifest_bytes)
            archive.addfile(manifest_info, io.BytesIO(manifest_bytes))
            for member_name, payload in (
                ("image.tar", b"synthetic harmless image payload"),
                ("runtime.tar", b"synthetic harmless runtime payload"),
            ):
                info = tarfile.TarInfo(member_name)
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        sidecar = path.with_name(path.name + ".sha256")
        sidecar.write_text(f"{digest}  {path.name}\n", encoding="ascii")
        return path

    def invoke(self, release_id=RELEASE_ID):
        output = io.StringIO()
        PREFLIGHT.preflight(
            self.zpr,
            self.zpr.with_name(self.zpr.name + ".sha256"),
            self.simulator,
            self.simulator.with_name(self.simulator.name + ".sha256"),
            release_id,
            stdout=output,
            verifier=self.verifier,
        )
        return output.getvalue()

    def test_valid_pair_prints_artifact_identity_and_ordered_checklist(self):
        output = self.invoke()
        self.verifier.assert_called_once_with(self.zpr, self.simulator)
        self.assertIn("OFFLINE DEMO ARTIFACT PREFLIGHT PASSED", output)
        self.assertIn("Expected release ID: " + RELEASE_ID, output)
        self.assertIn(hashlib.sha256(self.zpr.read_bytes()).hexdigest(), output)
        self.assertIn(hashlib.sha256(self.simulator.read_bytes()).hexdigest(), output)
        self.assertIn("ZPR image ID: " + ZPR_ID, output)
        self.assertIn("Simulator image ID: " + SIMULATOR_ID, output)
        self.assertIn("This is not clean-host, installation, runtime, reboot, or release acceptance.", output)
        self.assertLess(output.index("1. Clean Ubuntu host:"), output.index("2. One-machine provisioning:"))
        self.assertLess(output.index("2. One-machine provisioning:"), output.index("3. Reboot and restart persistence:"))
        self.assertLess(output.index("3. Reboot and restart persistence:"), output.index("4. World supervisor and service lifecycle:"))
        self.assertLess(output.index("4. World supervisor and service lifecycle:"), output.index("5. Identity, policy and configuration invariants:"))

    def test_rejects_sidecar_mismatch_before_verifier(self):
        self.zpr.with_name(self.zpr.name + ".sha256").write_text(
            "0" * 64 + "  " + self.zpr.name + "\n", encoding="ascii"
        )
        with self.assertRaisesRegex(ValueError, "archive SHA-256 mismatch"):
            self.invoke()
        self.verifier.assert_not_called()

    def test_requires_requested_release(self):
        with self.assertRaisesRegex(ValueError, "does not match requested release"):
            self.invoke("different-release")
        self.verifier.assert_called_once_with(self.zpr, self.simulator)

    def test_rejects_pair_image_identity_mismatch(self):
        bad_simulator = package_manifest(
            "simulator-image", "zpr-demo-image", SIMULATOR_ID,
            SIMULATOR_DOCKER_ID, "sha256:" + "e" * 64, ZPR_DOCKER_ID,
        )
        self.simulator = self.write_package("simulator-test.tar", bad_simulator)
        with self.assertRaisesRegex(ValueError, "paired Simulator image"):
            self.invoke()

    def test_rejects_non_runtime_or_wrong_platform_manifest(self):
        wrong_platform = package_manifest(
            "zpr-demo-image", "simulator-image", ZPR_ID, ZPR_DOCKER_ID,
            SIMULATOR_ID, SIMULATOR_DOCKER_ID,
        )
        wrong_platform["platform"] = "linux/arm64"
        self.zpr = self.write_package("zpr-demo-test.tar", wrong_platform)
        with self.assertRaisesRegex(ValueError, "must target linux/amd64"):
            self.invoke()


if __name__ == "__main__":
    unittest.main()
