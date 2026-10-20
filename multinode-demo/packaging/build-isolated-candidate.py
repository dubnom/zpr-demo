#!/usr/bin/env python3
"""Stage an explicitly reviewed source snapshot and build an isolated demo candidate."""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import uuid


REPOSITORIES = (
    "zpr-common",
    "zpr-core",
    "zpr-utils",
    "zpr-compiler",
    "zpr-dev-tools",
    "zpr-visaservice",
    "zpr-demo",
)
ARTIFACT_SEGMENTS = {
    ".aws", ".azure", ".cache", ".git", ".next", ".pytest_cache", ".ssh", ".venv", "__pycache__",
    "bin", "build", "coverage", "dist", "node_modules", "target", "venv",
}
PRIVATE_NAME_PARTS = ("credential", "private", "secret")
PRIVATE_FILENAMES = {
    ".env", ".netrc", ".npmrc", ".pypirc", "credentials", "credentials.json",
    "id_dsa", "id_ecdsa", "id_ed25519", "id_rsa", "secrets.json",
}
PRIVATE_SUFFIXES = (".key", ".p12", ".pfx", ".pem", ".pkey", ".jks")
PRIVATE_KEY_HEADER = re.compile(
    rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"
)
PRIVATE_KEY_END = re.compile(
    rb"-----END (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"
)
RELEASE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z")
MAX_INVENTORY_FILE_SIZE = 256 * 1024 * 1024
BINARIES = ("ph", "ph-cli", "vs", "vs-admin", "vsapikey", "zplc", "zpdump",
            "zpr-dashboard", "zpr-web-dashboard")


class CandidateError(Exception):
    pass


def run_git(repo, *arguments, binary=False):
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise CandidateError(f"git {' '.join(arguments)} failed in {repo}: {detail}")
    return result.stdout if binary else result.stdout.decode("utf-8", errors="strict")


def require_safe_relative(value, label):
    path = PurePosixPath(value)
    if (
        not value
        or "\\" in value
        or path.is_absolute()
        or any(part in ("", ".", "..") for part in value.split("/"))
    ):
        raise CandidateError(f"{label} must be a safe repository-relative path: {value!r}")
    return path


def split_allowlist(values, label):
    result = set()
    for value in values:
        if ":" not in value:
            raise CandidateError(f"{label} must use repo:path form: {value!r}")
        repository, relative = value.split(":", 1)
        if repository not in REPOSITORIES:
            raise CandidateError(f"{label} names an unknown repository: {repository!r}")
        require_safe_relative(relative, label)
        item = f"{repository}/{relative}"
        if item in result:
            raise CandidateError(f"duplicate {label} entry: {item}")
        result.add(item)
    return result


def exclusion_reason(repository, relative):
    path = PurePosixPath(relative)
    parts = tuple(part.lower() for part in path.parts)
    if ".local-runtime" in parts:
        return "local runtime state"
    if any(part in ARTIFACT_SEGMENTS for part in parts):
        return "cache or build artifact"
    name = path.name.lower()
    if (
        name in PRIVATE_FILENAMES
        or name.startswith(".env")
        or name.endswith(".env")
        or name.endswith(PRIVATE_SUFFIXES)
        or any(token in part for part in parts for token in PRIVATE_NAME_PARTS)
    ):
        return "credential or private-key path"
    if repository in ("zpr-demo", "zpr-visaservice") and parts[-1:] == (".DS_Store".lower(),):
        return "operating-system metadata"
    return ""


def check_repo_layout(source_root):
    source_root = Path(source_root)
    if source_root.is_symlink():
        raise CandidateError("source root must not be a symlink")
    source_root = source_root.resolve(strict=True)
    if not source_root.is_dir():
        raise CandidateError("source root must be a directory")
    repos = {}
    for name in REPOSITORIES:
        path = source_root / name
        if path.is_symlink() or not path.is_dir():
            raise CandidateError(f"required repository directory is missing or symlinked: {path}")
        top = Path(run_git(path, "rev-parse", "--show-toplevel").strip()).resolve(strict=True)
        if top != path.resolve(strict=True):
            raise CandidateError(f"repository {name} resolves to unexpected root {top}")
        repos[name] = path
    return source_root, repos


def parse_tree(repo, revision="HEAD"):
    records = run_git(repo, "ls-tree", "-r", "-z", revision, binary=True).split(b"\0")
    result = {}
    for record in records:
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8", errors="strict")
        require_safe_relative(path, "tracked path")
        if mode == "160000" and object_type == "commit":
            result[path] = {"mode": mode, "object": object_id}
            continue
        if mode not in ("100644", "100755", "120000") or object_type != "blob":
            raise CandidateError(f"unsupported tracked file mode {mode}: {repo.name}/{path}")
        result[path] = {"mode": mode, "object": object_id}
    return result


def parse_status(repo):
    raw = run_git(
        repo,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignore-submodules=none",
        binary=True,
    )
    records = raw.split(b"\0")
    tracked, untracked = set(), set()
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        if not record:
            continue
        if len(record) < 4 or record[2:3] != b" ":
            raise CandidateError(f"cannot parse git status record in {repo}")
        status = record[:2].decode("ascii")
        path = record[3:].decode("utf-8", errors="strict")
        if status == "??":
            untracked.add(path)
            continue
        if "R" in status or "C" in status:
            raise CandidateError(f"renamed or copied worktree paths are not accepted: {repo.name}/{path}")
        tracked.add(path)
    return tracked, untracked


