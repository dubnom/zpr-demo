#!/usr/bin/env python3
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("package-demo-images.py")


def write_docker_stub(directory, log_path):
    docker = directory / "docker"
    docker.write_text(
        """#!/usr/bin/env python3
import hashlib, json, os, sys, tarfile
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["FAKE_DOCKER_CALL_LOG"], "a") as stream:
    stream.write(" ".join(args) + "\\n")
def config_for(ref):
    label = "zpr" if ref.startswith("zpr-") else "simulator"
    return json.dumps(
        {"os":"linux","architecture":os.environ.get("FAKE_ARCH", "amd64"),
         "config":{"Labels":{"demo.image":label}}},
        sort_keys=True, separators=(",",":")
    ).encode()
def image_id(ref):
    return "sha256:" + hashlib.sha256(config_for(ref)).hexdigest()
if args[:2] == ["image", "inspect"]:
    ref = args[2]
    print(json.dumps([{"Id": image_id(ref), "Os": "linux",
                       "Architecture": os.environ.get("FAKE_ARCH", "amd64")}]))
elif args[:2] == ["image", "save"]:
    ref = args[-1]
    out = Path(args[args.index("--output") + 1])
    config = config_for(ref)
    image_id = image_id(ref)
    out_config = image_id.removeprefix("sha256:") + ".json"
    with tarfile.open(out, "w") as archive:
        info = tarfile.TarInfo(out_config); info.size = len(config)
        import io; archive.addfile(info, io.BytesIO(config))
        entry = json.dumps([{"Config":out_config,"RepoTags":[ref],"Layers":[]}]).encode()
        info = tarfile.TarInfo("manifest.json"); info.size = len(entry)
        archive.addfile(info, io.BytesIO(entry))
elif args[:1] == ["load"] and args[1:2] == ["--input"]:
    with open(os.environ["FAKE_DOCKER_LOG"], "a") as stream:
        stream.write("load\\n")
    Path(args[2]).read_bytes()
else:
    print("unexpected fake docker command: " + repr(args), file=sys.stderr)
    sys.exit(9)
""",
        encoding="utf-8",
    )
    docker.chmod(0o755)
    return docker


