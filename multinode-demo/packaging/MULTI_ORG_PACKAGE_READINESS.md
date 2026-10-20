# Multi-organization package readiness evidence

This is a read-only inventory of six checked-in profile files: the five
dashboard organization examples and the separate packaged Simulator `demo`
profile. It is not a readiness or distribution approval. “LDIF checked in”
means the profile-declared path exists as a tracked file in this checkout; it
does not establish that the data is portable, reviewed, or approved.

The machine IDs below are only references explicitly present in each profile
(`machine_owners` or `packaged_provisioning`). The profiles do not themselves
define or verify the complete machine inventory, nor do these references prove
that matching machine records exist in an organization manifest.

| Profile (source) | Profile-declared source and machine references | LDIF inputs checked in at profile-relative paths? | `packaged_provisioning` v2 / shared-approved-bootstrap / OciWeb compatibility | Unresolved topology, policy, budget, and provenance blockers |
|---|---|---|---|---|
| `northstar` ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/northstar.json)) | `pregen`; `demo-company.ldif`, `demo-employees.ldif`, `demo-roles.ldif`, `demo-machines.ldif`; one reference node `northstar-node`; no `machine_owners` IDs. | **No.** All four configured LDIF paths are absent and untracked. | **Incompatible as checked in:** no `packaged_provisioning` block. | Profile labels its location a simulation guess. Its asserted groups exceed the three inline groups; resolution against the missing LDIFs is unverified. Policy/config/catalog behavior and budgets are unverified. Source provenance and distribution approval are unresolved. |
| `redwood` ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/redwood.json)) | `ldif`; `directory.ldif`, `directory-people.ldif`; reference nodes `north-hub`, `regional-yard`; `machine_owners` references `machine-01`–`machine-03`. | **Present, provenance unverified.** Both declared files are tracked under `examples/organizations/redwood/`. | **Incompatible as checked in:** no `packaged_provisioning` block. | Two-node reference topology and machine-owner references have no verified package mapping. Policy artifacts, operational limits/budgets, source provenance, and distribution approval are unverified. Profile coordinates are explicitly simulation guesses. |
| `velocity` ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/velocity.json)) | `ldif`; `directory.ldif`; reference node `velocity-node`; `machine_owners` references `machine-03` and `machine-05`. | **Present, provenance unverified.** The declared file is tracked under `examples/organizations/velocity/`. | **Incompatible as checked in:** no `packaged_provisioning` block. | Single-node reference topology and machine-owner references have no verified package mapping. Policy/config/catalog and operational budgets are unverified; the profile itself says direct visa-grant timing needs separate instrumentation. Source provenance and distribution approval are unresolved. |
| `great-lakes` ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/great-lakes.json)) | `ldif`; `directory.ldif`; reference nodes `milwaukee-hq`, `shenzhen-office`, `tijuana-plant`; `machine_owners` references `machine-01`–`machine-13`. | **Present, provenance unverified.** The declared file is tracked under `examples/organizations/great-lakes/`. | **Incompatible as checked in:** no `packaged_provisioning` block. | Three-node, cross-site reference topology and machine-owner references are not verified against a package inventory. Policy/runtime-policy, workload behavior, budgets, and source provenance/distribution approval remain unverified. Coordinates are described as simulation approximations, not verified addresses. |
| `load-lab` ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/load-lab.json)) | `ldif`; `directory.ldif`; reference node `load-lab-node`; `machine_owners` references `machine-03` and `machine-05`. | **Present, provenance unverified.** The declared file is tracked under `examples/organizations/load-lab/`. | **Incompatible as checked in:** no `packaged_provisioning` block. | Single-node reference topology and machine references are not verified against package inventory. The profile describes 200 generated services but supplies no verified package resource budget or capacity result. Policy/runtime-policy, source provenance, and distribution approval remain unverified. |
| `demo` ([packaged profile](../../../zpr-visaservice/zpr-dashboard/packaging/demo-runtime/organizations/demo.json)) | `ldif`; `demo.ldif`; reference nodes `demo-node-a`, `demo-node-b`; provisioning IDs `demo-machine-01`, `demo-machine-02`, with `demo-machine-01` primary. | **Present, provenance unverified.** The declared file is tracked under `packaging/demo-runtime/organizations/demo/`. | **Profile shape matches the declared contract:** version `2`, driver `shared-approved-bootstrap`, unique machine IDs with primary first, service `OciWeb`. Matching manifest membership and end-to-end package validation are **unverified**. | The profile describes itself as unprovisioned/UI-only and says other machine records/reference topology are not provisioned. Its two reference node addresses are example ranges. Actual package topology/policy behavior, budgets, data provenance, and distribution approval remain unverified. |

## Contract interpretation and limits

The runtime’s packaged machine-provisioning contract requires version 2,
`shared-approved-bootstrap`, `OciWeb`, unique machine IDs with the primary ID
first, and each enabled ID present exactly once in the matching organization
manifest. The five dashboard examples do not declare that contract. The `demo`
profile declares the required shape, but that alone does not establish the
matching manifest, package/source compatibility, or successful provisioning.

No profile row is marked package-ready. A tracked LDIF is not necessarily a
portable or approved asset. The profile inventory also does not certify policy
compilation or semantics, topology/address suitability, resource budgets,
runtime acceptance, or human/machine data provenance. For Northstar specifically,
the separate [source-manifest contract](NORTHSTAR_SOURCE_CONTRACT.md) only
defines a future input boundary; its temporary tests do not supply or approve
Northstar data. Do not copy `.local-runtime` inputs into a package.

## Isolated-candidate dry-run handoff

W5's completed read-only dry run is an input/provenance report, not a package
readiness decision. The approved dirty and untracked allowlists are both empty;
19 tracked-dirty paths remain unapproved. Of 34 excluded untracked paths, 31
are unapproved inputs and 3 are Python-cache files. This includes the
pre-existing `zpr-visaservice/zpr-dashboard/cmd/zpr-discover/foo`, recorded by
path only. The dry run also excluded 70 Demo paths named as credentials or
private keys and 414 `.local-runtime` files.

Four scanner match paths/categories were reported as private-key-header
content matches. They have not been adjudicated as credentials; their content
remains redacted. This handoff does not waive or bypass the scanner, approve
any excluded path, or change the package-readiness blockers above.

The following exact handoff fields have not been supplied here and remain
**unavailable** pending C0's forwarding of W5's results. Do not infer or
substitute values:

| Handoff field | Status |
|---|---|
| Exact path-only input manifest | Unavailable |
| Source and image pins | Unavailable |
| Exact missing-input list | Unavailable |
| Unique dry-run command | Unavailable |
| Actual plan hashes and image IDs | Unavailable |
| Exact scanner match paths/categories | Unavailable; match content remains redacted |

No builder rerun, source staging, copying, or build is part of this handoff.
No path is approved for packaging by these counts; readiness remains blocked
until the exact manifest, pins, missing inputs, dry-run command, and plan/image
identifiers are provided and reviewed.
