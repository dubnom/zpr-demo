# Northstar source-manifest contract

`northstar-source-contract.py` validates an explicit manifest for a future,
portable Northstar LDIF source set. It is a source-boundary check only: it does
not package the files, provision an organization, or establish that any
Northstar data is approved for distribution.

## Required assets

The required basenames come from `directory.ldif_files` in the checked-in
profile at
`zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/northstar.json`:

- `demo-company.ldif`
- `demo-employees.ldif`
- `demo-roles.ldif`
- `demo-machines.ldif`

The validator reads that profile at runtime, rather than maintaining a second
list. Each required basename must appear exactly once in the manifest. Missing
or additional asset entries are rejected.

## Manifest format

The JSON manifest has exactly three top-level fields:

```json
{
  "schema": "zpr.northstar.source-manifest.v1",
  "review": {
    "status": "reviewed",
    "reviewer": "reviewer or review group",
    "reference": "review record or source revision"
  },
  "assets": [
    {
      "path": "portable-source/demo-company.ldif",
      "sha256": "64 lowercase hexadecimal characters"
    }
  ]
}
```

There must be one `assets` entry for each required profile basename. Each entry
contains exactly `path` and `sha256`. Paths are relative POSIX paths under the
explicit source root; absolute paths, traversal components, backslashes,
control characters, and any `.local-runtime` path component (case-insensitive)
are rejected. The path basename must match a required profile basename.

Each digest must be a 64-character lowercase hexadecimal SHA-256 and must match
the referenced regular file. The source tree must contain exactly the declared
files: missing files, extra files, and symlinks within the source tree are
rejected. Resolved source roots, manifest paths, and asset paths inside
`ZPR Docs/.local-runtime` are rejected, as are source assets whose resolved
paths escape the source root. A source-root or manifest symlink may be used
only when its resolved target remains outside `.local-runtime`; asset
symlinks are not permitted.

The `review` object must contain exactly `status`, `reviewer`, and `reference`.
Status must be the literal `reviewed`, and the other fields must be non-empty
strings. These are required declarations, not authenticated attestations: the
validator does not verify reviewer identity, approval authority, provenance,
or the truth of the review claim.

## Validation use and limits

Run the standalone validator with an explicit source root and manifest:

```sh
python3 packaging/northstar-source-contract.py \
  --source-root /path/to/reviewed-portable-source \
  --manifest /path/to/northstar-source-manifest.json
```

The tests create synthetic temporary files with the required basenames to
exercise valid and invalid manifests. Those fixtures are not Northstar source
assets and do not provide, reproduce, or approve any Northstar data. No source
assets are included by this contract or its tests.

The actual Northstar LDIF sources remain absent/unverified. Their provenance,
content review, distribution approval, and any needed profile/schema mapping
decisions remain unresolved. Passing this validator would prove only that the
declared files match the checked-in basename contract, paths, review metadata
shape, and hashes; it would not make the data approved or package-ready.