def verify_submodules(repo, repository, tree, revision="HEAD", findings=None):
    links = {path: entry for path, entry in tree.items() if entry["mode"] == "160000"}
    if not links:
        return []
    if ".gitmodules" not in tree or tree[".gitmodules"]["mode"] != "100644":
        raise CandidateError(f"missing or malformed .gitmodules: {repository}")
    records = run_git(
        repo, "config", "--null", "--blob", f"{revision}:.gitmodules",
        "--get-regexp", r"^submodule\..*\.path$",
    ).split("\0")
    configured = []
    for record in filter(None, records):
        if "\n" not in record:
            raise CandidateError(f"malformed submodule configuration: {repository}")
        _, path = record.split("\n", 1)
        require_safe_relative(path, "submodule path")
        configured.append(path)
    if len(set(configured)) != len(configured) or set(configured) != set(links):
        raise CandidateError(f"submodule paths do not match pinned gitlinks: {repository}")
    verified = []
    for relative, entry in sorted(links.items()):
        label = f"{repository}/{relative}"
        reason = exclusion_reason(repository, relative)
        if reason:
            raise CandidateError(f"excluded submodule {reason}: {label}")
        path = repo / relative
        if any((repo / Path(*PurePosixPath(relative).parts[:index])).is_symlink()
               for index in range(1, len(PurePosixPath(relative).parts) + 1)):
            raise CandidateError(f"symlinked submodule path rejected: {label}")
        if not path.is_dir() or not (path / ".git").exists():
            raise CandidateError(f"submodule is uninitialized: {label}")
        if (path / ".git").is_symlink():
            raise CandidateError(f"symlinked submodule metadata rejected: {label}")
        top = Path(run_git(path, "rev-parse", "--show-toplevel").strip()).resolve()
        if top != path.resolve():
            raise CandidateError(f"submodule has unexpected repository root: {label}")
        observed = run_git(path, "rev-parse", "HEAD").strip()
        if observed != entry["object"]:
            raise CandidateError(f"submodule HEAD mismatches pinned gitlink: {label}")
        dirty, untracked = parse_status(path)
        ignored = run_git(path, "ls-files", "--others", "--ignored", "--exclude-standard", "-z")
        if dirty or untracked or ignored:
            raise CandidateError(f"submodule has dirty/untracked state: {label}")
        child_tree = parse_tree(path, observed)
        if any(item["mode"] == "160000" for item in child_tree.values()):
            raise CandidateError(f"nested submodules are not accepted: {label}")
        planned, excluded = archive_inventory(
            path, label, child_tree, set(), set(), set(), set(), observed, findings,
        )
        verified.append({
            "path": relative,
            "pinned_gitlink": entry["object"],
            "observed_head": observed,
            "initialized": True,
            "tree": run_git(path, "rev-parse", f"{observed}^{{tree}}").strip(),
            "included": planned,
            "excluded": excluded,
        })
    return verified


def validate_symlink(relative, target, repository):
    if not target or target.startswith("/"):
        raise CandidateError(f"absolute or empty symlink target rejected: {repository}/{relative}")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), target))
    if resolved == ".." or resolved.startswith("../"):
        raise CandidateError(f"symlink escapes repository: {repository}/{relative} -> {target}")
    require_safe_relative(resolved, "symlink target")
    reason = exclusion_reason(repository, resolved)
    if reason:
        raise CandidateError(f"symlink targets excluded {reason}: {repository}/{relative}")


def resolve_symlink_chain(relative, target, symlinks, tracked_paths, repository):
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), target))
    visited = set()
    for _ in range(len(symlinks) + 1):
        if resolved in ("", ".", "..") or resolved.startswith("../"):
            raise CandidateError(f"symlink escapes repository: {repository}/{relative} -> {target}")
        require_safe_relative(resolved, "symlink target")
        reason = exclusion_reason(repository, resolved)
        if reason:
            raise CandidateError(f"symlink targets excluded {reason}: {repository}/{relative}")
        if resolved in symlinks:
            if resolved in visited:
                raise CandidateError(f"symlink cycle rejected: {repository}/{relative}")
            visited.add(resolved)
            next_target = symlinks[resolved]
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(resolved), next_target)
            )
            continue
        prefix_link = next(
            (
                path for path in symlinks
                if resolved.startswith(path + "/")
            ),
            None,
        )
        if prefix_link:
            if prefix_link in visited:
                raise CandidateError(f"symlink cycle rejected: {repository}/{relative}")
            visited.add(prefix_link)
            suffix = resolved[len(prefix_link) + 1:]
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(prefix_link), symlinks[prefix_link], suffix)
            )
            continue
        if resolved not in tracked_paths and not any(
            path.startswith(resolved + "/") for path in tracked_paths
        ):
            raise CandidateError(f"symlink target is not tracked: {repository}/{relative} -> {target}")
        return
    raise CandidateError(f"symlink chain is too deep: {repository}/{relative}")


