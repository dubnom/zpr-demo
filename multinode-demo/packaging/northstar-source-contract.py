#!/usr/bin/env python3
"""Validate the reviewed Northstar source contract without packaging it."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys


SCHEMA = "zpr.northstar.source-manifest.v1"


def fail(message):
    raise ValueError(message)


def is_within(path, root):
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def resolve_path(path, label):
    try:
        return Path(path).resolve()
    except (OSError, RuntimeError) as exc:
        fail(f"{label} path cannot be resolved: {path}: {exc}")


def reject_local_runtime(path, docs_root, label):
    resolved = resolve_path(path, label)
    local_runtime = resolve_path(Path(docs_root) / ".local-runtime", ".local-runtime")
    if is_within(resolved, local_runtime):
        fail(f"{label} resolves inside prohibited .local-runtime: {path}")
    return resolved


def required_asset_basenames(profile_path, docs_root):
    profile_path = reject_local_runtime(profile_path, docs_root, "Northstar profile")
    if not profile_path.is_file():
        fail(f"Northstar profile is not a regular file: {profile_path}")
    try:
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"could not read Northstar profile: {exc}")
    if not isinstance(profile, dict):
        fail("Northstar profile must be a JSON object")
    directory = profile.get("directory")
    if not isinstance(directory, dict):
        fail("Northstar profile has no directory object")
    names = directory.get("ldif_files")
    if not isinstance(names, list) or not names:
        fail("Northstar profile directory.ldif_files must be a non-empty list")
    if any(
        not isinstance(name, str)
        or not name
        or Path(name).name != name
        or "/" in name
        or "\\" in name
        for name in names
    ):
        fail("Northstar profile LDIF entries must be basenames")
    if len(names) != len(set(names)):
        fail("Northstar profile contains duplicate LDIF basenames")
    return tuple(names)


def validate_relative_asset_path(value):
    if not isinstance(value, str) or not value or "\\" in value:
        fail("manifest asset paths must be non-empty relative POSIX paths")
    parts = value.split("/")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or re.match(r"^[A-Za-z]:", value)
        or any(part in ("", ".", "..") for part in parts)
        or any(part.casefold() == ".local-runtime" for part in parts)
        or any(any(ord(character) < 32 for character in part) for part in parts)
    ):
        fail(f"unsafe manifest asset path: {value!r}")
    return path


def manifest_entries(manifest, required_names):
    if not isinstance(manifest, dict) or set(manifest) != {"schema", "review", "assets"}:
        fail("manifest must contain exactly schema, review, and assets")
    if manifest.get("schema") != SCHEMA:
        fail(f"manifest schema must be {SCHEMA}")

    review = manifest.get("review")
    if not isinstance(review, dict) or set(review) != {
        "status", "reviewer", "reference"
    }:
        fail("manifest review must contain status, reviewer, and reference")
    if review.get("status") != "reviewed":
        fail("manifest must explicitly declare review status 'reviewed'")
    for field in ("reviewer", "reference"):
        value = review.get(field)
        if not isinstance(value, str) or not value.strip():
            fail(f"manifest review {field} must be a non-empty string")

    assets = manifest.get("assets")
    if not isinstance(assets, list):
        fail("manifest assets must be a list")
    entries = {}
    seen_paths = set()
    for asset in assets:
        if not isinstance(asset, dict) or set(asset) != {"path", "sha256"}:
            fail("each manifest asset must contain exactly path and sha256")
        relative = validate_relative_asset_path(asset.get("path"))
        basename = relative.name
        if basename not in required_names:
            fail(f"manifest contains unconfigured Northstar asset: {basename}")
        if basename in entries:
            fail(f"manifest repeats Northstar asset basename: {basename}")
        if str(relative) in seen_paths:
            fail(f"manifest repeats asset path: {relative}")
        digest = asset.get("sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            fail(f"manifest has an invalid SHA-256 for {relative}")
        entries[basename] = (str(relative), digest)
        seen_paths.add(str(relative))

    missing = sorted(set(required_names) - set(entries))
    if missing:
        fail("manifest is missing configured Northstar assets: " + ", ".join(missing))
    return entries


def walk_source_files(source_root, docs_root):
    files = set()

    def raise_walk_error(error):
        raise error

    for root, directories, names in os.walk(
        source_root, followlinks=False, onerror=raise_walk_error
    ):
        root_path = Path(root)
        for name in directories:
            directory = root_path / name
            relative = directory.relative_to(source_root)
            if any(part.casefold() == ".local-runtime" for part in relative.parts):
                fail(f"source tree contains prohibited .local-runtime path: {relative}")
            resolved = reject_local_runtime(directory, docs_root, "source directory")
            if directory.is_symlink():
                if not is_within(resolved, source_root):
                    fail(f"source directory symlink escapes source root: {relative}")
                fail(f"source directory symlinks are not permitted: {relative}")

        for name in names:
            source = root_path / name
            relative = source.relative_to(source_root)
            if any(part.casefold() == ".local-runtime" for part in relative.parts):
                fail(f"source tree contains prohibited .local-runtime path: {relative}")
            resolved = reject_local_runtime(source, docs_root, "source asset")
            if not is_within(resolved, source_root):
                fail(f"source asset symlink escapes source root: {relative}")
            if source.is_symlink():
                fail(f"source asset symlinks are not permitted: {relative}")
            if not source.is_file():
                fail(f"source asset is not a regular file: {relative}")
            files.add(relative.as_posix())
    return files


def validate_source_manifest(profile_path, source_root, manifest_path, docs_root):
    required_names = required_asset_basenames(profile_path, docs_root)
    source_root = reject_local_runtime(source_root, docs_root, "source root")
    if not source_root.is_dir():
        fail(f"source root is not a directory: {source_root}")
    manifest_path = reject_local_runtime(manifest_path, docs_root, "source manifest")
    if not manifest_path.is_file():
        fail(f"source manifest is not a regular file: {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"could not read source manifest: {exc}")

    entries = manifest_entries(manifest, set(required_names))
    for basename, (relative, expected_digest) in entries.items():
        asset_path = source_root.joinpath(*PurePosixPath(relative).parts)
        resolved = reject_local_runtime(asset_path, docs_root, "source asset")
        if not is_within(resolved, source_root):
            fail(f"source asset symlink escapes source root: {relative}")
        if not resolved.is_file():
            fail(f"manifest source asset is missing or not a file: {relative}")
        digest = hashlib.sha256(resolved.read_bytes()).hexdigest()
        if digest != expected_digest:
            fail(f"SHA-256 mismatch for {basename}")

    actual_files = walk_source_files(source_root, docs_root)
    declared_paths = {relative for relative, _ in entries.values()}
    missing_files = sorted(declared_paths - actual_files)
    extra_files = sorted(actual_files - declared_paths)
    if missing_files:
        fail("source tree is missing manifest assets: " + ", ".join(missing_files))
    if extra_files:
        fail("source tree contains unmanifested assets: " + ", ".join(extra_files))
    return len(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()

    script_path = Path(__file__).resolve()
    docs_root = script_path.parents[3]
    profile_path = (
        docs_root
        / "zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/northstar.json"
    )
    try:
        asset_count = validate_source_manifest(
            profile_path, args.source_root, args.manifest, docs_root
        )
    except (OSError, ValueError) as exc:
        print(f"northstar source manifest: {exc}", file=sys.stderr)
        return 1
    print(
        f"Northstar source manifest contract valid for {asset_count} assets; "
        "review metadata and hashes match."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