def rewrite_archive(path, edit_manifest=None, extra_member=None):
    with tarfile.open(path, "r:") as source:
        manifest = json.loads(source.extractfile("manifest.json").read())
        payload = source.extractfile("image.tar").read()
        runtime = source.extractfile("runtime.tar").read()
    if edit_manifest:
        edit_manifest(manifest)
    with tarfile.open(path, "w:") as archive:
        for name, data in (
            ("manifest.json", json.dumps(manifest).encode()),
            ("image.tar", payload),
            ("runtime.tar", runtime),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        if extra_member:
            name, data = extra_member
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    Path(str(path) + ".sha256").write_text(
        f"{digest}  {path.name}\n", encoding="ascii"
    )


def convert_to_image_only(path):
    with tarfile.open(path, "r:") as source:
        manifest = json.loads(source.extractfile("manifest.json").read())
        image = source.extractfile("image.tar").read()
    manifest["schema"] = "zpr.demo.image-package.v1"
    manifest["status"] = "demo-unqualified-image-only"
    manifest["payloads"] = manifest["payloads"][:1]
    with tarfile.open(path, "w") as archive:
        for name, data in (
            ("manifest.json", json.dumps(manifest).encode()),
            ("image.tar", image),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    Path(str(path) + ".sha256").write_text(
        f"{digest}  {path.name}\n", encoding="ascii"
    )


def replace_runtime_asset(path, member_name, data):
    with tarfile.open(path, "r:") as source:
        manifest = json.loads(source.extractfile("manifest.json").read())
        image = source.extractfile("image.tar").read()
    runtime_buffer = io.BytesIO()
    with tarfile.open(fileobj=runtime_buffer, mode="w") as assets:
        info = tarfile.TarInfo(member_name)
        info.size = len(data)
        assets.addfile(info, io.BytesIO(data))
    runtime = runtime_buffer.getvalue()
    manifest["payloads"][1] = {
        "path": "runtime.tar",
        "sha256": hashlib.sha256(runtime).hexdigest(),
        "size_bytes": len(runtime),
    }
    with tarfile.open(path, "w") as archive:
        for name, payload in (
            ("manifest.json", json.dumps(manifest).encode()),
            ("image.tar", image),
            ("runtime.tar", runtime),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    Path(str(path) + ".sha256").write_text(
        f"{digest}  {path.name}\n", encoding="ascii"
    )


class PackageDemoImagesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "docker.log"
        self.docker_calls = self.root / "docker-calls.log"
        write_docker_stub(self.bin, self.log)
        self.env = os.environ.copy()
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.env["FAKE_DOCKER_LOG"] = str(self.log)
        self.env["FAKE_DOCKER_CALL_LOG"] = str(self.docker_calls)
        self.output = self.root / "out"
        self.output.mkdir()
        self.zpr_assets = self.root / "zpr-assets"
        self.simulator_assets = self.root / "simulator-assets"
        self.zpr_assets.mkdir()
        self.simulator_assets.mkdir()
        (self.zpr_assets / "zpr-demo-runtime.sh").write_text(
            "#!/bin/sh\nexit 0\n", encoding="utf-8"
        )
        (self.zpr_assets / "test-only.sh").write_text(
            "#!/bin/sh\nexit 0\n", encoding="utf-8"
        )
        (self.simulator_assets / "simulator-demo-runtime.sh").write_text(
            "#!/bin/sh\nexit 0\n", encoding="utf-8"
        )

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, *args, ok=True):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *map(str, args)],
            env=self.env, text=True, capture_output=True,
        )
        if ok and result.returncode:
            self.fail(f"command failed: {result.stderr}")
        if not ok and result.returncode == 0:
            self.fail(f"command unexpectedly succeeded: {result.stdout}")
        return result

    def run_build(
        self, *, release_id="test-release", simulator_runtime_dir=None,
        zpr_runtime_dir=None, zpr_pki_helper=None, ok=True,
    ):
        args = [
            "build", "--release-id", release_id, "--output-dir", self.output,
            "--zpr-image", "zpr-candidate:latest",
            "--simulator-image", "simulator-candidate:latest",
        ]
        if zpr_runtime_dir is not None:
            args.extend(("--zpr-runtime-dir", zpr_runtime_dir))
        else:
            args.extend(("--zpr-runtime-dir", self.zpr_assets))
        if simulator_runtime_dir is not None:
            args.extend(("--simulator-runtime-dir", simulator_runtime_dir))
        else:
            args.extend(("--simulator-runtime-dir", self.simulator_assets))
        if zpr_pki_helper is not None:
            args.extend(("--zpr-pki-helper", zpr_pki_helper))
        return self.run_script(*args, ok=ok)

    def build(self, simulator_runtime_dir=None, zpr_runtime_dir=None):
        self.run_build(
            simulator_runtime_dir=simulator_runtime_dir,
            zpr_runtime_dir=zpr_runtime_dir,
        )
        return (
            self.output / "zpr-demo-test-release.tar",
            self.output / "simulator-test-release.tar",
        )

    def test_rejects_local_runtime_sources_including_symlink_targets(self):
        docs_root = SCRIPT.resolve().parents[3]
        local_runtime = docs_root / ".local-runtime"
        runtime_alias = self.root / "local-runtime-alias"
        runtime_alias.symlink_to(local_runtime, target_is_directory=True)
        cases = (
            ("zpr-runtime-dir", {"zpr_runtime_dir": local_runtime}),
            ("simulator-runtime-dir", {"simulator_runtime_dir": runtime_alias}),
            (
                "zpr-pki-helper",
                {"zpr_pki_helper": runtime_alias / "simulation-environment.json"},
            ),
        )
        for index, (source_name, options) in enumerate(cases):
            with self.subTest(source=source_name):
                result = self.run_build(
                    release_id=f"blocked-source-{index}",
                    ok=False,
                    **options,
                )
                self.assertIn(".local-runtime", result.stderr)
                self.assertFalse(
                    self.docker_calls.exists(),
                    "Docker must not be invoked for a prohibited source path",
                )

    def test_build_accepts_approved_runtime_directories(self):
        zpr, simulator = self.build()
        self.assertTrue(zpr.is_file())
        self.assertTrue(simulator.is_file())
        self.assertEqual(len(self.docker_calls.read_text().splitlines()), 4)

    def test_installs_actual_paired_runtime_assets_without_tests(self):
        docs_root = SCRIPT.parents[3]
        zpr_runtime_dir = (
            docs_root / "zpr-demo/multinode-demo/packaging/runtime"
        )
        simulator_runtime_dir = (
            docs_root / "zpr-visaservice/zpr-dashboard/packaging/demo-runtime"
        )
        zpr, simulator = self.build(
            simulator_runtime_dir=simulator_runtime_dir,
            zpr_runtime_dir=zpr_runtime_dir,
        )
        self.run_script("verify", zpr, simulator)
        install_dir = self.root / "installed"
        self.run_script(
            "install", zpr, simulator, "--install-dir", install_dir
        )

        zpr_root = install_dir / "test-release/zpr-demo/runtime"
        for name in (
            "zpr-demo-runtime.sh",
            "zpr-demo-compose.yml",
            "init-demo-identities.sh",
            "zpr-pki",
        ):
            installed = zpr_root / name
            self.assertTrue(installed.is_file(), installed)
        for name in ("zpr-demo-runtime.sh", "init-demo-identities.sh", "zpr-pki"):
            self.assertTrue(os.access(zpr_root / name, os.X_OK))
        self.assertFalse((zpr_root / "test-init-demo-identities.sh").exists())
        self.assertFalse((zpr_root / "test-zpr-demo-runtime.sh").exists())
        compose_text = (zpr_root / "zpr-demo-compose.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn('ZPR_DEMO_WEB0_HTTP_SUPERVISOR: "1"', compose_text)
        web0_entrypoint = zpr_root / "assets/entrypoints/entrypoint-web0.sh"
        self.assertTrue(web0_entrypoint.is_file())
        self.assertEqual(
            subprocess.run(
                ["sh", "-n", str(web0_entrypoint)],
                text=True,
                capture_output=True,
            ).returncode,
            0,
        )
        web0_entrypoint_text = web0_entrypoint.read_text(encoding="utf-8")
        self.assertIn("nginx -g 'daemon off;' &", web0_entrypoint_text)
        self.assertIn('wait "$nginx_pid" || true', web0_entrypoint_text)
        self.assertIn("while :; do", web0_entrypoint_text)

        simulator_root = install_dir / "test-release/simulator/runtime"
        paired_runtime = simulator_root / "paired-demo-runtime.sh"
        simulator_runtime = simulator_root / "simulator-demo-runtime.sh"
        self.assertTrue(paired_runtime.is_file())
        self.assertTrue(os.access(paired_runtime, os.X_OK))
        self.assertTrue(simulator_runtime.is_file())
        self.assertTrue(os.access(simulator_runtime, os.X_OK))
        self.assertFalse((simulator_root / "test-paired-demo-runtime.sh").exists())
        simulator_text = simulator_runtime.read_text(encoding="utf-8")
        for variable in (
            "SIMULATION_DEMO_PROJECT",
            "SIMULATION_DEMO_IMAGE",
            "SIMULATION_DEMO_RELEASE_ID",
        ):
            self.assertIn(variable, simulator_text)
        profile = (simulator_root / "organizations/demo.json").read_text(
            encoding="utf-8"
        )
        self.assertIn("Unprovisioned UI-only profile", profile)

    def test_web0_entrypoint_survives_http_service_stop(self):
        demo_root = SCRIPT.parents[1]
        entrypoint = demo_root / "local-compute/entrypoint-web0.sh"
        test_root = self.root / "web0-entrypoint"
        bin_dir = test_root / "bin"
        bin_dir.mkdir(parents=True)
        nginx_pid_file = test_root / "nginx.pid"
        web0_runtime = test_root / "run-web0.sh"
        source = entrypoint.read_text(encoding="utf-8")
        self.assertIn("/tools/regen-banner.sh", source)
        self.assertIn("/var/run/zpr", source)
        web0_runtime.write_text(
            source.replace("/tools/regen-banner.sh", "true").replace(
                "/var/run/zpr", str(test_root / "run/zpr")
            ),
            encoding="utf-8",
        )

        (bin_dir / "ip").write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
        nginx = bin_dir / "nginx"
        nginx.write_text(
            """#!/bin/sh
if [ "$1" = "-g" ]; then
    printf '%s\\n' "$$" >"$NGINX_PID_FILE"
    exec sleep 30
fi
if [ "$1" = "-s" ] && [ "$2" = "stop" ]; then
    kill -TERM "$(cat "$NGINX_PID_FILE")"
    exit 0
fi
exit 2
""",
            encoding="ascii",
        )
        for executable in (bin_dir / "ip", nginx):
            executable.chmod(0o755)

        env = self.env.copy()
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        env["NGINX_PID_FILE"] = str(nginx_pid_file)
        process = subprocess.Popen(["sh", str(web0_runtime)], env=env)
        try:
            deadline = time.monotonic() + 5
            while not nginx_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(nginx_pid_file.is_file(), "web0 did not start nginx")
            subprocess.run([str(nginx), "-s", "stop"], env=env, check=True)
            time.sleep(0.2)
            self.assertIsNone(
                process.poll(),
                "stopping nginx also stopped the web0 adapter container",
            )
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 0)
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                process.wait(timeout=5)

    def test_build_verify_and_install_exact_pair(self):
        zpr, simulator = self.build()
        self.run_script("verify", zpr, simulator)
        install_dir = self.root / "installed"
        self.run_script(
            "install", zpr, simulator, "--install-dir", install_dir
        )
        self.assertEqual(self.log.read_text(encoding="utf-8"), "load\nload\n")
        package_root = install_dir / "test-release"
        self.assertTrue(
            (package_root / "zpr-demo/runtime/zpr-demo-runtime.sh").is_file()
        )
        self.assertTrue(
            os.access(
                package_root / "zpr-demo/runtime/zpr-demo-runtime.sh", os.X_OK
            )
        )
        zpr_pki = package_root / "zpr-demo/runtime/zpr-pki"
        self.assertTrue(zpr_pki.is_file())
        self.assertTrue(os.access(zpr_pki, os.X_OK))
        self.assertTrue(
            (
                package_root
                / "zpr-demo/runtime/assets/config/admin/multinode-demo.zpl"
            ).is_file()
        )
        self.assertTrue(
            (
                package_root
                / "zpr-demo/runtime/assets/entrypoints/entrypoint-node0.sh"
            ).is_file()
        )
        self.assertTrue(
            (package_root / "simulator/runtime/simulator-demo-runtime.sh").is_file()
        )
        self.assertEqual(
            (package_root / "zpr-demo/runtime/image-reference").read_text(
                encoding="ascii"
            ),
            "zpr-candidate:latest\n",
        )
        self.assertEqual(
            (package_root / "simulator/runtime/image-reference").read_text(
                encoding="ascii"
            ),
            "simulator-candidate:latest\n",
        )
        for archive in (zpr, simulator):
            self.assertTrue(Path(str(archive) + ".sha256").is_file())

    def test_runtime_payloads_exclude_private_key_files_and_checkout_include_tree(
        self,
    ):
        zpr, simulator = self.build()
        for package in (zpr, simulator):
            with tarfile.open(package, "r:") as outer:
                runtime = io.BytesIO(outer.extractfile("runtime.tar").read())
            with tarfile.open(fileobj=runtime, mode="r:") as assets:
                names = [member.name for member in assets.getmembers()]
            self.assertFalse(any(Path(name).name.startswith("test-") for name in names))
            self.assertFalse(
                any(
                    name.endswith((".key", ".pem", ".p12", ".pfx"))
                    for name in names
                )
            )
            self.assertFalse(any("/include/" in name for name in names))

    def test_rejects_tampered_archive_checksum(self):
        zpr, simulator = self.build()
        with zpr.open("ab") as stream:
            stream.write(b"tamper")
        result = self.run_script("verify", zpr, simulator, ok=False)
        self.assertIn("archive checksum mismatch", result.stderr)

    def test_install_verifies_both_archives_before_loading_either(self):
        zpr, simulator = self.build()
        with simulator.open("ab") as stream:
            stream.write(b"tamper")
        self.run_script(
            "install", zpr, simulator,
            "--install-dir", self.root / "installed", ok=False,
        )
        self.assertFalse(self.log.exists())

    def test_rejects_payload_change_even_if_outer_checksum_is_recomputed(self):
        zpr, simulator = self.build()
        with tarfile.open(zpr, "r:") as source:
            manifest = source.extractfile("manifest.json").read()
            payload = source.extractfile("image.tar").read() + b"tamper"
            runtime = source.extractfile("runtime.tar").read()
        changed = self.root / "changed.tar"
        with tarfile.open(changed, "w") as archive:
            for name, data in (
                ("manifest.json", manifest),
                ("image.tar", payload),
                ("runtime.tar", runtime),
            ):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        zpr.write_bytes(changed.read_bytes())
        sidecar_hash = hashlib.sha256(zpr.read_bytes()).hexdigest()
        Path(str(zpr) + ".sha256").write_text(
            f"{sidecar_hash}  {zpr.name}\n", encoding="ascii"
        )
        result = self.run_script("verify", zpr, simulator, ok=False)
        self.assertIn("image payload checksum or size mismatch", result.stderr)

    def test_rejects_runtime_private_key_asset_name(self):
        (self.zpr_assets / "operator-private.key").write_text(
            "must not enter package", encoding="ascii"
        )
        result = self.run_script(
            "build", "--release-id", "private-key", "--output-dir", self.output,
            "--zpr-image", "zpr-candidate:latest",
            "--simulator-image", "simulator-candidate:latest",
            "--zpr-runtime-dir", self.zpr_assets,
            "--simulator-runtime-dir", self.simulator_assets,
            ok=False,
        )
        self.assertIn("must not contain credentials or private keys", result.stderr)

    def test_rejects_runtime_archive_path_traversal(self):
        zpr, simulator = self.build()
        replace_runtime_asset(zpr, "runtime/../../outside", b"unsafe")
        result = self.run_script("verify", zpr, simulator, ok=False)
        self.assertIn("unsafe archive path", result.stderr)

    def test_refuses_overwriting_installed_runtime_assets(self):
        zpr, simulator = self.build()
        install_dir = self.root / "installed"
        self.run_script(
            "install", zpr, simulator, "--install-dir", install_dir
        )
        self.log.unlink()
        result = self.run_script(
            "install", zpr, simulator,
            "--install-dir", install_dir, ok=False,
        )
        self.assertIn("refusing to overwrite installed release", result.stderr)
        self.assertFalse(self.log.exists())

    def test_keeps_legacy_image_only_pair_verifiable_and_loadable(self):
        zpr, simulator = self.build()
        convert_to_image_only(zpr)
        convert_to_image_only(simulator)
        result = self.run_script("verify", zpr, simulator)
        self.assertIn("Verified legacy image-only pair", result.stdout)
        result = self.run_script("install", zpr, simulator)
        self.assertIn("No runtime assets were installed", result.stdout)
        self.assertEqual(self.log.read_text(encoding="utf-8"), "load\nload\n")

    def test_rejects_pair_with_different_pinned_peer_image(self):
        zpr, simulator = self.build()
        rewrite_archive(
            zpr,
            lambda manifest: manifest.update(peer_image_id="sha256:" + "f" * 64),
        )
        result = self.run_script("verify", zpr, simulator, ok=False)
        self.assertIn("ZPR package requires a different Simulator image", result.stderr)

    def test_rejects_archive_path_traversal(self):
        zpr, simulator = self.build()
        rewrite_archive(zpr, extra_member=("../outside", b"not safe"))
        result = self.run_script("verify", zpr, simulator, ok=False)
        self.assertIn("unsafe archive path", result.stderr)

    def test_refuses_existing_release_outputs(self):
        self.build()
        result = self.run_script(
            "build", "--release-id", "test-release", "--output-dir", self.output,
            "--zpr-image", "zpr-candidate:latest",
            "--simulator-image", "simulator-candidate:latest",
            "--zpr-runtime-dir", self.zpr_assets,
            "--simulator-runtime-dir", self.simulator_assets,
            ok=False,
        )
        self.assertIn("refusing to overwrite", result.stderr)

    def test_rejects_non_amd64_candidate_image(self):
        self.env["FAKE_ARCH"] = "arm64"
        result = self.run_script(
            "build", "--release-id", "wrong-arch", "--output-dir", self.output,
            "--zpr-image", "zpr-candidate:latest",
            "--simulator-image", "simulator-candidate:latest",
            "--zpr-runtime-dir", self.zpr_assets,
            "--simulator-runtime-dir", self.simulator_assets,
            ok=False,
        )
        self.assertIn("must be linux/amd64", result.stderr)


if __name__ == "__main__":
    unittest.main()