def private_key_content(data, relative):
    masked = data
    references = []
    if re.match(rb"#![^\n]*(?:/bash|/sh|env bash|env sh)(?:\r?\n|$)", data):
        generator = re.compile(
            rb'^[ \t]*echo "-----BEGIN PRIVATE KEY-----"\r?\n'
            rb"[ \t]*\{ echo -en '"
            + re.escape(rb"\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20")
            + rb"'; base64 -d; \} \| base64\r?\n"
            rb'[ \t]*echo "-----END PRIVATE KEY-----"[ \t]*$',
            re.MULTILINE,
        )
        for match in generator.finditer(data):
            references.append({
                "line": data[:match.start()].count(b"\n") + 1,
                "role": "PEM generator: fixed X25519 DER prefix plus stdin, no embedded key payload",
            })
        masked = generator.sub(lambda match: b" " * len(match.group()), masked)
    # A complete PEM end marker prevents treating any Rust header as documentation.
    if (
        PurePosixPath(relative).suffix == ".rs"
        and not PRIVATE_KEY_END.search(masked)
        and not re.search(rb"(?m)^[ \t]*(?:///|//|\*)?[ \t]*[A-Za-z0-9+/=]{32,}[ \t]*$", masked)
    ):
        documentation = re.compile(
            rb"^[ \t]*///[^\r\n`]*`"
            + PRIVATE_KEY_HEADER.pattern
            + rb"`[ \t.]*$",
            re.MULTILINE,
        )
        for match in documentation.finditer(masked):
            references.append({
                "line": data[:match.start()].count(b"\n") + 1,
                "role": "Rust documentation header token only; no PEM end marker",
            })
        masked = documentation.sub(lambda match: b" " * len(match.group()), masked)
    return masked, references


def scan_content(data, repository, relative):
    if len(data) > MAX_INVENTORY_FILE_SIZE:
        raise CandidateError(f"source file exceeds inventory safety limit: {repository}/{relative}")
    masked, _ = private_key_content(data, relative)
    if PRIVATE_KEY_HEADER.search(masked):
        raise CandidateError(f"private-key material detected in source: {repository}/{relative}")
    return hashlib.sha256(data).hexdigest()


def inspect_content(data, repository, relative, findings):
    try:
        return scan_content(data, repository, relative)
    except CandidateError as error:
        if findings is None:
            raise
        masked, _ = private_key_content(data, relative)
        markers = list(PRIVATE_KEY_HEADER.finditer(masked))
        payload = any(
            re.match(rb"(?:\r?\n|\\n)[A-Za-z0-9+/=]{32,}(?:\r?\n|\\n|$)", data[match.end():])
            for match in markers
        )
        findings.append({
            "path": f"{repository}/{relative}",
            "category": (
                "private-key PEM payload-shaped content" if payload else
                "private-key header reference (unadjudicated)" if markers else
                "source size safety limit"
            ),
            "lines": [data[:match.start()].count(b"\n") + 1 for match in markers],
            "sha256": hashlib.sha256(data).hexdigest(),
            "message": str(error),
            "contents": "redacted",
        })
        return None


def worktree_input(repo, relative):
    parts = require_safe_relative(relative, "worktree input").parts
    for index in range(1, len(parts) + 1):
        if (repo / Path(*parts[:index])).is_symlink():
            raise CandidateError(f"symlinked worktree input rejected: {repo.name}/{relative}")
    return repo / relative


