# Multi-organization package readiness decisions

This is a decision record template seeded only from the checked-in profile
facts and blockers in
[MULTI_ORG_PACKAGE_READINESS.md](MULTI_ORG_PACKAGE_READINESS.md). It does not
approve a profile, choose package semantics, or make an organization package
ready. Every `TBD` requires an explicit decision; do not infer approval from
checked-in files or passing contract tests.

## Required decisions for each profile

For every profile, record and approve the following before package-specific
implementation:

1. **Topology and machine mapping:** intended package topology; mapping from
   profile node IDs and machine IDs to package endpoints; primary member and
   exact machine-manifest correspondence; whether reference addresses and
   locations are retained, replaced, or excluded.
2. **Policy and runtime behavior:** allowed service flows, policy/config
   artifacts, runtime services and workloads, and what acceptance must prove.
3. **Package, driver, and source provenance:** package ID/release relationship,
   supported `packaged_provisioning` version and driver, source revision and
   asset inventory, provenance and distribution approval. Never use
   `.local-runtime` as a distributable source.
4. **Budgets and caps:** approved resource limits for nodes, services,
   containers, CPU, memory, storage, traffic, and duration as applicable.
   Values remain TBD until explicitly selected and reviewed.
5. **Validation evidence:** exact static, package, and runtime evidence needed;
   identify completed evidence and its artifact/revision, or leave it TBD.
6. **Approver and status:** named accountable approver, decision reference/date,
   and explicit status. Until all required decisions and evidence are approved,
   status must remain `BLOCKED` or `TBD`, not ready.

## Per-profile decision register

