#!/usr/bin/env python3
"""Focused tests for the standalone Northstar source-manifest contract."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("northstar-source-contract.py")
DOCS_ROOT = SCRIPT.resolve().parents[3]
PROFILE = (
    DOCS_ROOT
    / "zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/northstar.json"
)


def configured_assets():
    profile = json.loads(PROFILE.read_text(encoding="utf-8"))
    return profile["directory"]["ldif_files"]


class NorthstarSourceManifestTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source_root = self.root / "portable-source"
        self.source_root.mkdir()
        self.manifest_path = self.root / "source-manifest.json"
        self.assets = configured_assets()
        self.asset_contents = {}
        for name in self.assets:
            content = f"temporary test fixture for {name}\n".encode("ascii")
            self.asset_contents[name] = content
            (self.source_root / name).write_bytes(content)
        self.manifest = self.valid_manifest()
        self.write_manifest()

    def tearDown(self):
        self.temp.cleanup()

    def valid_manifest(self):
        return {
            "schema": "zpr.northstar.source-manifest.v1",
            "review": {
                "status": "reviewed",
                "reviewer": "test-only",
                "reference": "fixture-test",
            },
            "assets": [
                {
                    "path": name,
                    "sha256": hashlib.sha256(self.asset_contents[name]).hexdigest(),
                }
                for name in self.assets
            ],
        }

    def write_manifest(self, path=None):
        (path or self.manifest_path).write_text(
            json.dumps(self.manifest), encoding="utf-8"
        )

    def run_validator(self, source_root=None, manifest_path=None):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--source-root",
                str(source_root or self.source_root),
                "--manifest",
                str(manifest_path or self.manifest_path),
            ],
            text=True,
            capture_output=True,
        )

    def test_accepts_reviewed_manifest_for_profile_assets(self):
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("contract valid for 4 assets", result.stdout)

    def test_rejects_manifest_missing_configured_asset(self):
        self.manifest["assets"].pop()
        self.write_manifest()
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing configured Northstar assets", result.stderr)

    def test_rejects_missing_source_file(self):
        (self.source_root / self.assets[0]).unlink()
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest source asset is missing", result.stderr)

    def test_rejects_manifest_extra_asset(self):
        self.manifest["assets"].append(
            {"path": "unexpected.ldif", "sha256": "0" * 64}
        )
        self.write_manifest()
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unconfigured Northstar asset", result.stderr)

    def test_rejects_duplicate_manifest_entries_and_basenames(self):
        for duplicate_path in (self.assets[0], "alternate/" + self.assets[0]):
            with self.subTest(path=duplicate_path):
                self.manifest = self.valid_manifest()
                duplicate = self.manifest["assets"][0].copy()
                duplicate["path"] = duplicate_path
                self.manifest["assets"].append(duplicate)
                self.write_manifest()
                result = self.run_validator()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("repeats Northstar asset basename", result.stderr)

    def test_rejects_unmanifested_source_file(self):
        (self.source_root / "extra.ldif").write_text("extra", encoding="ascii")
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unmanifested assets", result.stderr)

    def test_rejects_hash_mismatch(self):
        self.manifest["assets"][0]["sha256"] = "0" * 64
        self.write_manifest()
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)

    def test_rejects_malformed_sha256_values(self):
        for malformed in ("0" * 63, "g" * 64, "A" * 64):
            with self.subTest(digest=malformed):
                self.manifest = self.valid_manifest()
                self.manifest["assets"][0]["sha256"] = malformed
                self.write_manifest()
                result = self.run_validator()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid SHA-256", result.stderr)

    def test_requires_review_metadata(self):
        self.manifest["review"]["status"] = "pending"
        self.write_manifest()
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("explicitly declare review status", result.stderr)

    def test_rejects_unsafe_relative_paths(self):
        for unsafe_path in ("../demo-company.ldif", "/demo-company.ldif"):
            with self.subTest(path=unsafe_path):
                self.manifest["assets"][0]["path"] = unsafe_path
                self.write_manifest()
                result = self.run_validator()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unsafe manifest asset path", result.stderr)
                self.manifest = self.valid_manifest()

    def test_rejects_local_runtime_manifest_path_component(self):
        self.manifest["assets"][0]["path"] = (
            ".local-runtime/" + self.assets[0]
        )
        self.write_manifest()
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe manifest asset path", result.stderr)

    def test_rejects_source_root_inside_local_runtime(self):
        result = self.run_validator(source_root=DOCS_ROOT / ".local-runtime")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source root resolves inside prohibited .local-runtime", result.stderr)

    def test_rejects_source_root_symlink_into_local_runtime(self):
        source_alias = self.root / "local-runtime-root-alias"
        source_alias.symlink_to(DOCS_ROOT / ".local-runtime", target_is_directory=True)
        result = self.run_validator(source_root=source_alias)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source root resolves inside prohibited .local-runtime", result.stderr)

    def test_accepts_source_root_symlink_to_portable_fixture(self):
        source_alias = self.root / "portable-source-alias"
        source_alias.symlink_to(self.source_root, target_is_directory=True)
        result = self.run_validator(source_root=source_alias)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_symlink_escape_to_local_runtime(self):
        alias = self.source_root / "local-runtime-alias"
        alias.symlink_to(DOCS_ROOT / ".local-runtime", target_is_directory=True)
        self.manifest["assets"][0]["path"] = (
            "local-runtime-alias/" + self.assets[0]
        )
        self.write_manifest()
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(".local-runtime", result.stderr)

    def test_rejects_symlink_escape_outside_source_root(self):
        external = self.root / self.assets[0]
        external.write_bytes(self.asset_contents[self.assets[0]])
        asset = self.source_root / self.assets[0]
        asset.unlink()
        asset.symlink_to(external)
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes source root", result.stderr)

    def test_rejects_manifest_symlink_into_local_runtime(self):
        manifest_alias = self.root / "manifest-alias.json"
        manifest_alias.symlink_to(DOCS_ROOT / ".local-runtime/simulation-environment.json")
        result = self.run_validator(manifest_path=manifest_alias)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source manifest resolves inside prohibited .local-runtime", result.stderr)

    def test_accepts_manifest_symlink_to_explicit_portable_manifest(self):
        manifest_alias = self.root / "portable-manifest-alias.json"
        manifest_alias.symlink_to(self.manifest_path)
        result = self.run_validator(manifest_path=manifest_alias)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