def archive_inventory(repo, repository, tree, tracked_dirty, untracked, dirty_allowlist, untracked_allowlist, revision="HEAD", findings=None):
    dirty_allowlist_here = {entry[len(repository) + 1:] for entry in dirty_allowlist if entry.startswith(repository + "/")}
    untracked_allowlist_here = {entry[len(repository) + 1:] for entry in untracked_allowlist if entry.startswith(repository + "/")}
    if not dirty_allowlist_here.issubset(tracked_dirty):
        invalid = sorted(dirty_allowlist_here - tracked_dirty)
        raise CandidateError(f"tracked allowlist entries are not modified tracked files: {invalid}")
    if not untracked_allowlist_here.issubset(untracked):
        invalid = sorted(untracked_allowlist_here - untracked)
        raise CandidateError(f"untracked allowlist entries are not untracked files: {invalid}")
    for path in dirty_allowlist_here | untracked_allowlist_here:
        reason = exclusion_reason(repository, path)
        if reason:
            raise CandidateError(f"cannot allowlist excluded {reason}: {repository}/{path}")

    archived = run_git(repo, "archive", "--format=tar", revision, binary=True)
    symlinks = {}
    excluded = []
    planned = []
    try:
        archive = tarfile.open(fileobj=io.BytesIO(archived), mode="r:")
        with archive:
            for member in archive:
                relative = member.name.rstrip("/")
                if not relative:
                    continue
                require_safe_relative(relative, "archive path")
                if member.isdir():
                    continue
                if member.issym():
                    if relative in dirty_allowlist_here:
                        raise CandidateError(f"dirty allowlisted symlinks are not accepted: {repository}/{relative}")
                    validate_symlink(relative, member.linkname, repository)
                    reason = exclusion_reason(repository, relative)
                    if reason:
                        if reason == "local runtime state":
                            raise CandidateError(
                                f"tracked local runtime input is forbidden: {repository}/{relative}"
                            )
                        excluded.append({"path": f"{repository}/{relative}", "reason": reason})
                        continue
                    symlinks[relative] = member.linkname
                    planned.append({
                        "path": f"{repository}/{relative}",
                        "sha256": hashlib.sha256(member.linkname.encode("utf-8")).hexdigest(),
                        "kind": "symlink",
                        "target": member.linkname,
                        "dirty": False,
                    })
                    continue
                if not member.isfile():
                    raise CandidateError(f"unsupported archive entry: {repository}/{relative}")
                if relative not in tree:
                    raise CandidateError(f"archive contains a path absent from HEAD tree: {repository}/{relative}")
                reason = exclusion_reason(repository, relative)
                if reason:
                    if reason == "local runtime state":
                        raise CandidateError(
                            f"tracked local runtime input is forbidden: {repository}/{relative}"
                        )
                    excluded.append({"path": f"{repository}/{relative}", "reason": reason})
                    continue
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise CandidateError(f"cannot read archived file: {repository}/{relative}")
                data = extracted.read(MAX_INVENTORY_FILE_SIZE + 1)
                is_dirty = relative in dirty_allowlist_here
                if is_dirty:
                    current = worktree_input(repo, relative)
                    if current.is_symlink():
                        target = os.readlink(current)
                        validate_symlink(relative, target, repository)
                        if not current.exists():
                            raise CandidateError(f"allowlisted symlink is broken: {repository}/{relative}")
                        raise CandidateError(f"dirty allowlisted symlinks are not accepted: {repository}/{relative}")
                    if not current.is_file():
                        if not current.exists():
                            planned.append({
                                "path": f"{repository}/{relative}",
                                "kind": "deleted",
                                "dirty": True,
                            })
                            continue
                        raise CandidateError(
                            f"allowlisted tracked input is not a regular file: {repository}/{relative}"
                        )
                    dirty_data = current.read_bytes()
                    digest = inspect_content(dirty_data, repository, relative, findings)
                else:
                    digest = inspect_content(data, repository, relative, findings)
                if digest is None:
                    excluded.append({"path": f"{repository}/{relative}", "reason": "source safety rejection"})
                    continue
                patch = ""
                patch_redaction = ""
                patch_encoded = ""
                if is_dirty:
                    patch = run_git(
                        repo, "diff", "--binary", "HEAD", "--", relative, binary=True
                    ).decode("latin-1")
                    # Removed historical material must not leak through provenance.
                    if inspect_content(patch.encode("latin-1"), repository, relative, []) is None:
                        patch_redaction = "historical source safety rejection; hash only"
                    else:
                        patch_encoded = base64.b64encode(patch.encode("latin-1")).decode("ascii")
                    if scan_content(current.read_bytes(), repository, relative) != digest:
                        raise CandidateError(f"allowlisted input changed during preflight: {repository}/{relative}")
                planned.append({
                    "path": f"{repository}/{relative}",
                    "sha256": digest,
                    "kind": "file",
                    "dirty": is_dirty,
                    "mode": (
                        "100755" if current.stat().st_mode & 0o111 else "100644"
                    ) if is_dirty else tree[relative]["mode"],
                    "diff_sha256": hashlib.sha256(patch.encode("latin-1")).hexdigest() if is_dirty else "",
                    "diff_base64": patch_encoded,
                    "diff_redaction": patch_redaction,
                    "content_references": private_key_content(
                        dirty_data if is_dirty else data, relative,
                    )[1],
                })
    except tarfile.TarError as exc:
        raise CandidateError(f"cannot inspect Git archive for {repository}: {exc}") from exc

    for relative, target in symlinks.items():
        resolve_symlink_chain(relative, target, symlinks, set(tree), repository)

    for relative in sorted(untracked):
        if relative not in untracked_allowlist_here:
            excluded.append({
                "path": f"{repository}/{relative}",
                "reason": exclusion_reason(repository, relative) or "unapproved untracked input",
                "untracked": True,
            })
            continue
        require_safe_relative(relative, "untracked path")
        reason = exclusion_reason(repository, relative)
        if reason:
            raise CandidateError(f"cannot allowlist excluded {reason}: {repository}/{relative}")
        current = worktree_input(repo, relative)
        if current.is_symlink() or not current.is_file():
            raise CandidateError(f"allowlisted untracked input must be a regular file: {repository}/{relative}")
        digest = inspect_content(current.read_bytes(), repository, relative, findings)
        if digest is None:
            excluded.append({"path": f"{repository}/{relative}", "reason": "source safety rejection"})
            continue
        planned.append({
            "path": f"{repository}/{relative}",
            "sha256": digest,
            "kind": "file",
            "dirty": True,
            "untracked": True,
            "mode": "100755" if current.stat().st_mode & 0o111 else "100644",
            "content_references": private_key_content(current.read_bytes(), relative)[1],
        })
    return planned, excluded


