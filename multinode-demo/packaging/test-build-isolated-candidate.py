import contextlib
import base64
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("build-isolated-candidate.py")
SPEC = importlib.util.spec_from_file_location("build_isolated_candidate", SCRIPT)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


REQUIRED_FILES = {
    "zpr-core": (
        "Cargo.toml", "adapter/ph/Cargo.toml", "adapter/cli/Cargo.toml",
        "integration-test/lib/zpr-pki",
    ),
    "zpr-common": ("Cargo.toml",),
    "zpr-utils": ("zpr-utils/Cargo.toml",),
    "zpr-compiler": ("Cargo.toml",),
    "zpr-dev-tools": ("docker/dev-env/Dockerfile",),
    "zpr-visaservice": (
        "Cargo.toml", "zpr-dashboard/go.mod", "zpr-dashboard/go.sum",
        "zpr-dashboard/scripts/Dockerfile.simulator",
        "zpr-dashboard/packaging/demo-runtime/runtime.sh",
    ),
    "zpr-demo": (
        "multinode-demo/Makefile",
        "multinode-demo/README.md",
        "multinode-demo/Dockerfile.build-linux",
        "multinode-demo/build-linux-amd64.sh",
        "multinode-demo/Dockerfile",
        "multinode-demo/packaging/package-demo-images.py",
        "multinode-demo/packaging/runtime/runtime.sh",
        "multinode-demo/local-compute/entrypoint-alice.sh",
        "multinode-demo/local-compute/entrypoint-node0.sh",
        "multinode-demo/local-compute/entrypoint-node1.sh",
        "multinode-demo/local-compute/entrypoint-vs.sh",
        "multinode-demo/local-compute/entrypoint-web0.sh",
        "multinode-demo/local-compute/entrypoint-web1.sh",
        "multinode-demo/zpr-conf/admin/attrfile.json",
        "multinode-demo/zpr-conf/admin/multinode-demo.zpl",
        "multinode-demo/zpr-conf/admin/multinode-demo.zplc.template",
        "multinode-demo/zpr-conf/confs/adapter-alice-conf.toml.template",
        "multinode-demo/zpr-conf/confs/adapter-alice-local-conf.toml.template",
        "multinode-demo/zpr-conf/confs/adapter-bob-conf.toml.template",
        "multinode-demo/zpr-conf/confs/adapter-vs-conf.toml.template",
        "multinode-demo/zpr-conf/confs/adapter-web0-conf.toml.template",
        "multinode-demo/zpr-conf/confs/adapter-web1-conf.toml.template",
        "multinode-demo/zpr-conf/confs/node0-conf.toml",
        "multinode-demo/zpr-conf/confs/node1-conf.toml",
        "multinode-demo/zpr-conf/confs/zpr-dashboard-config.toml",
        "multinode-demo/local-compute/vs.toml",
        "multinode-demo/tools/regen-banner.sh",
    ),
}


def git(repo, *args):
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def fixture_root(base):
    root = base / "source"
    for repository, files in REQUIRED_FILES.items():
        repo = root / repository
        repo.mkdir(parents=True)
        git(repo, "init", "-b", "main")
        git(repo, "config", "user.email", "candidate-test@example.invalid")
        git(repo, "config", "user.name", "Candidate Test")
        for relative in files:
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"safe synthetic source {repository}/{relative}\n", encoding="utf-8")
        if repository == "zpr-demo":
            (repo / "multinode-demo/Makefile").write_text(
                'linux-amd64:\n'
                '\tdocker build -t $(ZPR_BUILDER_IMAGE) .\n'
                '\tdocker run -v "$(ZPR_ROOT):/work" $(ZPR_BUILDER_IMAGE)\n',
                encoding="utf-8",
            )
        git(repo, "add", ".")
        git(repo, "commit", "-m", "synthetic baseline")
    return root


def make_args(source, output_parent, **overrides):
    values = {
        "source_root": str(source),
        "output_parent": str(output_parent),
        "release_id": "test-candidate",
        "include_dirty": [],
        "include_untracked": [],
        "dry_run": True,
    }
    values.update(overrides)
    return type("Args", (), values)()


def find_included(plan, repository, relative):
    for entry in plan["repositories"][repository]["included"]:
        if entry["path"] == f"{repository}/{relative}":
            return entry
    raise AssertionError(f"not included: {repository}/{relative}")


class IsolatedCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = fixture_root(self.base)
        self.output_parent = self.base / "outputs"
        self.output_parent.mkdir()
        self.tool_paths = mock.patch.object(candidate.shutil, "which", side_effect=lambda name: f"/synthetic/{name}")
        self.tool_paths.start()
        self.addCleanup(self.tool_paths.stop)

    def test_modified_tracked_files_require_exact_allowlist_and_record_diff(self):
        path = self.source / "zpr-demo/multinode-demo/README.md"
        original = path.read_text(encoding="utf-8")
        path.write_text(original + "approved local change\n", encoding="utf-8")

        baseline_plan, baseline_repos, baseline_inventories, baseline_root = candidate.collect_plan(
            make_args(self.source, self.output_parent), run_id="baseline"
        )
        baseline_entry = find_included(
            baseline_plan, "zpr-demo", "multinode-demo/README.md"
        )
        self.assertFalse(baseline_entry["dirty"])
        self.assertEqual(
            baseline_entry["sha256"],
            candidate.hashlib.sha256(original.encode()).hexdigest(),
        )
        baseline_source, _ = candidate.stage_candidate(
            baseline_plan, baseline_repos, baseline_inventories, baseline_root
        )
        self.assertEqual(
            (baseline_source / "zpr-demo/multinode-demo/README.md").read_text(encoding="utf-8"),
            original,
        )

        args = make_args(
            self.source,
            self.output_parent,
            include_dirty=["zpr-demo:multinode-demo/README.md"],
        )
        plan, repos, inventories, root = candidate.collect_plan(args, run_id="approved")
        entry = find_included(plan, "zpr-demo", "multinode-demo/README.md")
        self.assertTrue(entry["dirty"])
        self.assertNotEqual(entry["sha256"], baseline_entry["sha256"])
        self.assertRegex(entry["diff_sha256"], r"^[0-9a-f]{64}$")
        self.assertIn(
            b"approved local change",
            base64.b64decode(entry["diff_base64"]),
        )

        source, _ = candidate.stage_candidate(plan, repos, inventories, root)
        staged = source / "zpr-demo/multinode-demo/README.md"
        self.assertIn("approved local change", staged.read_text(encoding="utf-8"))
        provenance = json.loads((root / "provenance.json").read_text(encoding="utf-8"))
        self.assertEqual(
            provenance["repositories"]["zpr-demo"]["head"],
            git_output(self.source / "zpr-demo", "rev-parse", "HEAD"),
        )
        self.assertEqual(
            provenance["repositories"]["zpr-demo"]["branch"],
            "main",
        )
        self.assertEqual(
            find_included(provenance, "zpr-demo", "multinode-demo/README.md")["sha256"],
            candidate.hashlib.sha256(staged.read_bytes()).hexdigest(),
        )

    def test_unapproved_and_private_untracked_files_are_excluded(self):
        repo = self.source / "zpr-demo"
        unapproved = repo / "multinode-demo/notes.txt"
        private = repo / "multinode-demo/packaging/credentials/private-key.pem"
        unapproved.parent.mkdir(parents=True, exist_ok=True)
        private.parent.mkdir(parents=True, exist_ok=True)
        unapproved.write_text("do not include\n", encoding="utf-8")
        private.write_text("do not read or include\n", encoding="utf-8")

        plan, _, _, _ = candidate.collect_plan(
            make_args(self.source, self.output_parent), run_id="excluded"
        )
        included_paths = {
            item["path"]
            for repo_plan in plan["repositories"].values()
            for item in repo_plan["included"]
        }
        self.assertNotIn("zpr-demo/multinode-demo/notes.txt", included_paths)
        self.assertNotIn(
            "zpr-demo/multinode-demo/packaging/credentials/private-key.pem",
            included_paths,
        )
        exclusions = plan["repositories"]["zpr-demo"]["excluded"]
        self.assertTrue(any(item["path"].endswith("/notes.txt") for item in exclusions))

    def test_explicit_untracked_allowlist_includes_only_named_file(self):
        repo = self.source / "zpr-demo"
        allowed = repo / "multinode-demo/reviewed.txt"
        other = repo / "multinode-demo/unreviewed.txt"
        allowed.write_text("approved input\n", encoding="utf-8")
        other.write_text("unapproved input\n", encoding="utf-8")

        args = make_args(
            self.source,
            self.output_parent,
            include_untracked=["zpr-demo:multinode-demo/reviewed.txt"],
        )
        plan, repos, inventories, root = candidate.collect_plan(args, run_id="untracked")
        included = find_included(plan, "zpr-demo", "multinode-demo/reviewed.txt")
        self.assertTrue(included["untracked"])
        source, _ = candidate.stage_candidate(plan, repos, inventories, root)
        self.assertTrue((source / "zpr-demo/multinode-demo/reviewed.txt").is_file())
        self.assertFalse((source / "zpr-demo/multinode-demo/unreviewed.txt").exists())

    def test_local_runtime_is_rejected_during_preflight(self):
        repo = self.source / "zpr-demo"
        local = repo / ".local-runtime/private-state"
        local.parent.mkdir(parents=True)
        local.write_text("synthetic\n", encoding="utf-8")
        git(repo, "add", ".local-runtime/private-state")
        git(repo, "commit", "-m", "unsafe local runtime input")
        args = make_args(self.source, self.output_parent, dry_run=False)

        with mock.patch.object(candidate, "verify_docker_tags") as docker_check:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(candidate.main([
                    "--source-root", str(self.source),
                    "--output-parent", str(self.output_parent),
                    "--release-id", "test-candidate",
                    "--execute",
                ]), 1)
            docker_check.assert_not_called()
        self.assertFalse(any(self.output_parent.iterdir()))

    def test_symlink_escape_is_rejected_before_docker(self):
        repo = self.source / "zpr-demo"
        (repo / "escape").symlink_to("../../outside")
        git(repo, "add", "escape")
        git(repo, "commit", "-m", "unsafe symlink")
        with self.assertRaisesRegex(candidate.CandidateError, "symlink escapes"):
            candidate.collect_plan(make_args(self.source, self.output_parent), run_id="escape")
        self.assertFalse(any(self.output_parent.iterdir()))

    def test_dry_run_prints_plan_without_writes_or_docker(self):
        with mock.patch.object(candidate, "verify_docker_tags") as docker_check:
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = candidate.main([
                    "--source-root", str(self.source),
                    "--output-parent", str(self.output_parent),
                    "--release-id", "dry-run",
                ])
        self.assertEqual(result, 0)
        plan = json.loads(stdout.getvalue())
        self.assertEqual(plan["mode"], "dry-run")
        self.assertIn("builder", plan["docker_tags"])
        self.assertEqual(len(plan["artifact_paths"]), 4)
        docker_check.assert_not_called()
        self.assertFalse((self.output_parent / f"zpr-candidate-dry-run-{plan['run_id']}").exists())
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def test_existing_output_root_is_refused(self):
        existing = self.output_parent / "zpr-candidate-test-candidate-fixed"
        existing.mkdir()
        with self.assertRaisesRegex(candidate.CandidateError, "candidate output already exists"):
            candidate.collect_plan(make_args(self.source, self.output_parent), run_id="fixed")
        self.assertTrue(existing.is_dir())

    def test_existing_docker_tag_is_refused(self):
        calls = []

        def fake_docker(command, **_kwargs):
            calls.append(command)
            if command[1:3] == ["context", "inspect"]:
                return subprocess.CompletedProcess(command, 0, "unix:///synthetic/docker.sock\n", "")
            if command[1:2] == ["info"]:
                return subprocess.CompletedProcess(command, 0, "local\n", "")
            return subprocess.CompletedProcess(command, 0, "image\n", "")

        with self.assertRaisesRegex(candidate.CandidateError, "refusing to overwrite"):
            candidate.verify_docker_tags({"candidate": "example:test"}, runner=fake_docker)
        self.assertEqual(len(calls), 3)

    def test_missing_required_input_fails_before_docker_check(self):
        repo = self.source / "zpr-demo"
        missing = repo / "multinode-demo/Dockerfile"
        missing.unlink()
        git(repo, "add", "-u")
        git(repo, "commit", "-m", "remove required input")
        with mock.patch.object(candidate, "verify_docker_tags") as docker_check:
            with contextlib.redirect_stderr(io.StringIO()):
                result = candidate.main([
                    "--source-root", str(self.source),
                    "--output-parent", str(self.output_parent),
                    "--release-id", "missing",
                    "--execute",
                ])
        self.assertEqual(result, 1)
        docker_check.assert_not_called()
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def add_submodule(self):
        origin = self.base / "module-origin"
        origin.mkdir()
        git(origin, "init", "-b", "main")
        git(origin, "config", "user.email", "candidate-test@example.invalid")
        git(origin, "config", "user.name", "Candidate Test")
        (origin / "source.txt").write_text("pinned synthetic content\n")
        git(origin, "add", ".")
        git(origin, "commit", "-m", "module snapshot")
        parent = self.source / "zpr-common"
        git(parent, "-c", "protocol.file.allow=always", "submodule", "add", str(origin), "module")
        git(parent, "commit", "-am", "pin module")
        return parent, parent / "module"

    def assert_submodule_refused(self, message):
        with mock.patch.object(candidate, "verify_docker_tags") as docker_check:
            with self.assertRaisesRegex(candidate.CandidateError, message):
                candidate.collect_plan(make_args(self.source, self.output_parent))
        docker_check.assert_not_called()
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def test_matching_submodule_provenance_and_pinned_staging(self):
        parent, module = self.add_submodule()
        plan, repos, inventories, root = candidate.collect_plan(
            make_args(self.source, self.output_parent), run_id="submodule"
        )
        provenance = plan["repositories"]["zpr-common"]["submodules"][0]
        pinned = git_output(module, "rev-parse", "HEAD")
        self.assertEqual(provenance["path"], "module")
        self.assertEqual(provenance["pinned_gitlink"], pinned)
        self.assertEqual(provenance["observed_head"], pinned)
        self.assertTrue(provenance["initialized"])
        self.assertEqual(provenance["tree"], git_output(module, "rev-parse", "HEAD^{tree}"))
        self.assertEqual(provenance["included"][0]["sha256"],
                         candidate.hashlib.sha256(b"pinned synthetic content\n").hexdigest())
        with mock.patch.object(candidate, "run_git", wraps=candidate.run_git) as git_calls:
            source, _ = candidate.stage_candidate(plan, repos, inventories, root)
        git_calls.assert_any_call(module.resolve(), "archive", "--format=tar", pinned, binary=True)
        self.assertEqual((source / "zpr-common/module/source.txt").read_text(),
                         "pinned synthetic content\n")
        stored = json.loads((root / "provenance.json").read_text())
        self.assertEqual(stored["repositories"]["zpr-common"]["submodules"], [provenance])
        self.assertFalse((source / "zpr-common/module/.git").exists())

    def test_uninitialized_submodule_rejected(self):
        parent, _ = self.add_submodule()
        git(parent, "submodule", "deinit", "-f", "--", "module")
        self.assert_submodule_refused("uninitialized")

    def test_mismatched_submodule_rejected(self):
        _, module = self.add_submodule()
        git(module, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "--allow-empty", "-m", "not pinned")
        self.assert_submodule_refused("mismatches pinned gitlink")

    def test_dirty_and_untracked_submodule_rejected(self):
        _, module = self.add_submodule()
        file = module / "source.txt"
        file.write_text("dirty\n")
        self.assert_submodule_refused("dirty/untracked")
        file.write_text("pinned synthetic content\n")
        (module / "unexpected.txt").write_text("unapproved\n")
        self.assert_submodule_refused("dirty/untracked")
        (module / "unexpected.txt").unlink()
        gitdir = Path(git_output(module, "rev-parse", "--absolute-git-dir"))
        with (gitdir / "info/exclude").open("a") as output:
            output.write("\nignored.txt\n")
        (module / "ignored.txt").write_text("ignored but forbidden\n")
        self.assert_submodule_refused("dirty/untracked")

    def test_nested_submodule_rejected(self):
        parent, module = self.add_submodule()
        git(module, "-c", "protocol.file.allow=always", "submodule", "add",
            str(self.base / "module-origin"), "nested")
        git(module, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "-am", "nested pin")
        git(parent, "add", "module")
        git(parent, "commit", "-m", "update parent pin")
        self.assert_submodule_refused("nested submodules")

    def test_malformed_submodule_paths_rejected(self):
        parent, _ = self.add_submodule()
        (parent / ".gitmodules").write_text('[submodule "module"]\npath = ../escape\n')
        git(parent, "commit", "-am", "unsafe module path")
        self.assert_submodule_refused("safe repository-relative path")

    def test_submodule_symlink_escape_rejected(self):
        parent, module = self.add_submodule()
        (module / "escape").symlink_to("../../outside")
        git(module, "add", "escape")
        git(module, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "-m", "unsafe link")
        git(parent, "add", "module")
        git(parent, "commit", "-m", "pin unsafe module")
        self.assert_submodule_refused("symlink escapes")

    def test_submodule_change_after_preflight_has_no_output(self):
        _, module = self.add_submodule()
        plan, repos, inventories, root = candidate.collect_plan(
            make_args(self.source, self.output_parent)
        )
        (module / "source.txt").write_text("changed after preflight\n")
        with self.assertRaisesRegex(candidate.CandidateError, "dirty/untracked"):
            candidate.stage_candidate(plan, repos, inventories, root)
        self.assertFalse(root.exists())

    def test_submodule_private_key_content_rejected(self):
        parent, module = self.add_submodule()
        (module / "source.txt").write_text("-----BEGIN PRIVATE KEY-----\nsynthetic\n")
        git(module, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "-am", "synthetic forbidden content")
        git(parent, "add", "module")
        git(parent, "commit", "-m", "pin forbidden content")
        self.assert_submodule_refused("private-key material")

    def test_submodule_allowlist_cannot_override_dirty_state(self):
        _, module = self.add_submodule()
        (module / "source.txt").write_text("dirty\n")
        args = make_args(self.source, self.output_parent,
                         include_dirty=["zpr-common:module"])
        with self.assertRaisesRegex(candidate.CandidateError, "dirty/untracked"):
            candidate.collect_plan(args)
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def test_submodule_gitmodules_gitlink_mismatch_rejected(self):
        parent, _ = self.add_submodule()
        (parent / ".gitmodules").write_text('[submodule "module"]\npath = other\n')
        git(parent, "commit", "-am", "mismatching module path")
        self.assert_submodule_refused("paths do not match pinned gitlinks")

    def test_blocked_report_is_complete_and_content_redacted(self):
        header = b"-----BEGIN PRIVATE KEY-----"
        repo = self.source / "zpr-utils"
        (repo / "marker.rs").write_bytes(b'const HEADER = "' + header + b'";\n')
        payload = b"SyntheticFixturePayloadNotAnActualKey1234567890"
        (repo / "fixture.rs").write_bytes(header + b"\n" + payload + b"\n")
        git(repo, "add", ".")
        git(repo, "commit", "-m", "synthetic scanner cases")
        args = make_args(self.source, self.output_parent, preflight_report=True)
        plan, repos, inventories, root = candidate.collect_plan(args, run_id="blocked")
        self.assertFalse(plan["source_preflight_passed"])
        self.assertEqual(len(plan["findings"]), 2)
        self.assertEqual(
            {item["category"] for item in plan["findings"]},
            {"private-key PEM payload-shaped content", "private-key header reference (unadjudicated)"},
        )
        rendered = json.dumps(plan).encode()
        self.assertNotIn(header, rendered)
        self.assertNotIn(payload, rendered)
        self.assertTrue(plan["commands"])
        self.assertEqual(plan["approved_dirty"], [])
        self.assertEqual(plan["approved_untracked"], [])
        calls = mock.Mock()
        with self.assertRaisesRegex(candidate.CandidateError, "blocked"):
            candidate.execute_plan(plan, repos, inventories, root, runner=calls)
        calls.assert_not_called()
        self.assertFalse(root.exists())

    def test_approved_fixture_replacement_scans_only_selected_source_and_redacts_diff(self):
        repo = self.source / "zpr-utils"
        path = repo / "fixture.rs"
        historical = (
            b"-----BEGIN PRIVATE KEY-----\n"
            b"SyntheticHistoricalPayloadNotAnActualKey1234567890\n"
            b"-----END PRIVATE KEY-----\n"
        )
        path.write_bytes(historical)
        git(repo, "add", "fixture.rs")
        git(repo, "commit", "-m", "synthetic historical fixture")
        replacement = b"fn test_material() { generate_at_runtime(); }\n"
        path.write_bytes(replacement)
        args = make_args(
            self.source, self.output_parent,
            include_dirty=["zpr-utils:fixture.rs"],
        )
        plan, repos, inventories, root = candidate.collect_plan(args)
        entry = find_included(plan, "zpr-utils", "fixture.rs")
        self.assertTrue(plan["source_preflight_passed"])
        self.assertEqual(entry["sha256"], candidate.hashlib.sha256(replacement).hexdigest())
        diff = subprocess.check_output(["git", "-C", str(repo), "diff", "--binary", "HEAD", "--", "fixture.rs"])
        self.assertEqual(entry["diff_sha256"], candidate.hashlib.sha256(diff).hexdigest())
        self.assertEqual(entry["diff_base64"], "")
        self.assertEqual(entry["diff_redaction"], "historical source safety rejection; hash only")
        self.assertNotIn("SyntheticHistoricalPayload", json.dumps(plan))
        with mock.patch.object(candidate, "write_file", wraps=candidate.write_file) as writes:
            source, _ = candidate.stage_candidate(plan, repos, inventories, root)
        for call in writes.call_args_list:
            self.assertNotIn(b"SyntheticHistoricalPayload", call.args[1])
        self.assertEqual((source / "zpr-utils/fixture.rs").read_bytes(), replacement)
        self.assertNotIn("SyntheticHistoricalPayload", (root / "provenance.json").read_text())

    def test_fixture_replacement_without_approval_and_unsafe_replacement_stay_blocked(self):
        repo = self.source / "zpr-utils"
        path = repo / "fixture.rs"
        historical = b"-----BEGIN PRIVATE KEY-----\nSyntheticUnknownPayloadNotAnActualKey1234567890\n"
        path.write_bytes(historical)
        git(repo, "add", "fixture.rs")
        git(repo, "commit", "-m", "synthetic historical fixture")
        path.write_text("safe runtime generator\n")
        with self.assertRaisesRegex(candidate.CandidateError, "private-key material"):
            candidate.collect_plan(make_args(self.source, self.output_parent))
        path.write_bytes(historical + b"still embedded\n")
        with self.assertRaisesRegex(candidate.CandidateError, "private-key material"):
            candidate.collect_plan(make_args(
                self.source, self.output_parent,
                include_dirty=["zpr-utils:fixture.rs"],
            ))
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def test_approved_fixture_deletion_never_stages_historical_bytes(self):
        repo = self.source / "zpr-utils"
        path = repo / "fixture.rs"
        historical = b"-----BEGIN PRIVATE KEY-----\nSyntheticDeletedPayloadNotAnActualKey1234567890\n"
        path.write_bytes(historical)
        git(repo, "add", "fixture.rs")
        git(repo, "commit", "-m", "synthetic historical fixture")
        path.unlink()
        plan, repos, inventories, root = candidate.collect_plan(make_args(
            self.source, self.output_parent,
            include_dirty=["zpr-utils:fixture.rs"],
        ))
        self.assertEqual(find_included(plan, "zpr-utils", "fixture.rs")["kind"], "deleted")
        with mock.patch.object(candidate, "write_file", wraps=candidate.write_file) as writes:
            source, _ = candidate.stage_candidate(plan, repos, inventories, root)
        self.assertFalse((source / "zpr-utils/fixture.rs").exists())
        for call in writes.call_args_list:
            self.assertNotIn(b"SyntheticDeletedPayload", call.args[1])

    def test_selected_makefile_requires_unique_builder_tag_support(self):
        repo = self.source / "zpr-demo"
        path = repo / "multinode-demo/Makefile"
        path.write_text("linux-amd64:\n\tdocker build -t fixed-tag .\n")
        git(repo, "commit", "-am", "unsafe fixed tag")
        self.assert_submodule_refused("builder-tag isolation")

    def test_allowlisted_deleted_required_file_is_missing(self):
        repo = self.source / "zpr-demo"
        (repo / "multinode-demo/Dockerfile").unlink()
        with self.assertRaisesRegex(candidate.CandidateError, "required build input missing"):
            candidate.collect_plan(make_args(
                self.source, self.output_parent,
                include_dirty=["zpr-demo:multinode-demo/Dockerfile"],
            ))
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def test_changed_dirty_file_is_rejected_before_output(self):
        file = self.source / "zpr-demo/multinode-demo/README.md"
        file.write_text("approved change\n")
        plan, repos, inventories, root = candidate.collect_plan(make_args(
            self.source, self.output_parent,
            include_dirty=["zpr-demo:multinode-demo/README.md"],
        ))
        file.write_text("not approved after preflight\n")
        with self.assertRaisesRegex(candidate.CandidateError, "changed after preflight"):
            candidate.stage_candidate(plan, repos, inventories, root)
        self.assertFalse(root.exists())

    def test_allowlisted_untracked_symlink_parent_is_rejected(self):
        repo = self.source / "zpr-demo"
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "input.txt").write_text("synthetic outside content\n")
        (repo / "escape").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(candidate.CandidateError, "symlinked worktree input"):
            candidate.worktree_input(repo, "escape/input.txt")
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def test_missing_tool_is_reported_without_docker_or_writes(self):
        with mock.patch.object(candidate.shutil, "which", side_effect=lambda name: None if name == "docker" else "/synthetic/" + name):
            plan, _, _, root = candidate.collect_plan(make_args(
                self.source, self.output_parent, preflight_report=True,
            ))
        self.assertIn("required build tool is missing: docker", plan["blockers"])
        self.assertFalse(root.exists())

    def test_unavailable_docker_has_no_staging_side_effect(self):
        plan, repos, inventories, root = candidate.collect_plan(make_args(self.source, self.output_parent))
        calls = []

        def unavailable(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 1, "", "synthetic unavailable daemon")

        with self.assertRaisesRegex(candidate.CandidateError, "daemon is unavailable"):
            candidate.execute_plan(plan, repos, inventories, root, runner=unavailable)
        self.assertEqual(calls, [["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]])
        self.assertFalse(root.exists())

    def test_fake_builder_records_pair_identity_and_artifact_hashes(self):
        plan, repos, inventories, root = candidate.collect_plan(make_args(self.source, self.output_parent))
        before = {name: candidate.run_git(repo, "status", "--porcelain") for name, repo in repos.items()}
        calls = []
        packaged = False
        header = b"\x7fELF\x02\x01" + b"\0" * 12 + b"\x3e\x00"

        def fake_builder(command, **kwargs):
            nonlocal packaged
            calls.append(command)
            output = ""
            if command[:3] == ["docker", "context", "inspect"]:
                output = "unix:///synthetic/docker.sock\n"
            elif command[:3] == ["docker", "image", "inspect"]:
                if not packaged:
                    return subprocess.CompletedProcess(command, 1, "", "No such image")
                output = json.dumps([{"Id": "sha256:" + "a" * 64, "Os": "linux", "Architecture": "amd64"}])
            elif command == ["go", "version"]:
                self.assertEqual(kwargs["env"]["GOTOOLCHAIN"], "local")
                output = "go version go1.27.1 synthetic/amd64\n"
            elif command[0] == "make":
                directory = root / "source/zpr-demo/multinode-demo/bin"
                directory.mkdir()
                for name in candidate.BINARIES:
                    (directory / name).write_bytes(header + b"synthetic fake executable")
            elif command[0] == "python3" and command[2] == "build":
                for path in plan["artifact_paths"]:
                    Path(path).write_bytes(b"synthetic fake packaged output\n")
                packaged = True
            return subprocess.CompletedProcess(command, 0, output, "")

        candidate.execute_plan(plan, repos, inventories, root, runner=fake_builder)
        result = json.loads((root / "build-results.json").read_text())
        self.assertTrue(result["pair_verified"])
        self.assertFalse(result["byte_reproducible"])
        self.assertEqual(result["images"]["zpr"]["id"], "sha256:" + "a" * 64)
        self.assertEqual(len(result["sha256"]), len(candidate.BINARIES) + 4)
        self.assertIn(plan["commands"][-1], calls)
        self.assertEqual(before, {name: candidate.run_git(repo, "status", "--porcelain") for name, repo in repos.items()})

    def test_report_cannot_execute(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(candidate.main([
                "--source-root", str(self.source), "--output-parent", str(self.output_parent),
                "--release-id", "invalid-mode", "--preflight-report", "--execute",
            ]), 1)
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def test_invalid_arguments_and_output_paths_do_not_write(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as missing:
                candidate.main([])
        self.assertEqual(missing.exception.code, 2)
        for release in ("../escape", "invalid/tag", ""):
            with self.subTest(release=release):
                with self.assertRaisesRegex(candidate.CandidateError, "release ID"):
                    candidate.collect_plan(make_args(self.source, self.output_parent, release_id=release))
        unsafe = self.base / "unsafe$path"
        unsafe.mkdir()
        with self.assertRaisesRegex(candidate.CandidateError, "unsafe for Make/Docker"):
            candidate.collect_plan(make_args(self.source, unsafe))
        self.assertEqual(list(self.output_parent.iterdir()), [])
        self.assertEqual(list(unsafe.iterdir()), [])

    def test_private_directory_and_environment_variants_cannot_be_allowlisted(self):
        repo = self.source / "zpr-demo"
        for relative in ("credentials/input.txt", ".env.production"):
            with self.subTest(relative=relative):
                file = repo / relative
                file.parent.mkdir(exist_ok=True)
                file.write_text("synthetic excluded data\n")
                with self.assertRaisesRegex(candidate.CandidateError, "cannot allowlist excluded"):
                    candidate.collect_plan(make_args(
                        self.source, self.output_parent,
                        include_untracked=["zpr-demo:" + relative],
                    ))
        self.assertEqual(list(self.output_parent.iterdir()), [])

    def test_existing_tag_refused_before_staging(self):
        plan, repos, inventories, root = candidate.collect_plan(make_args(self.source, self.output_parent))

        def existing(command, **kwargs):
            if command[1:3] == ["context", "inspect"]:
                return subprocess.CompletedProcess(command, 0, "unix:///synthetic/docker.sock\n", "")
            return subprocess.CompletedProcess(command, 0, "synthetic existing image", "")

        with self.assertRaisesRegex(candidate.CandidateError, "refusing to overwrite"):
            candidate.execute_plan(plan, repos, inventories, root, runner=existing)
        self.assertFalse(root.exists())

    def test_approved_mode_change_after_preflight_has_no_output(self):
        file = self.source / "zpr-demo/multinode-demo/README.md"
        file.write_text("approved content\n")
        file.chmod(0o644)
        plan, repos, inventories, root = candidate.collect_plan(make_args(
            self.source, self.output_parent,
            include_dirty=["zpr-demo:multinode-demo/README.md"],
        ))
        file.chmod(0o755)
        with self.assertRaisesRegex(candidate.CandidateError, "changed after preflight"):
            candidate.stage_candidate(plan, repos, inventories, root)
        self.assertFalse(root.exists())

    def test_documentation_header_is_not_embedded_private_key(self):
        data = b'/// File must begin with `-----BEGIN PRIVATE KEY-----`.\nfn load() {}\n'
        self.assertEqual(
            candidate.scan_content(data, "synthetic", "src/crypto.rs"),
            candidate.hashlib.sha256(data).hexdigest(),
        )
        masked, references = candidate.private_key_content(data, "src/crypto.rs")
        self.assertNotRegex(masked, candidate.PRIVATE_KEY_HEADER)
        self.assertEqual(references[0]["line"], 1)
        with self.assertRaises(candidate.CandidateError):
            candidate.scan_content(data, "synthetic", "unknown.txt")

    def test_exact_stdin_generator_is_not_embedded_private_key(self):
        data = (
            b'#!/usr/bin/env bash\nfunction from_raw() {\n'
            b'\techo "-----BEGIN PRIVATE KEY-----"\n'
            rb"\t{ echo -en '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'; base64 -d; } | base64".replace(rb"\t", b"\t")
            + b'\n\techo "-----END PRIVATE KEY-----"\n}\n'
        )
        self.assertEqual(candidate.scan_content(data, "synthetic", "helper"),
                         candidate.hashlib.sha256(data).hexdigest())
        self.assertEqual(len(candidate.private_key_content(data, "helper")[1]), 1)
        for changed in (
            data.replace(b"base64 -d;", b"echo arbitrary_payload;"),
            data.replace(rb"\x30\x2e", rb"\x31\x2e"),
            data + b'echo "-----BEGIN PRIVATE KEY-----\\nUnknownPayload\\n-----END PRIVATE KEY-----"\n',
        ):
            with self.subTest(changed_hash=candidate.hashlib.sha256(changed).hexdigest()):
                with self.assertRaises(candidate.CandidateError):
                    candidate.scan_content(changed, "synthetic", "helper")

    def test_private_payloads_stay_blocked_in_test_code_and_escaped_strings(self):
        header = b"-----BEGIN PRIVATE KEY-----"
        end = b"-----END PRIVATE KEY-----"
        payload = b"UnknownSyntheticPayloadNotUsableAsAKey12345678"
        cases = [
            header + b"\n" + payload + b"\n" + end,
            b'const KEY: &str = "' + header + rb"\n" + payload + rb"\n" + end + b'";',
            b'#[cfg(test)]\nmod tests {\nconst KEY: &str = r#"' + header + b"\n" + payload + b"\n" + end + b'"#;\n}',
            b'/// Header `' + header + b'`.\n/// ' + payload + b"\n",
            b'/// Header `' + header + b'`.\n' + end,
        ]
        for data in cases:
            with self.subTest(content_hash=candidate.hashlib.sha256(data).hexdigest()):
                with self.assertRaisesRegex(candidate.CandidateError, "private-key material"):
                    candidate.scan_content(data, "synthetic", "src/test.rs")

    def test_accepted_reference_provenance_and_unknown_fixture_blocker(self):
        repo = self.source / "zpr-utils"
        source = repo / "header.rs"
        data = b'/// Begins with `-----BEGIN PRIVATE KEY-----`.\n'
        source.write_bytes(data)
        git(repo, "add", "header.rs")
        git(repo, "commit", "-m", "synthetic documentation")
        plan, repos, inventories, root = candidate.collect_plan(make_args(self.source, self.output_parent))
        entry = find_included(plan, "zpr-utils", "header.rs")
        self.assertEqual(len(entry["content_references"]), 1)
        staged, _ = candidate.stage_candidate(plan, repos, inventories, root)
        self.assertEqual((staged / "zpr-utils/header.rs").read_bytes(), data)

    def test_remote_docker_is_rejected_before_daemon_or_staging(self):
        plan, repos, inventories, root = candidate.collect_plan(make_args(self.source, self.output_parent))
        calls = []

        def remote(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, "ssh://remote.synthetic.invalid\n", "")

        with mock.patch.dict(candidate.os.environ, {"DOCKER_HOST": ""}):
            with self.assertRaisesRegex(candidate.CandidateError, "nonlocal Docker context"):
                candidate.execute_plan(plan, repos, inventories, root, runner=remote)
        self.assertEqual(len(calls), 1)
        self.assertFalse(root.exists())
        calls.clear()
        with mock.patch.dict(candidate.os.environ, {"DOCKER_HOST": "tcp://remote.synthetic.invalid:2376"}):
            with self.assertRaisesRegex(candidate.CandidateError, "nonlocal DOCKER_HOST"):
                candidate.execute_plan(plan, repos, inventories, root, runner=remote)
        self.assertEqual(calls, [])
        self.assertFalse(root.exists())


def git_output(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ).stdout.strip()


if __name__ == "__main__":
    unittest.main()
