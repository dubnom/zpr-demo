#!/usr/bin/env python3
"""Build, verify, or load a paired ZPR demo runtime package."""

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


SCHEMA = "zpr.demo.runtime-package.v2"
LEGACY_SCHEMA = "zpr.demo.image-package.v1"
PLATFORM = "linux/amd64"
PACKAGES = (
    ("zpr-demo", "zpr-demo-image"),
    ("simulator", "simulator-image"),
)


def fail(message):
    raise ValueError(message)


def reject_local_runtime_source(path, docs_root):
    local_runtime = (Path(docs_root) / ".local-runtime").resolve()
    resolved_path = Path(path).resolve()
    try:
        resolved_path.relative_to(local_runtime)
    except ValueError:
        return
    fail(f"package source path must not resolve inside .local-runtime: {path}")


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
    if not isinstance(reference, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,254}", reference
    ):
        fail(f"invalid Docker image reference: {reference!r}")
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


def safe_runtime_asset_name(name):
    if "\\" in name:
        fail(f"unsafe runtime asset path: {name!r}")
    path = PurePosixPath(name)
    if (path.is_absolute() or not path.parts
            or any(part in ("", ".", "..") for part in name.split("/"))):
        fail(f"unsafe runtime asset path: {name!r}")
    basename = path.name.lower()
    if (not name.startswith("runtime/")
            or basename.startswith(".env")
            or basename.endswith(".env")
            or basename in {
                "credentials", "secrets", "id_rsa", "id_ed25519", "id_ecdsa"
            }
            or basename.endswith((".key", ".pem", ".p12", ".pfx", ".jks"))
            or any(token in basename for token in ("private", "secret", "credential"))):
        fail(f"runtime assets must not contain credentials or private keys: {name!r}")


def create_runtime_archive(source_dir, archive_path, extra_files=()):
    source_dir = Path(source_dir)
    if source_dir.is_symlink() or not source_dir.is_dir():
        fail(f"runtime asset directory must be a regular directory: {source_dir}")
    files = []
    for root, directories, names in os.walk(source_dir, followlinks=False):
        root_path = Path(root)
        for name in directories + names:
            if name.startswith("test-"):
                continue
            path = root_path / name
            if path.is_symlink():
                fail(f"runtime assets must not contain symlinks: {path}")
            if path.is_dir():
                continue
            if not path.is_file():
                fail(f"runtime assets must be regular files: {path}")
            relative = path.relative_to(source_dir).as_posix()
            safe_runtime_asset_name("runtime/" + relative)
            files.append((path, relative))
    for source, relative in extra_files:
        source = Path(source)
        if source.is_symlink() or not source.is_file():
            fail(f"extra runtime asset must be a regular file: {source}")
        safe_runtime_asset_name("runtime/" + relative)
        if any(existing == relative for _, existing in files):
            fail(f"runtime asset path is repeated: {relative}")
        files.append((source, relative))
    if not files:
        fail(f"runtime asset directory is empty: {source_dir}")
    with tarfile.open(archive_path, "w") as archive:
        for path, relative in sorted(files, key=lambda item: item[1]):
            archive.add(path, arcname="runtime/" + relative, recursive=False)