def validate_required_inputs(source_root, repos, inventories):
    missing = []
    required = {
        "zpr-core": ("Cargo.toml", "adapter/ph/Cargo.toml", "adapter/cli/Cargo.toml"),
        "zpr-common": ("Cargo.toml",),
        "zpr-utils": ("zpr-utils/Cargo.toml",),
        "zpr-compiler": ("Cargo.toml",),
        "zpr-dev-tools": ("docker/dev-env/Dockerfile",),
        "zpr-visaservice": ("Cargo.toml", "zpr-dashboard/go.mod", "zpr-dashboard/go.sum"),
        "zpr-demo": (
            "multinode-demo/Makefile",
            "multinode-demo/Dockerfile.build-linux",
            "multinode-demo/build-linux-amd64.sh",
            "multinode-demo/Dockerfile",
            "multinode-demo/packaging/package-demo-images.py",
        ),
    }
    for repository, paths in required.items():
        included = {
            item["path"][len(repository) + 1:] for item in inventories[repository][0]
            if item["kind"] == "file"
        }
        for relative in paths:
            if relative not in included:
                missing.append(f"required build input missing or excluded: {repository}/{relative}")
    included_by_repo = {
        repository: {
            item["path"][len(repository) + 1:]
            for item in inventories[repository][0]
            if item.get("kind") == "file"
        }
        for repository in REPOSITORIES
    }
    assets = [
        *(f"multinode-demo/local-compute/{name}" for name in (
            "entrypoint-alice.sh", "entrypoint-node0.sh", "entrypoint-node1.sh",
            "entrypoint-vs.sh", "entrypoint-web0.sh", "entrypoint-web1.sh",
        )),
        *(f"multinode-demo/zpr-conf/admin/{name}" for name in (
            "attrfile.json", "multinode-demo.zpl", "multinode-demo.zplc.template",
        )),
        *(f"multinode-demo/zpr-conf/confs/{name}" for name in (
            "adapter-alice-conf.toml.template", "adapter-alice-local-conf.toml.template",
            "adapter-bob-conf.toml.template", "adapter-vs-conf.toml.template",
            "adapter-web0-conf.toml.template", "adapter-web1-conf.toml.template",
            "node0-conf.toml", "node1-conf.toml", "zpr-dashboard-config.toml",
        )),
        "multinode-demo/local-compute/vs.toml",
        "multinode-demo/tools/regen-banner.sh",
    ]
    for relative in set(assets):
        if relative not in included_by_repo["zpr-demo"]:
            missing.append(f"required package asset missing or excluded: zpr-demo/{relative}")
    if "integration-test/lib/zpr-pki" not in included_by_repo["zpr-core"]:
        missing.append("required zpr-pki package helper file is missing or excluded: zpr-core/integration-test/lib/zpr-pki")
    for repository, prefix in (
        ("zpr-demo", "multinode-demo/packaging/runtime/"),
        ("zpr-visaservice", "zpr-dashboard/packaging/demo-runtime/"),
    ):
        if not any(path.startswith(prefix) for path in included_by_repo[repository]):
            missing.append(f"required package runtime directory is empty: {repository}/{prefix}")
    if "zpr-dashboard/scripts/Dockerfile.simulator" not in included_by_repo["zpr-visaservice"]:
        missing.append("required Simulator Dockerfile missing or excluded")
    return missing


