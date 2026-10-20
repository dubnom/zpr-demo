#!/usr/bin/env python3
"""Offline preflight for a locally supplied paired demo runtime package."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile


SCHEMA = "zpr.demo.runtime-package.v2"
STATUS = "demo-unqualified-runtime-package"
PLATFORM = "linux/amd64"
IMAGE_ID_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
RELEASE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
CHECKLIST = (
    (
        "Clean Ubuntu host",
        "Obtain explicit approval for the designated disposable Ubuntu 26.04.1 "
        "LTS x86-64 host, maintenance window, rollback/console access, Docker "
        "and TUN permissions. Run the separately authorized read-only host "
        "preflight; this offline tool did not probe the host.",
    ),
    (
        "One-machine provisioning",
        "Verify the approved artifact hashes through an independently trusted "
        "channel, install this exact matched pair into a new release directory, "
        "and start from new persistent state. Record package/image IDs, state "
        "ownership and modes, and the state marker without displaying "
        "credential contents.",
    ),
    (
        "Reboot and restart persistence",
        "First record identity/configuration fingerprints, active policy, Redis "
        "state and operator draft revision. After separately approved service "
        "restart and OS reboot, verify the same values; do not reinitialize or "
        "replace state to recover a failed check.",
    ),
    (
        "World supervisor and service lifecycle",
        "Confirm with the owners the exact boot/supervisor interface and whether "
        "startup is automatic or operator-invoked. Exercise ZPR, Simulator and "
        "world start/status/stop independently, inspect exit status and logs, "
        "and verify the approved dependency ordering and clean shutdown.",
    ),
    (
        "Identity, policy and configuration invariants",
        "Verify the approved identities/configuration remain stable, required "
        "nodes synchronize, peer links are Active, Alice-to-web0 HTTP passes "
        "the readiness gate, and the Simulator scenario proves allowed traffic "
        "and explicit policy denial. Recheck active policy and draft revisions "
        "after restart; retain redacted evidence only.",
    ),
)


def fail(message):
    raise ValueError(message)


def require_regular_file(path, description):
    if path.is_symlink() or not path.is_file():
        fail(f"{description} must be a regular, non-symlink file: {path}")


def verify_sidecar(archive_path, sidecar_path):
    require_regular_file(archive_path, "archive")
    require_regular_file(sidecar_path, "SHA-256 sidecar")
    expected_sidecar = archive_path.with_name(archive_path.name + ".sha256")
    if sidecar_path.absolute() != expected_sidecar.absolute():
        fail(
            f"sidecar must be the adjacent verifier sidecar "
            f"{expected_sidecar.name}: {sidecar_path}"
        )
    try:
        sidecar = sidecar_path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as exc:
        fail(f"cannot read SHA-256 sidecar {sidecar_path}: {exc}")
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", sidecar)
    if not match or match.group(2) != archive_path.name:
        fail(f"invalid SHA-256 sidecar for {archive_path}")
    digest = hashlib.sha256()
    try:
        with archive_path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        fail(f"cannot read archive {archive_path}: {exc}")
    actual = digest.hexdigest()
    if actual != match.group(1):
        fail(f"archive SHA-256 mismatch: {archive_path}")
    return actual


def read_manifest(archive_path):
    try:
        with tarfile.open(archive_path, "r:") as archive:
            members = [member for member in archive.getmembers() if member.name == "manifest.json"]
            if len(members) != 1 or not members[0].isfile():
                fail(f"archive must contain one regular manifest.json: {archive_path}")
            manifest_file = archive.extractfile(members[0])
            if manifest_file is None:
                fail(f"cannot read manifest.json from {archive_path}")
            data = manifest_file.read(1024 * 1024 + 1)
    except (OSError, tarfile.TarError) as exc:
        fail(f"cannot inspect package archive {archive_path}: {exc}")
    if len(data) > 1024 * 1024:
        fail(f"manifest.json exceeds 1 MiB: {archive_path}")
    try:
        manifest = json.loads(data)
    except (json.JSONDecodeError, UnicodeError) as exc:
        fail(f"invalid manifest.json in {archive_path}: {exc}")
    if not isinstance(manifest, dict):
        fail(f"manifest.json must contain an object: {archive_path}")
    return manifest


def validate_runtime_manifest(manifest, package_id, peer_package_id, expected_release, path):
    if manifest.get("schema") != SCHEMA or manifest.get("status") != STATUS:
        fail(f"package is not a v2 runtime package: {path}")
    if manifest.get("package_id") != package_id:
        fail(f"expected {package_id} package: {path}")
    if manifest.get("release_id") != expected_release:
        fail(f"package release ID does not match requested release {expected_release}: {path}")
    if manifest.get("platform") != PLATFORM:
        fail(f"package must target {PLATFORM}: {path}")
    if manifest.get("required_peer_package_id") != peer_package_id:
        fail(f"{package_id} package has an invalid paired package ID: {path}")
    component = manifest.get("component")
    if not isinstance(component, dict) or component.get("id") != package_id:
        fail(f"{package_id} package has invalid component metadata: {path}")
    for field in ("image_id", "docker_image_id"):
        value = component.get(field)
        if not isinstance(value, str) or not IMAGE_ID_PATTERN.fullmatch(value):
            fail(f"{package_id} package has an invalid {field}: {path}")
    return component


def run_existing_verifier(zpr_archive, simulator_archive):
    verifier = Path(__file__).with_name("package-demo-images.py")
    if verifier.is_symlink() or not verifier.is_file():
        fail(f"existing package verifier is unavailable or unsafe: {verifier}")
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(verifier),
                "verify",
                str(zpr_archive),
                str(simulator_archive),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
    except OSError as exc:
        fail(f"cannot run the local package verifier: {exc}")
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "verification failed"
        fail(f"existing package verifier rejected the pair: {detail}")


def print_report(zpr_archive, simulator_archive, release_id, zpr_hash, simulator_hash,
                 zpr_manifest, simulator_manifest, stdout):
    zpr_component = zpr_manifest["component"]
    simulator_component = simulator_manifest["component"]
    print("OFFLINE DEMO ARTIFACT PREFLIGHT PASSED", file=stdout)
    print("This is not clean-host, installation, runtime, reboot, or release acceptance.", file=stdout)
    print("No host was probed; no Docker command, network access, install, service start,", file=stdout)
    print("credential operation, reboot, or privileged operation was performed.", file=stdout)
    print("", file=stdout)
    print(f"Expected release ID: {release_id}", file=stdout)
    print(f"Platform: {PLATFORM}", file=stdout)
    print(f"ZPR archive: {zpr_archive}", file=stdout)
    print(f"  SHA-256: {zpr_hash}", file=stdout)
    print(f"  ZPR image reference: {zpr_component['image_reference']}", file=stdout)
    print(f"  ZPR image ID: {zpr_component['image_id']}", file=stdout)
    print(f"  ZPR Docker image ID: {zpr_component['docker_image_id']}", file=stdout)
    print(f"Simulator archive: {simulator_archive}", file=stdout)
    print(f"  SHA-256: {simulator_hash}", file=stdout)
    print(f"  Simulator image reference: {simulator_component['image_reference']}", file=stdout)
    print(f"  Simulator image ID: {simulator_component['image_id']}", file=stdout)
    print(f"  Simulator Docker image ID: {simulator_component['docker_image_id']}", file=stdout)
    print("", file=stdout)
    print("Ordered human acceptance checklist (not executed):", file=stdout)
    for index, (title, instruction) in enumerate(CHECKLIST, start=1):
        print(f"{index}. {title}: {instruction}", file=stdout)


def preflight(zpr_archive, zpr_sidecar, simulator_archive, simulator_sidecar,
              release_id, stdout=sys.stdout, verifier=run_existing_verifier):
    if not RELEASE_ID_PATTERN.fullmatch(release_id):
        fail("expected release ID is invalid")
    zpr_archive = Path(zpr_archive)
    zpr_sidecar = Path(zpr_sidecar)
    simulator_archive = Path(simulator_archive)
    simulator_sidecar = Path(simulator_sidecar)

    zpr_hash = verify_sidecar(zpr_archive, zpr_sidecar)
    simulator_hash = verify_sidecar(simulator_archive, simulator_sidecar)
    verifier(zpr_archive, simulator_archive)

    zpr_manifest = read_manifest(zpr_archive)
    simulator_manifest = read_manifest(simulator_archive)
    zpr_component = validate_runtime_manifest(
        zpr_manifest, "zpr-demo-image", "simulator-image", release_id, zpr_archive
    )
    simulator_component = validate_runtime_manifest(
        simulator_manifest, "simulator-image", "zpr-demo-image", release_id, simulator_archive
    )
    if zpr_manifest["platform"] != simulator_manifest["platform"]:
        fail("paired packages have different platform identities")
    if zpr_component["image_id"] != simulator_manifest.get("peer_image_id"):
        fail("ZPR package does not identify the paired Simulator image")
    if simulator_component["image_id"] != zpr_manifest.get("peer_image_id"):
        fail("Simulator package does not identify the paired ZPR image")
    if zpr_component["docker_image_id"] != simulator_manifest.get("peer_docker_image_id"):
        fail("ZPR package does not identify the paired Simulator Docker image")
    if simulator_component["docker_image_id"] != zpr_manifest.get("peer_docker_image_id"):
        fail("Simulator package does not identify the paired ZPR Docker image")
    if not isinstance(zpr_component.get("image_reference"), str) or not isinstance(
        simulator_component.get("image_reference"), str
    ):
        fail("paired packages must declare image references")

    print_report(
        zpr_archive,
        simulator_archive,
        release_id,
        zpr_hash,
        simulator_hash,
        zpr_manifest,
        simulator_manifest,
        stdout,
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-id", required=True, help="expected paired package release ID")
    parser.add_argument("--zpr-archive", required=True, help="local ZPR runtime archive")
    parser.add_argument("--zpr-sha256", required=True, help="adjacent ZPR archive .sha256 sidecar")
    parser.add_argument("--simulator-archive", required=True, help="local Simulator runtime archive")
    parser.add_argument(
        "--simulator-sha256", required=True, help="adjacent Simulator archive .sha256 sidecar"
    )
    args = parser.parse_args(argv)
    try:
        preflight(
            args.zpr_archive,
            args.zpr_sha256,
            args.simulator_archive,
            args.simulator_sha256,
            args.release_id,
        )
    except (OSError, ValueError) as exc:
        print(f"preflight-demo-acceptance: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