def verify_runtime_archive(runtime_path):
    try:
        with tarfile.open(runtime_path, "r:") as archive:
            members = archive.getmembers()
            seen = set()
            files = 0
            for member in members:
                safe_tar_member(member)
                safe_runtime_asset_name(member.name)
                if member.name in seen:
                    fail(f"runtime archive repeats path {member.name!r}")
                seen.add(member.name)
                if member.mode & 0o6022:
                    fail(f"runtime asset has unsafe permissions: {member.name!r}")
                if member.isfile():
                    files += 1
            if files == 0:
                fail("runtime archive contains no files")
    except tarfile.TarError as exc:
        raise ValueError(f"invalid runtime archive {runtime_path}: {exc}") from exc


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
                   image_id, docker_image_id, image_path, runtime_path,
                   peer_image_id, peer_docker_image_id):
    image_hash, image_size = sha256_file(image_path)
    runtime_hash, runtime_size = sha256_file(runtime_path)
    manifest = {
        "schema": SCHEMA,
        "status": "demo-unqualified-runtime-package",
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
        "payloads": [
            {"path": "image.tar", "sha256": image_hash, "size_bytes": image_size},
            {"path": "runtime.tar", "sha256": runtime_hash, "size_bytes": runtime_size},
        ],
    }
    manifest_path = path.parent / (package_id + "-manifest.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    try:
        with tarfile.open(path, "w") as archive:
            archive.add(manifest_path, arcname="manifest.json", recursive=False)
            archive.add(image_path, arcname="image.tar", recursive=False)
            archive.add(runtime_path, arcname="runtime.tar", recursive=False)
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
            member_names = {member.name for member in members}
            if "manifest.json" not in member_names or "image.tar" not in member_names:
                fail(f"{path} is missing manifest.json or image.tar")
            manifest_file = archive.extractfile("manifest.json")
            image_file = archive.extractfile("image.tar")
            if manifest_file is None or image_file is None:
                fail(f"{path} is missing a required package file")
            manifest = json.load(manifest_file)
            if not isinstance(manifest, dict):
                fail(f"invalid package manifest in {path}")
            image_hash, image_size = sha256_stream(image_file)
            package_status = manifest.get("status")
            schema = manifest.get("schema")
            if (schema, package_status) == (
                SCHEMA, "demo-unqualified-runtime-package"
            ):
                expected_members = {"manifest.json", "image.tar", "runtime.tar"}
            elif (schema, package_status) == (
                LEGACY_SCHEMA, "demo-unqualified-image-only"
            ):
                expected_members = {"manifest.json", "image.tar"}
            else:
                fail(f"unsupported package schema or status in {path}")
            if len(members) != len(expected_members) or member_names != expected_members:
                fail(f"{path} does not match its declared package status")
            if manifest.get("package_id") != expected_package_id:
                fail(f"expected {expected_package_id} package, got {manifest.get('package_id')!r}")
            if manifest.get("platform") != PLATFORM:
                fail(f"package {path} must target {PLATFORM}")
            payloads = manifest.get("payloads")
            expected_payload_names = (
                {"image.tar", "runtime.tar"}
                if package_status == "demo-unqualified-runtime-package"
                else {"image.tar"}
            )
            if not isinstance(payloads, list) or len(payloads) != len(expected_payload_names):
                fail(f"package {path} declares an invalid number of payloads")
            payload_map = {
                payload.get("path"): payload
                for payload in payloads
                if isinstance(payload, dict)
            }
            if set(payload_map) != expected_payload_names:
                fail(f"package {path} has invalid payload declarations")
            if (payload_map["image.tar"].get("sha256") != image_hash
                    or payload_map["image.tar"].get("size_bytes") != image_size):
                fail(f"image payload checksum or size mismatch: {path}")
            if package_status == "demo-unqualified-runtime-package":
                runtime_file = archive.extractfile("runtime.tar")
                if runtime_file is None:
                    fail(f"{path} is missing runtime.tar")
                runtime_hash, runtime_size = sha256_stream(runtime_file)
                if (payload_map["runtime.tar"].get("sha256") != runtime_hash
                        or payload_map["runtime.tar"].get("size_bytes") != runtime_size):
                    fail(f"runtime payload checksum or size mismatch: {path}")
                runtime_tmp = tempfile.NamedTemporaryFile(
                    prefix="zpr-demo-runtime-", delete=False
                )
                try:
                    with runtime_tmp:
                        runtime_file.seek(0)
                        shutil.copyfileobj(runtime_file, runtime_tmp)
                    verify_runtime_archive(Path(runtime_tmp.name))
                finally:
                    Path(runtime_tmp.name).unlink(missing_ok=True)
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
            if (not isinstance(reference, str)
                    or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,254}", reference)):
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
    if zpr.get("status") != simulator.get("status"):
        fail("ZPR and Simulator packages use different package formats")
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
    docs_root = Path(__file__).resolve().parents[3]
    runtime_dirs = (
        Path(args.zpr_runtime_dir),
        Path(args.simulator_runtime_dir)
        if args.simulator_runtime_dir
        else docs_root / "zpr-visaservice/zpr-dashboard/packaging/demo-runtime",
    )
    zpr_pki_helper = (
        Path(args.zpr_pki_helper)
        if args.zpr_pki_helper
        else docs_root / "zpr-core/integration-test/lib/zpr-pki"
    )
    demo_root = docs_root / "zpr-demo/multinode-demo"
    zpr_runtime_assets = [(zpr_pki_helper, "zpr-pki")]
    for name in (
        "entrypoint-alice.sh",
        "entrypoint-node0.sh",
        "entrypoint-node1.sh",
        "entrypoint-vs.sh",
        "entrypoint-web0.sh",
        "entrypoint-web1.sh",
    ):
        zpr_runtime_assets.append(
            (
                demo_root / "local-compute" / name,
                f"assets/entrypoints/{name}",
            )
        )
    for name in (
        "attrfile.json",
        "multinode-demo.zpl",
        "multinode-demo.zplc.template",
    ):
        zpr_runtime_assets.append(
            (demo_root / "zpr-conf/admin" / name, f"assets/config/admin/{name}")
        )
    for name in (
        "adapter-alice-conf.toml.template",
        "adapter-alice-local-conf.toml.template",
        "adapter-bob-conf.toml.template",
        "adapter-vs-conf.toml.template",
        "adapter-web0-conf.toml.template",
        "adapter-web1-conf.toml.template",
        "node0-conf.toml",
        "node1-conf.toml",
        "zpr-dashboard-config.toml",
    ):
        zpr_runtime_assets.append(
            (demo_root / "zpr-conf/confs" / name, f"assets/config/confs/{name}")
        )
    zpr_runtime_assets.extend(
        (
            (demo_root / "local-compute/vs.toml", "assets/config/vs.toml"),
            (demo_root / "tools/regen-banner.sh", "assets/tools/regen-banner.sh"),
        )
    )
    for source_path in runtime_dirs:
        reject_local_runtime_source(source_path, docs_root)
    for source_path, _ in zpr_runtime_assets:
        reject_local_runtime_source(source_path, docs_root)

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
        runtime_paths = (stage / "zpr-runtime.tar", stage / "simulator-runtime.tar")
        create_runtime_archive(
            runtime_dirs[0],
            runtime_paths[0],
            extra_files=zpr_runtime_assets,
        )
        create_runtime_archive(runtime_dirs[1], runtime_paths[1])
        for image_path, reference in zip(image_paths, references):
            run_docker("image", "save", "--output", str(image_path), reference)
        image_ids = tuple(
            docker_save_identity(image_path, reference)
            for image_path, reference in zip(image_paths, references)
        )
        create_archive(stage / names[0], "zpr-demo-image", "simulator-image",
                       args.release_id, references[0], image_ids[0], docker_image_ids[0],
                       image_paths[0], runtime_paths[0], image_ids[1], docker_image_ids[1])
        create_archive(stage / names[1], "simulator-image", "zpr-demo-image",
                       args.release_id, references[1], image_ids[1], docker_image_ids[1],
                       image_paths[1], runtime_paths[1], image_ids[0], docker_image_ids[0])
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
    print(f"Created demo runtime package pair for release {args.release_id}")
    for path in destinations:
        print(path)


def verify(args):
    zpr, simulator = verify_pair(args.zpr_archive, args.simulator_archive)
    status = (
        "runtime package"
        if zpr["status"] == "demo-unqualified-runtime-package"
        else "legacy image-only pair"
    )
    print(f"Verified {status} for release {zpr['release_id']}")
    print(f"  ZPR image:       {zpr['component']['image_id']}")
    print(f"  Simulator image: {simulator['component']['image_id']}")
    print("  Status:          demo-unqualified-runtime-package")


def extract_runtime_package(archive_path, destination, expected_package_id):
    manifest = load_package(archive_path, expected_package_id)
    destination.mkdir(mode=0o755)
    (destination / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    with tarfile.open(archive_path, "r:") as package:
        runtime = package.extractfile("runtime.tar")
        if runtime is None:
            fail(f"missing runtime payload in {archive_path}")
        with tarfile.open(fileobj=runtime, mode="r:") as assets:
            for member in assets.getmembers():
                safe_tar_member(member)
                safe_runtime_asset_name(member.name)
                target = destination.joinpath(*PurePosixPath(member.name).parts)
                if member.isdir():
                    target.mkdir(mode=0o755, parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                stream = assets.extractfile(member)
                if stream is None:
                    fail(f"unreadable runtime asset {member.name!r}")
                mode = (
                    0o755
                    if member.mode & 0o111
                    or target.suffix == ".sh"
                    or target.name == "zpr-pki"
                    else 0o644
                )
                descriptor = os.open(
                    target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode
                )
                with os.fdopen(descriptor, "wb") as output:
                    shutil.copyfileobj(stream, output)
                os.chmod(target, mode)
    image_reference = manifest["component"]["image_reference"]
    if not isinstance(image_reference, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,254}", image_reference
    ):
        fail(f"invalid Docker image reference in {archive_path}")
    reference_path = destination / "runtime/image-reference"
    descriptor = os.open(
        reference_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644
    )
    with os.fdopen(descriptor, "w", encoding="ascii") as reference_file:
        reference_file.write(image_reference + "\n")
    return manifest


def install(args):
    zpr, simulator = verify_pair(args.zpr_archive, args.simulator_archive)
    runtime_package = zpr.get("status") == "demo-unqualified-runtime-package"
    stage = None
    final_directory = None
    if runtime_package:
        if not args.install_dir:
            fail("--install-dir is required for runtime package archives")
        install_root = Path(args.install_dir)
        if install_root.exists() and (
            install_root.is_symlink() or not install_root.is_dir()
        ):
            fail(f"install directory must be a regular directory: {install_root}")
        install_root.mkdir(parents=True, exist_ok=True, mode=0o755)
        install_root = install_root.resolve(strict=True)
        final_directory = install_root / zpr["release_id"]
        if final_directory.exists() or final_directory.is_symlink():
            fail(f"refusing to overwrite installed release: {final_directory}")
        stage = Path(tempfile.mkdtemp(prefix=".zpr-demo-install-", dir=install_root))
        os.chmod(stage, 0o755)
    try:
        if stage is not None:
            extract_runtime_package(
                args.zpr_archive, stage / "zpr-demo", "zpr-demo-image"
            )
            extract_runtime_package(
                args.simulator_archive, stage / "simulator", "simulator-image"
            )
        for archive_path, manifest in (
            (args.zpr_archive, zpr),
            (args.simulator_archive, simulator),
        ):
            with tempfile.NamedTemporaryFile(
                prefix="zpr-demo-install-image-", delete=False
            ) as temp:
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
            with tempfile.NamedTemporaryFile(
                prefix="zpr-demo-loaded-", delete=False
            ) as saved:
                saved_path = Path(saved.name)
            try:
                run_docker("image", "save", "--output", str(saved_path), reference)
                if docker_save_identity(
                    saved_path, reference
                ) != manifest["component"]["image_id"]:
                    fail(f"loaded image config digest mismatch for {archive_path}")
            finally:
                saved_path.unlink(missing_ok=True)
        if stage is not None and final_directory is not None:
            os.rename(stage, final_directory)
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage)
    if runtime_package:
        print(f"Installed verified demo pair for release {zpr['release_id']}")
        print(f"  ZPR runtime:       {final_directory / 'zpr-demo'}")
        print(f"  Simulator runtime: {final_directory / 'simulator'}")
        print("No containers were started.")
    else:
        print(f"Loaded image-only demo pair for release {zpr['release_id']}")
        print("No runtime assets were installed and no containers were started.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="build paired demo runtime archives")
    build_parser.add_argument("--release-id", required=True)
    build_parser.add_argument("--output-dir", required=True)
    build_parser.add_argument(
        "--zpr-runtime-dir",
        default=str(Path(__file__).with_name("runtime")),
        help="directory of package-owned ZPR runtime assets",
    )
    build_parser.add_argument(
        "--simulator-runtime-dir",
        help="directory of package-owned Simulator runtime assets",
    )
    build_parser.add_argument(
        "--zpr-pki-helper",
        help="non-secret zpr-pki helper to bundle with the ZPR runtime",
    )
    build_parser.add_argument("--zpr-image", required=True)
    build_parser.add_argument("--simulator-image", required=True)
    build_parser.set_defaults(func=build)
    verify_parser = commands.add_parser("verify", help="verify exact package pair before loading")
    verify_parser.add_argument("zpr_archive")
    verify_parser.add_argument("simulator_archive")
    verify_parser.set_defaults(func=verify)
    install_parser = commands.add_parser(
        "install", help="verify pair, load both images, and install runtime assets"
    )
    install_parser.add_argument("zpr_archive")
    install_parser.add_argument("simulator_archive")
    install_parser.add_argument("--install-dir")
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