def collect_plan(args, run_id=None):
    source_root, repos = check_repo_layout(args.source_root)
    output_parent = Path(args.output_parent)
    if output_parent.is_symlink():
        raise CandidateError("output parent must not be a symlink")
    output_parent = output_parent.resolve(strict=True)
    if not output_parent.is_dir():
        raise CandidateError("output parent must be an existing directory")
    if output_parent == source_root or source_root in output_parent.parents:
        raise CandidateError("output parent must be outside the source root")
    if output_parent.name == ".local-runtime" or ".local-runtime" in output_parent.parts:
        raise CandidateError("output parent must not be inside .local-runtime")
    if not re.fullmatch(r"[A-Za-z0-9_./ -]+", str(output_parent)):
        raise CandidateError("output parent contains characters unsafe for Make/Docker paths")
    if not RELEASE_ID.fullmatch(args.release_id):
        raise CandidateError("release ID must be 1-80 safe ASCII characters")
    run_id = run_id or uuid.uuid4().hex[:12]
    candidate_root = output_parent / f"zpr-candidate-{args.release_id}-{run_id}"
    if candidate_root.exists() or candidate_root.is_symlink():
        raise CandidateError(f"candidate output already exists: {candidate_root}")

    dirty_allowlist = split_allowlist(args.include_dirty, "tracked allowlist")
    untracked_allowlist = split_allowlist(args.include_untracked, "untracked allowlist")
    overlap = dirty_allowlist & untracked_allowlist
    if overlap:
        raise CandidateError(f"path appears in both allowlists: {sorted(overlap)}")

    repository_plans = {}
    inventories = {}
    findings = []
    for name, repo in repos.items():
        head = run_git(repo, "rev-parse", "HEAD").strip()
        tracked_dirty, untracked = parse_status(repo)
        tree = parse_tree(repo, head)
        submodules = verify_submodules(repo, name, tree, head, findings)
        for submodule in submodules:
            prefix = f"{name}/{submodule['path']}"
            if any(item == prefix or item.startswith(prefix + "/") for item in dirty_allowlist | untracked_allowlist):
                raise CandidateError(f"submodule inputs cannot be allowlisted: {prefix}")
            tree[submodule["path"]]["submodule"] = submodule
        tracked_paths = set(tree)
        if not tracked_dirty.issubset(tracked_paths):
            raise CandidateError(f"Git reports unknown tracked changes in {name}: {sorted(tracked_dirty-tracked_paths)}")
        planned, excluded = archive_inventory(
            repo, name, tree, tracked_dirty, untracked,
            dirty_allowlist, untracked_allowlist,
            head, findings,
        )
        inventories[name] = (planned, excluded, tree, tracked_dirty, untracked)
        if run_git(repo, "rev-parse", "HEAD").strip() != head:
            raise CandidateError(f"source HEAD changed during preflight: {name}")
        branch = run_git(repo, "branch", "--show-current").strip()
        repository_plans[name] = {
            "head": head,
            "tree": run_git(repo, "rev-parse", f"{head}^{{tree}}").strip(),
            "branch": branch,
            "tracked_dirty": sorted(f"{name}/{path}" for path in tracked_dirty),
            "untracked": sorted(f"{name}/{path}" for path in untracked),
            "unapproved_dirty": sorted(
                f"{name}/{path}"
                for path in tracked_dirty
                if f"{name}/{path}" not in dirty_allowlist
            ),
            "included": planned,
            "excluded": excluded,
            "submodules": submodules,
            "ignored": [
                {"path": f"{name}/{path}", "reason": exclusion_reason(name, path.rstrip("/")) or "unapproved ignored input"}
                for path in run_git(
                    repo, "ls-files", "--others", "--ignored", "--exclude-standard",
                    "--directory", "-z",
                ).split("\0") if path
            ],
        }
    for entry in dirty_allowlist:
        repository = entry.split("/", 1)[0]
        if entry.split("/", 1)[1] not in inventories[repository][3]:
            raise CandidateError(f"tracked allowlist entry is not modified: {entry}")
    for entry in untracked_allowlist:
        repository = entry.split("/", 1)[0]
        if entry.split("/", 1)[1] not in inventories[repository][4]:
            raise CandidateError(f"untracked allowlist entry is not untracked: {entry}")
    missing_inputs = validate_required_inputs(source_root, repos, inventories)
    makefile_path = "multinode-demo/Makefile"
    selected_makefile = next(
        (item for item in inventories["zpr-demo"][0]
         if item["path"] == f"zpr-demo/{makefile_path}" and item["kind"] == "file"),
        None,
    )
    if selected_makefile is not None:
        makefile = (
            worktree_input(repos["zpr-demo"], makefile_path).read_bytes()
            if selected_makefile["dirty"] else
            run_git(repos["zpr-demo"], "show",
                    f"{repository_plans['zpr-demo']['head']}:{makefile_path}", binary=True)
        )
        if hashlib.sha256(makefile).hexdigest() != selected_makefile["sha256"]:
            raise CandidateError("selected Makefile changed during preflight")
        if (
            b"-t $(ZPR_BUILDER_IMAGE)" not in makefile
            or b'"$(ZPR_ROOT):/work" $(ZPR_BUILDER_IMAGE)' not in makefile
        ):
            missing_inputs.append(
                "selected zpr-demo/multinode-demo/Makefile lacks candidate builder-tag isolation; "
                "explicitly approve the reviewed tracked Makefile change"
            )
    blockers = [item["message"] for item in findings] + missing_inputs
    tools = {name: shutil.which(name) for name in ("git", "make", "go", "docker", "python3")}
    blockers.extend(f"required build tool is missing: {name}" for name, path in tools.items() if path is None)
    if blockers and not getattr(args, "preflight_report", False):
        raise CandidateError("; ".join(blockers))

    tags = {
        "builder": f"zpr-multinode-builder:isolated-{args.release_id}-{run_id}",
        "zpr": f"zpr-multinode:isolated-{args.release_id}-{run_id}",
        "simulator": f"zpr-simulator:isolated-{args.release_id}-{run_id}",
    }
    artifacts = [
        f"zpr-demo-{args.release_id}.tar",
        f"zpr-demo-{args.release_id}.tar.sha256",
        f"simulator-{args.release_id}.tar",
        f"simulator-{args.release_id}.tar.sha256",
    ]
    commands = [
        ["make", "-C", str(candidate_root / "source/zpr-demo/multinode-demo"),
         f"ZPR_ROOT={candidate_root / 'source'}", f"ZPR_BUILDER_IMAGE={tags['builder']}", "linux-amd64"],
        ["docker", "build", "--platform", "linux/amd64", "-t", tags["zpr"],
         "-f", str(candidate_root / "source/zpr-demo/multinode-demo/Dockerfile"),
         str(candidate_root / "source/zpr-demo/multinode-demo")],
        ["docker", "build", "--platform", "linux/amd64", "-t", tags["simulator"],
         "-f", str(candidate_root / "source/zpr-visaservice/zpr-dashboard/scripts/Dockerfile.simulator"),
         str(candidate_root / "source/zpr-visaservice/zpr-dashboard")],
        ["python3", str(candidate_root / "source/zpr-demo/multinode-demo/packaging/package-demo-images.py"),
         "build", "--release-id", args.release_id, "--output-dir", str(candidate_root / "artifacts"),
         "--zpr-image", tags["zpr"], "--simulator-image", tags["simulator"]],
        ["python3", str(candidate_root / "source/zpr-demo/multinode-demo/packaging/package-demo-images.py"),
         "verify", str(candidate_root / "artifacts" / artifacts[0]),
         str(candidate_root / "artifacts" / artifacts[2])],
    ]
    return {
        "source_root": str(source_root),
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "output_parent": str(output_parent),
        "candidate_root": str(candidate_root),
        "release_id": args.release_id,
        "run_id": run_id,
        "mode": "dry-run" if args.dry_run else "execute",
        "source_preflight_passed": not blockers,
        "execution_authorized": False,
        "orchestrator": {
            "path": str(Path(__file__).resolve()),
            "sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "python": sys.version,
        },
        "blockers": blockers,
        "findings": findings,
        "missing_inputs": missing_inputs,
        "approved_dirty": sorted(dirty_allowlist),
        "approved_untracked": sorted(untracked_allowlist),
        "prerequisites": {
            "tools": tools,
            "free_disk_bytes": shutil.disk_usage(output_parent).free,
            "docker_daemon": "not contacted; availability and tag checks required before staging",
            "toolchains": "not pinned; exact versions required in execution record",
        },
        "docker_tags": tags,
        "artifact_paths": [str(candidate_root / "artifacts" / name) for name in artifacts],
        "repositories": repository_plans,
        "commands": commands,
    }, repos, inventories, candidate_root