| Profile / checked-in evidence | Topology and machine mapping | Policy and runtime behavior | Package / driver / source provenance | Budgets and caps | Validation evidence required | Approver / status |
|---|---|---|---|---|---|---|
| **northstar** ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/northstar.json)). Known: `pregen`; one reference node `northstar-node`; four configured LDIF basenames are absent; no `machine_owners` IDs. | **Known/blocker:** profile says single-node and labels location a simulation guess. Mapping to package endpoints and machine inventory: **TBD**. Decide whether/how referenced location and addresses are used. | **Known/blocker:** five policy entries and seven service entries; profile references Northstar policy config/catalog; source files needed for group assertions are absent, and policy/runtime behavior is unverified. Intended flows and runtime acceptance: **TBD**. | **Blocked:** no `packaged_provisioning`; all four LDIF assets absent/untracked; policy files are not present at the referenced Northstar paths. Provenance/distribution approval and any portable source set: **TBD**. Do not substitute `.local-runtime`. | **TBD:** no approved resource or capacity evidence. | Required profile/source validation, manifest membership, policy compile/evaluation, and target package acceptance: **TBD**. Existing source-manifest contract tests use synthetic fixtures only. | Approver: **TBD**. Status: **BLOCKED** pending approved portable source, topology, policy, and budgets. |
| **redwood** ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/redwood.json)). Known: LDIF mode; two tracked profile-relative LDIF files; reference nodes `north-hub`, `regional-yard`; owner references `machine-01`–`machine-03`. | **Known/blocker:** two-node reference topology; profile coordinates are simulation guesses. Mapping nodes and owner machine IDs to package endpoints and exact manifest records: **TBD**. | **Known/blocker:** three policy entries and three service entries. Intended policy, runtime flows, and acceptance: **TBD**; checked-in profile data is not runtime validation. | **Blocked:** no `packaged_provisioning`; LDIF presence is known but provenance/distribution approval is unverified. Package release/source revision, driver, and portable source approval: **TBD**. | **TBD:** no approved package resource or capacity evidence. | Source/provenance review, manifest match, policy/runtime validation, and package acceptance: **TBD**. | Approver: **TBD**. Status: **BLOCKED** pending decisions and evidence. |
| **velocity** ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/velocity.json)). Known: LDIF mode; one tracked profile-relative LDIF; reference node `velocity-node`; owner references `machine-03`, `machine-05`. | **Known/blocker:** single-node reference topology. Mapping profile node and owner IDs to package endpoints and manifest records: **TBD**. | **Known/blocker:** one policy and one service entry. The profile notes direct visa-grant timing needs separate instrumentation. Required policy/runtime behavior and acceptance beyond that note: **TBD**. | **Blocked:** no `packaged_provisioning`; LDIF provenance/distribution approval unverified. Package/source revision, driver, and portable input approval: **TBD**. | **TBD:** no approved resource or performance budget/evidence. | Instrumentation plan, source review, manifest match, policy acceptance, and package test evidence: **TBD**. | Approver: **TBD**. Status: **BLOCKED** pending decisions and evidence. |
| **great-lakes** ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/great-lakes.json)). Known: LDIF mode; one tracked profile-relative LDIF; three reference nodes `milwaukee-hq`, `shenzhen-office`, `tijuana-plant`; owner references `machine-01`–`machine-13`. | **Known/blocker:** three-node cross-site reference topology; coordinates are simulation approximations, not verified addresses. Approved topology/address plan and machine-to-node/package mapping: **TBD**. | **Known/blocker:** six policy entries, ten service entries, and a runtime-policy reference. Intended allowed flows, service behavior, and required acceptance: **TBD**. | **Blocked:** no `packaged_provisioning`; LDIF provenance/distribution approval unverified. Package/source revision, driver, and portable source approval: **TBD**. | **TBD:** no approved multi-node, service, or capacity budgets. | Source review, topology/machine manifest reconciliation, policy/runtime validation, and package acceptance: **TBD**. | Approver: **TBD**. Status: **BLOCKED** pending decisions and evidence. |
| **load-lab** ([profile](../../../zpr-visaservice/zpr-dashboard/cmd/zpr-web-dashboard/examples/organizations/load-lab.json)). Known: LDIF mode; one tracked profile-relative LDIF; reference node `load-lab-node`; owner references `machine-03`, `machine-05`. | **Known/blocker:** single-node reference topology. Mapping machine references to package endpoints and manifest records: **TBD**. | **Known/blocker:** one policy and service entry; profile describes 200 generated services. Runtime generation, allowed behavior, and acceptance criteria: **TBD**. | **Blocked:** no `packaged_provisioning`; LDIF provenance/distribution approval unverified. Package/source revision, driver, and portable source approval: **TBD**. | **TBD:** no approved service-count, CPU, memory, traffic, or duration limits/capacity evidence. | Bounded load profile, source review, manifest match, policy/runtime validation, and package acceptance: **TBD**. | Approver: **TBD**. Status: **BLOCKED** pending decisions and evidence. |
| **demo** ([packaged profile](../../../zpr-visaservice/zpr-dashboard/packaging/demo-runtime/organizations/demo.json)). Known: LDIF mode; tracked `demo.ldif`; reference nodes `demo-node-a`, `demo-node-b`; profile declares provisioning v2, `shared-approved-bootstrap`, primary `demo-machine-01`, members `demo-machine-01`/`demo-machine-02`, service `OciWeb`. | **Known/blocker:** profile describes two reference nodes and says other machines/reference topology are not provisioned. Approved package topology and relationship to the shared one-node/Visa/OciWeb runtime: **TBD**. Matching organization manifest records and runtime topology evidence: **unverified**. | **Known/blocker:** profile has empty `policies` and `services` arrays and identifies itself as UI-only/unprovisioned. The selected OciWeb provisioning service contract exists, but effective policy and desired runtime acceptance for this package: **TBD**. | **Known/blocker:** declared profile shape matches v2/driver/OciWeb requirements; packaged LDIF is tracked but provenance/distribution approval is unverified. Source revision, package release compatibility, and approval: **TBD**. | **TBD:** no approved package resource/capacity evidence. | Contract tests cover v2, driver, service, and matching IDs; package/clean-host/runtime acceptance and source review: **TBD**. | Approver: **TBD**. Status: **BLOCKED**; profile contract shape is not readiness approval. |

## Decision recording rules

- Record the approver, decision reference, date, and resulting status for every
  row before changing any `TBD` or `BLOCKED` field to an approved value.
- If a decision changes topology, package inputs, policy, source data, or
  resource limits, identify the updated profile/package revision and repeat
  the affected validation.
- Tracked source files, example profile values, and synthetic tests are not
  evidence of source provenance or distribution permission.
- This register authorizes no asset copying, package integration, provisioning,
  host action, or claim of release readiness.
