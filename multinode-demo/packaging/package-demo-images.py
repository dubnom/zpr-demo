#!/usr/bin/env python3
"""Build, verify, or load a paired, image-only ZPR demo candidate."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


SCHEMA = "zpr.demo.image-package.v1"
PLATFORM = "linux/amd64"
PACKAGES = (
    ("zpr-demo", "zpr-demo-image"),
    ("simulator", "simulator-image"),
)


def fail(message):
    raise ValueError(message)


def sha256_stream(stream):
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = stream.read(1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        size += len(chunk)
    return digest.hexdigest(), size


def sha256_file(path):
    with path.open("rb") as stream:
        return sha256_stream(stream)


def run_docker(*args):
    try:
        return subprocess.run(
            ["docker", *args], check=True, text=True, capture_output=True
        ).stdout
    except FileNotFoundError as exc:
        raise ValueError("Docker CLI is required") from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() or exc.stdout.strip()
        raise ValueError(f"docker {' '.join(args)} failed: {detail}") from exc


def inspect_image(reference):
    try:
        result = json.loads(run_docker("image", "inspect", reference))
        if not isinstance(result, list) or len(result) != 1:
            fail(f"Docker returned unexpected metadata for image {reference}")
        image = result[0]
        image_id = image.get("Id", "")
        if image.get("Os") + "/" + image.get("Architecture") != PLATFORM:
            fail(f"image {reference} must be {PLATFORM}")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
            fail(f"image {reference} has no valid immutable Docker image ID")
        return image_id
    except (json.JSONDecodeError, TypeError, AttributeError) as exc:
        raise ValueError(f"could not inspect image {reference}: {exc}") from exc


def safe_tar_member(member):
    if "\\" in member.name:
        fail(f"unsafe archive path: {member.name!r}")
    raw_parts = member.name.split("/")
    if member.isdir() and raw_parts[-1] == "":
        raw_parts.pop()
    path = PurePosixPath(member.name)
    if (path.is_absolute() or not path.parts
            or any(part in ("", ".", "..") for part in raw_parts)):
        fail(f"unsafe archive path: {member.name!r}")
    if not (member.isfile() or member.isdir()):
        fail(f"archive contains a link or unsupported file: {member.name!r}")


def docker_save_identity(image_path, expected_reference):
    try:
        with tarfile.open(image_path, "r:*") as image_tar:
            members = image_tar.getmembers()
            seen = set()
            for member in members:
                safe_tar_member(member)
                if member.name in seen:
                    fail(f"Docker image archive repeats path {member.name!r}")
                seen.add(member.name)
            manifest_member = image_tar.getmember("manifest.json")
            manifest_file = image_tar.extractfile(manifest_member)
            if manifest_file is None:
                fail("Docker image archive has no readable manifest.json")
            entries = json.load(manifest_file)
            if not isinstance(entries, list) or len(entries) != 1:
                fail("Docker image archive must contain exactly one image")
            if not isinstance(entries[0], dict):
                fail("Docker image archive manifest entry is invalid")
            matches = [
                entry
                for entry in entries
                if entry.get("RepoTags") == [expected_reference]
            ]
            if len(matches) != 1:
                fail(f"Docker image archive does not contain exactly {expected_reference}")
            config_name = matches[0].get("Config", "")
            if not isinstance(config_name, str):
                fail("Docker image archive config path is invalid")
            config_member = image_tar.getmember(config_name)
            config_file = image_tar.extractfile(config_member)
            if config_file is None:
                fail("Docker image archive has no readable image config")
            config_bytes = config_file.read()
            config_id = "sha256:" + hashlib.sha256(config_bytes).hexdigest()
            config_basename = PurePosixPath(config_name).name
            config_digest = config_id.removeprefix("sha256:")
            if config_basename not in {config_digest, config_digest + ".json"}:
                fail("Docker image archive config path does not match its content digest")
            config = json.loads(config_bytes)
            if not isinstance(config, dict):
                fail("Docker image config must be a JSON object")
            if config.get("os") != "linux" or config.get("architecture") != "amd64":
                fail(f"Docker image config must target {PLATFORM}")
            return config_id
    except (tarfile.TarError, KeyError, json.JSONDecodeError, TypeError) as exc:
        raise ValueError(f"invalid Docker image archive {image_path}: {exc}") from exc


def create_archive(path, package_id, peer_id, release_id, image_reference,
                   image_id, docker_image_id, image_path, peer_image_id,
                   peer_docker_image_id):
    image_hash, image_size = sha256_file(image_path)
    manifest = {
        "schema": SCHEMA,
        "status": "demo-unqualified-image-only",
        "release_id": release_id,
        "platform": PLATFORM,
        "package_id": package_id,
        "required_peer_package_id": peer_id,
        "peer_image_id": peer_image_id,
        "component": {
            "id": package_id,
            "image_reference": image_reference,
            "image_id": image_id,
            "docker_image_id": docker_image_id,
        },
        "peer_docker_image_id": peer_docker_image_id,
        "payloads": [{"path": "image.tar", "sha256": image_hash, "size_bytes": image_size}],
    }
    manifest_path = path.parent / (package_id + "-manifest.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    try:
        with tarfile.open(path, "w") as archive:
            archive.add(manifest_path, arcname="manifest.json", recursive=False)
            archive.add(image_path, arcname="image.tar", recursive=False)
    finally:
        manifest_path.unlink(missing_ok=True)
    archive_hash, _ = sha256_file(path)
    path.with_name(path.name + ".sha256").write_text(
        f"{archive_hash}  {path.name}\n", encoding="ascii"
    )


def load_package(path, expected_package_id):
    path = Path(path)
    try:
        if path.is_symlink() or not path.is_file():
            fail(f"package is not a regular file: {path}")
        sidecar = path.with_name(path.name + ".sha256")
        if sidecar.is_symlink() or not sidecar.is_file():
            fail(f"missing regular checksum sidecar: {sidecar}")
        sidecar_text = sidecar.read_text(encoding="ascii").strip()
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", sidecar_text)
        if not match or match.group(2) != path.name:
            fail(f"invalid checksum sidecar for {path}")
        actual_archive_hash, _ = sha256_file(path)
        if actual_archive_hash != match.group(1):
            fail(f"archive checksum mismatch: {path}")

        with tarfile.open(path, "r:") as archive:
            members = archive.getmembers()
            for member in members:
                safe_tar_member(member)
            if len(members) != 2 or {member.name for member in members} != {
                "manifest.json", "image.tar"
            }:
                fail(f"{path} must contain only manifest.json and image.tar")
            manifest_file = archive.extractfile("manifest.json")
            image_file = archive.extractfile("image.tar")
            if manifest_file is None or image_file is None:
                fail(f"{path} is missing a required package file")
            manifest = json.load(manifest_file)
            if not isinstance(manifest, dict):
                fail(f"invalid package manifest in {path}")
            payload_hash, payload_size = sha256_stream(image_file)
            if manifest.get("schema") != SCHEMA:
                fail(f"unsupported package schema in {path}")
            if manifest.get("status") != "demo-unqualified-image-only":
                fail(f"unexpected package status in {path}")
            if manifest.get("package_id") != expected_package_id:
                fail(f"expected {expected_package_id} package, got {manifest.get('package_id')!r}")
            if manifest.get("platform") != PLATFORM:
                fail(f"package {path} must target {PLATFORM}")
            payloads = manifest.get("payloads")
            if not isinstance(payloads, list) or len(payloads) != 1:
                fail(f"package {path} must declare exactly one payload")
            payload = payloads[0]
            if (not isinstance(payload, dict)
                    or payload.get("path") != "image.tar"
                    or payload.get("sha256") != payload_hash
                    or payload.get("size_bytes") != payload_size):
                fail(f"image payload checksum or size mismatch: {path}")
            component = manifest.get("component")
            if not isinstance(component, dict):
                fail(f"invalid component metadata in {path}")
            image_id = component.get("image_id", "")
            reference = component.get("image_reference", "")
            if component.get("id") != expected_package_id:
                fail(f"invalid component ID in {path}")
            if not isinstance(image_id, str) or not re.fullmatch(
                r"sha256:[0-9a-f]{64}", image_id
            ):
                fail(f"invalid immutable image ID in {path}")
            docker_image_id = component.get("docker_image_id")
            if (not isinstance(docker_image_id, str)
                    or not re.fullmatch(r"sha256:[0-9a-f]{64}", docker_image_id)):
                fail(f"invalid Docker image inspect ID in {path}")
            if not isinstance(reference, str) or not reference:
                fail(f"missing image reference in {path}")
            release_id = manifest.get("release_id")
            if (not isinstance(release_id, str)
                    or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", release_id)):
                fail(f"invalid release ID in {path}")
            if manifest.get("required_peer_package_id") not in {
                "zpr-demo-image", "simulator-image"
            }:
                fail(f"invalid peer package ID in {path}")
            peer_image_id = manifest.get("peer_image_id")
            if (not isinstance(peer_image_id, str)
                    or not re.fullmatch(r"sha256:[0-9a-f]{64}", peer_image_id)):
                fail(f"invalid peer image ID in {path}")
            peer_docker_image_id = manifest.get("peer_docker_image_id")
            if (not isinstance(peer_docker_image_id, str)
                    or not re.fullmatch(r"sha256:[0-9a-f]{64}", peer_docker_image_id)):
                fail(f"invalid peer Docker image ID in {path}")
            image_tmp = tempfile.NamedTemporaryFile(prefix="zpr-demo-image-", delete=False)
            try:
                with image_tmp:
                    image_file.seek(0)
                    shutil.copyfileobj(image_file, image_tmp)
                if docker_save_identity(Path(image_tmp.name), reference) != image_id:
                    fail("Docker image config digest does not match the package image ID")
            finally:
                Path(image_tmp.name).unlink(missing_ok=True)
            return manifest
    except (OSError, tarfile.TarError, json.JSONDecodeError, UnicodeError) as exc:
        raise ValueError(f"could not verify package {path}: {exc}") from exc


def verify_pair(zpr_path, simulator_path):
    zpr, simulator = (
        load_package(zpr_path, "zpr-demo-image"),
        load_package(simulator_path, "simulator-image"),
    )
    if zpr.get("release_id") != simulator.get("release_id"):
        fail("ZPR and Simulator packages have different release IDs")
    if zpr.get("required_peer_package_id") != "simulator-image":
        fail("ZPR package does not require the Simulator package")
    if simulator.get("required_peer_package_id") != "zpr-demo-image":
        fail("Simulator package does not require the ZPR package")
    if zpr.get("peer_image_id") != simulator["component"]["image_id"]:
        fail("ZPR package requires a different Simulator image")
    if simulator.get("peer_image_id") != zpr["component"]["image_id"]:
        fail("Simulator package requires a different ZPR image")
    if zpr.get("peer_docker_image_id") != simulator["component"]["docker_image_id"]:
        fail("ZPR package requires a different Docker Simulator image ID")
    if simulator.get("peer_docker_image_id") != zpr["component"]["docker_image_id"]:
        fail("Simulator package requires a different Docker ZPR image ID")
    return zpr, simulator


def build(args):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", args.release_id):
        fail("release ID must be 1-80 characters of letters, digits, dot, underscore, or hyphen")
    output = Path(args.output_dir).resolve(strict=True)
    if not output.is_dir():
        fail("output directory must already exist")
    if args.zpr_image == args.simulator_image:
        fail("ZPR and Simulator image references must be different")
    references = (args.zpr_image, args.simulator_image)
    docker_image_ids = tuple(inspect_image(reference) for reference in references)

    names = (
        f"zpr-demo-{args.release_id}.tar",
        f"simulator-{args.release_id}.tar",
    )
    sidecars = tuple(name + ".sha256" for name in names)
    destinations = tuple(output / name for name in names + sidecars)
    if any(path.exists() or path.is_symlink() for path in destinations):
        fail("refusing to overwrite any existing release archive or checksum")

    with tempfile.TemporaryDirectory(prefix=".zpr-demo-package-", dir=output) as temp:
        stage = Path(temp)
        image_paths = (stage / "zpr-image.tar", stage / "simulator-image.tar")
        for image_path, reference in zip(image_paths, references):
            run_docker("image", "save", "--output", str(image_path), reference)
        image_ids = tuple(
            docker_save_identity(image_path, reference)
            for image_path, reference in zip(image_paths, references)
        )
        create_archive(stage / names[0], "zpr-demo-image", "simulator-image",
                       args.release_id, references[0], image_ids[0], docker_image_ids[0],
                       image_paths[0], image_ids[1], docker_image_ids[1])
        create_archive(stage / names[1], "simulator-image", "zpr-demo-image",
                       args.release_id, references[1], image_ids[1], docker_image_ids[1],
                       image_paths[1], image_ids[0], docker_image_ids[0])
        verify_pair(stage / names[0], stage / names[1])
        published = []
        try:
            for name in names + sidecars:
                destination = output / name
                os.link(stage / name, destination)
                published.append(destination)
        except OSError:
            for destination in published:
                destination.unlink(missing_ok=True)
            raise
    print(f"Created image-only demo candidate pair for release {args.release_id}")
    for path in destinations:
        print(path)


def verify(args):
    zpr, simulator = verify_pair(args.zpr_archive, args.simulator_archive)
    print(f"Verified image-only pair for release {zpr['release_id']}")
    print(f"  ZPR image:       {zpr['component']['image_id']}")
    print(f"  Simulator image: {simulator['component']['image_id']}")
    print("  Status:          demo-unqualified-image-only")


def install(args):
    zpr, simulator = verify_pair(args.zpr_archive, args.simulator_archive)
    for archive_path, manifest in (
        (args.zpr_archive, zpr),
        (args.simulator_archive, simulator),
    ):
        with tempfile.NamedTemporaryFile(prefix="zpr-demo-install-", delete=False) as temp:
            image_path = Path(temp.name)
            with tarfile.open(archive_path, "r:") as archive:
                image_file = archive.extractfile("image.tar")
                if image_file is None:
                    fail(f"missing image payload in {archive_path}")
                shutil.copyfileobj(image_file, temp)
        try:
            result = subprocess.run(
                ["docker", "load", "--input", str(image_path)],
                check=False, text=True, capture_output=True,
            )
            if result.returncode != 0:
                detail = result.stderr.strip()
                fail(f"docker load failed for {archive_path}: {detail}")
        finally:
            image_path.unlink(missing_ok=True)
        reference = manifest["component"]["image_reference"]
        inspect_image(reference)
        with tempfile.NamedTemporaryFile(prefix="zpr-demo-loaded-", delete=False) as saved:
            saved_path = Path(saved.name)
        try:
            run_docker("image", "save", "--output", str(saved_path), reference)
            if docker_save_identity(saved_path, reference) != manifest["component"]["image_id"]:
                fail(f"loaded image config digest mismatch for {archive_path}")
        finally:
            saved_path.unlink(missing_ok=True)
    print(f"Loaded verified images for demo release {zpr['release_id']}")
    print("No containers were started; these are image archives, not complete installers.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="build two image-only archives")
    build_parser.add_argument("--release-id", required=True)
    build_parser.add_argument("--output-dir", required=True)
    build_parser.add_argument("--zpr-image", default="zpr-multinode:demo-candidate-20261018")
    build_parser.add_argument("--simulator-image", default="zpr-simulator:demo-candidate-20261018")
    build_parser.set_defaults(func=build)
    verify_parser = commands.add_parser("verify", help="verify exact package pair before loading")
    verify_parser.add_argument("zpr_archive")
    verify_parser.add_argument("simulator_archive")
    verify_parser.set_defaults(func=verify)
    install_parser = commands.add_parser("install", help="verify then load both Docker images")
    install_parser.add_argument("zpr_archive")
    install_parser.add_argument("simulator_archive")
    install_parser.set_defaults(func=install)
    args = parser.parse_args()
    try:
        args.func(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