def verify_docker_tags(tags, runner=subprocess.run):
    host_override = os.environ.get("DOCKER_HOST", "")
    if host_override and not host_override.startswith("unix://"):
        raise CandidateError("refusing nonlocal DOCKER_HOST for candidate build")
    context = runner(
        ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if context.returncode:
        raise CandidateError("Docker daemon is unavailable: cannot inspect local context")
    if not context.stdout.strip().startswith("unix://"):
        raise CandidateError("refusing nonlocal Docker context for candidate build")
    info = runner(["docker", "info", "--format", "{{.ServerVersion}}"], check=False,
                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if info.returncode:
        raise CandidateError("Docker daemon is unavailable")
    for tag in tags.values():
        result = runner(["docker", "image", "inspect", tag], check=False,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode == 0:
            raise CandidateError(f"refusing to overwrite existing Docker image tag: {tag}")
        detail = (result.stderr or "").lower()
        if "no such image" not in detail:
            raise CandidateError(f"could not verify Docker tag availability for {tag}: {detail.strip()}")


def write_file(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as output:
        output.write(data)
    path.chmod(mode)


def stage_repository(repo, repository, destination, inventory, revision="HEAD"):
    planned, excluded_items, tree, tracked_dirty, untracked = inventory
    included = {item["path"][len(repository) + 1:]: item for item in planned}
    excluded = {
        item["path"][len(repository) + 1:]
        for item in excluded_items
        if item["reason"] != "unapproved untracked input"
    }
    archive = run_git(repo, "archive", "--format=tar", revision, binary=True)
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
        for member in tar:
            relative = member.name.rstrip("/")
            if not relative:
                continue
            if member.isdir():
                continue
            if relative in excluded or relative not in included:
                continue
            if included[relative].get("dirty"):
                continue
            target = destination / relative
            if member.issym():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)
                continue
            stream = tar.extractfile(member)
            if stream is None:
                raise CandidateError(f"cannot stage {repository}/{relative}")
            data = stream.read(MAX_INVENTORY_FILE_SIZE + 1)
            write_file(target, data, 0o755 if member.mode & 0o111 else 0o644)

    for relative, item in included.items():
        if item.get("kind") == "deleted":
            (destination / relative).unlink(missing_ok=True)
            continue
        if item.get("dirty"):
            current = repo / relative
            target = destination / relative
            if item.get("untracked") or relative in {entry[len(repository) + 1:] for entry in item_allowlist(inventory)}:
                if current.is_symlink() or not current.is_file():
                    raise CandidateError(f"staged allowlisted input changed type: {repository}/{relative}")
                data = current.read_bytes()
                if hashlib.sha256(data).hexdigest() != item["sha256"]:
                    raise CandidateError(f"allowlisted input changed after preflight: {repository}/{relative}")
                mode = 0o755 if item["mode"] == "100755" else 0o644
                if target.exists() or target.is_symlink():
                    target.unlink()
                write_file(target, data, mode)
    for relative, item in included.items():
        if item.get("kind") == "symlink":
            continue
        target = destination / relative
        if target.is_symlink():
            raise CandidateError(f"staged path unexpectedly became a symlink: {repository}/{relative}")
        if item["kind"] == "file":
            if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != item["sha256"]:
                raise CandidateError(f"staged source hash mismatch or missing input: {repository}/{relative}")
    for relative, entry in tree.items():
        submodule = entry.get("submodule")
        if submodule is None:
            continue
        child_repo = repo / relative
        child_tree = parse_tree(child_repo, submodule["pinned_gitlink"])
        child_inventory = (submodule["included"], submodule["excluded"], child_tree, set(), set())
        stage_repository(
            child_repo, f"{repository}/{relative}", destination / relative,
            child_inventory, submodule["pinned_gitlink"],
        )


def item_allowlist(inventory):
    return {
        item["path"]
        for item in inventory[0]
        if item.get("dirty") and not item.get("untracked")
    }


def stage_candidate(plan, repos, inventories, candidate_root):
    if plan.get("blockers"):
        raise CandidateError("candidate preflight is blocked; refusing to stage")
    for repository, repo in repos.items():
        expected = plan["repositories"][repository]
        if run_git(repo, "rev-parse", "HEAD").strip() != expected["head"]:
            raise CandidateError(f"source HEAD changed after preflight: {repository}")
        if verify_submodules(repo, repository, inventories[repository][2]) != expected["submodules"]:
            raise CandidateError(f"submodule state changed after preflight: {repository}")
        for item in expected["included"]:
            if not item.get("dirty"):
                continue
            relative = item["path"][len(repository) + 1:]
            current = worktree_input(repo, relative)
            if item["kind"] == "deleted":
                if current.exists():
                    raise CandidateError(f"deleted input changed after preflight: {repository}/{relative}")
            elif (
                not current.is_file()
                or scan_content(current.read_bytes(), repository, relative) != item["sha256"]
                or ("100755" if current.stat().st_mode & 0o111 else "100644") != item["mode"]
            ):
                raise CandidateError(f"allowlisted input changed after preflight: {repository}/{relative}")
    candidate_root.mkdir(mode=0o700)
    source = candidate_root / "source"
    for repository, repo in repos.items():
        head = run_git(repo, "rev-parse", "HEAD").strip()
        if head != plan["repositories"][repository]["head"]:
            raise CandidateError(f"source HEAD changed after preflight: {repository}")
        stage_repository(
            repo, repository, source / repository, inventories[repository],
            plan["repositories"][repository]["head"],
        )
    provenance = {
        "schema": "zpr.isolated-candidate-provenance.v1",
        "release_id": plan["release_id"],
        "run_id": plan["run_id"],
        "source_root": plan["source_root"],
        "observed_at": plan["observed_at"],
        "repositories": plan["repositories"],
        "docker_tags": plan["docker_tags"],
        "commands": plan["commands"],
        "approved_dirty": plan["approved_dirty"],
        "approved_untracked": plan["approved_untracked"],
        "orchestrator": plan["orchestrator"],
    }
    write_file(candidate_root / "provenance.json",
               (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode())
    artifacts = candidate_root / "artifacts"
    artifacts.mkdir(mode=0o700)
    return source, artifacts


def execute_plan(plan, repos, inventories, candidate_root, runner=subprocess.run):
    if plan.get("blockers"):
        raise CandidateError("candidate preflight is blocked; refusing to execute")
    verify_docker_tags(plan["docker_tags"], runner=runner)
    go_version = runner(
        ["go", "version"], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env={**os.environ, "GOTOOLCHAIN": "local"},
    )
    if go_version.returncode:
        raise CandidateError("local Go toolchain version check failed before staging")
    source, artifacts = stage_candidate(plan, repos, inventories, candidate_root)
    verify_docker_tags(plan["docker_tags"], runner=runner)
    for index, command in enumerate(plan["commands"]):
        if index in (1, 2):
            name = "zpr" if index == 1 else "simulator"
            verify_docker_tags({name: plan["docker_tags"][name]}, runner=runner)
        rendered = list(command)
        if index == 3:
            rendered[rendered.index(str(candidate_root / "artifacts"))] = str(artifacts)
        result = runner(rendered, cwd=source / "zpr-demo/multinode-demo" if index == 0 else None)
        if result.returncode:
            raise CandidateError(f"candidate command failed: {shlex.join(rendered)}")
        if index == 0:
            for name in BINARIES:
                binary = source / "zpr-demo/multinode-demo/bin" / name
                if not binary.is_file() or binary.is_symlink():
                    raise CandidateError(f"required built binary is missing or unsafe: {name}")
                with binary.open("rb") as stream:
                    header = stream.read(20)
                if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\x3e\x00":
                    raise CandidateError(f"built binary is not ELF64 little-endian amd64: {name}")
    images = {}
    for name in ("builder", "zpr", "simulator"):
        result = runner(
            ["docker", "image", "inspect", plan["docker_tags"][name]], check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        if result.returncode:
            raise CandidateError(f"cannot record built image identity: {name}")
        try:
            image, = json.loads(result.stdout)
            image_id = image["Id"]
            if image["Os"] != "linux" or image["Architecture"] != "amd64" or not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
                raise CandidateError(f"built image has invalid identity/platform: {name}")
        except (ValueError, KeyError, TypeError) as error:
            raise CandidateError(f"invalid built image metadata: {name}") from error
        images[name] = {"tag": plan["docker_tags"][name], "id": image_id, "platform": "linux/amd64"}
    hashes = {}
    for path in (*[source / "zpr-demo/multinode-demo/bin" / name for name in BINARIES],
                 *map(Path, plan["artifact_paths"])):
        if path.is_symlink() or not path.is_file():
            raise CandidateError(f"required candidate result is missing or unsafe: {path}")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        hashes[str(path.relative_to(candidate_root))] = digest.hexdigest()
    write_file(candidate_root / "build-results.json", (json.dumps({
        "schema": "zpr.isolated-candidate-results.v1",
        "go_version": go_version.stdout.strip(),
        "python_version": sys.version,
        "images": images,
        "sha256": hashes,
        "pair_verified": True,
        "byte_reproducible": False,
        "qualification": "local engineering candidate only",
    }, indent=2, sort_keys=True) + "\n").encode())


def make_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--output-parent", required=True)
    parser.add_argument("--release-id", required=True)
    parser.add_argument("--include-dirty", action="append", default=[], metavar="REPO:PATH")
    parser.add_argument("--include-untracked", action="append", default=[], metavar="REPO:PATH")
    parser.add_argument("--preflight-report", action="store_true",
                        help="dry-run only: emit a content-redacted plan even when source checks block execution")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="print the complete read-only plan (default)")
    mode.add_argument("--execute", action="store_true", help="stage and run the local build/package plan")
    parser.set_defaults(dry_run=True)
    return parser


def main(argv=None):
    args = make_parser().parse_args(argv)
    if args.execute:
        args.dry_run = False
    if args.execute and args.preflight_report:
        print("error: --preflight-report cannot be used with --execute", file=sys.stderr)
        return 1
    try:
        plan, repos, inventories, candidate_root = collect_plan(args)
        print(json.dumps(plan, indent=2, sort_keys=True))
        if plan["blockers"]:
            print("error: preflight blocked; report is not authorization to stage or build", file=sys.stderr)
            return 1
        if args.execute:
            execute_plan(plan, repos, inventories, candidate_root)
            print(f"Candidate staged at {candidate_root}")
    except (CandidateError, OSError, UnicodeError, subprocess.SubprocessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
