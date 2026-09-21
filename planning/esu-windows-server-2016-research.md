# Windows Server 2016 ESU through Azure Arc: research and implementation impact

Research date: 2026-09-03

## Purpose

This report compares Windows Server 2012/2012 R2 and Windows Server 2016 Extended Security Updates (ESUs) enabled by Azure Arc. It is based on current official Microsoft documentation and the current repository implementation.

This phase is research and planning only. It does not change any scripts.

## Executive summary

Windows Server 2016 uses the same Azure Arc ESU resource model as Windows Server 2012/2012 R2:

1. Provision or modify a `Microsoft.HybridCompute/licenses` resource.
2. Link or unlink it through the Arc machine's `Microsoft.HybridCompute/machines/licenseProfiles/default` resource.
3. Read the license profile to check assignment state.
4. Delete the license resource when appropriate.

The REST paths, methods, assignment body, unlink body, and deletion mechanism are not target-specific. The principal REST payload difference is `properties.licenseDetails.target`, which must be one of:

- `Windows Server 2012`
- `Windows Server 2012 R2`
- `Windows Server 2016`

Windows Server 2016 also has material validation and customer-guidance differences:

- Connected Machine agent version 1.62 or later is required, compared with 1.34 or later for 2012/R2.
- Volume Licensing transition fields (`invoiceId` and `programYear`) are not supported for Windows Server 2016.
- SPLA eligibility and the Visual Studio dev/test benefit documented for 2012/R2 do not apply to Windows Server 2016.
- Windows Server 2016 billing begins January 13, 2027; late enrollment is back-billed to its end-of-support date.
- The repository's current license API version, `2025-02-19-preview`, does not list Windows Server 2016 in its published target values. Publicly retrievable schema versions beginning with `2026-02-12-preview` do list it.

The creation scripts therefore require target-aware input, validation, agent-version rules, payload construction, and a documented API-version update. Assignment, status, and deletion scripts are structurally target-neutral, but they must be verified with contract tests and their customer guidance must explain 2016 eligibility.

## Clarified product contract

The following decisions were confirmed before this research:

- Add an optional `-target` parameter to applicable creation scripts.
- Preserve `Windows Server 2012` as the default for backward compatibility.
- Accept only the exact API target values listed above.
- Add a `Target` column to applicable CSV input.
- A nonempty row `Target` overrides the `-target` parameter; an empty cell uses the parameter/default.
- Allow a single bulk CSV to mix 2012, 2012 R2, and 2016 rows.
- Add optional per-row `InvoiceId` and `ProgramYear` columns. Nonempty row values override batch-level values.
- Reject every unsupported target/input combination before authentication or any Azure mutation, with an explanation of why it is unsupported.
- In particular, reject Volume Licensing transition data for Windows Server 2016.
- Confirm that assignment, status, and deletion scripts work for both generations without adding target selection unless official contracts require it.
- Produce this research report before implementing code.

## Product and lifecycle differences

| Area | Windows Server 2012/2012 R2 | Windows Server 2016 | Implementation consequence |
| --- | --- | --- | --- |
| End of support | October 10, 2023 | Azure Arc guidance treats January 12, 2027 as EOS; billing begins January 13, 2027 | Billing and warning text must be target-aware. |
| ESU duration | Three years; Microsoft lists Year 3 ending October 13, 2026 | Critical and Important updates for up to three years, through 2030 | Do not apply the completed 2012 calendar to 2016. |
| Portal availability | Already available | Configurable starting August 3, 2026 | 2016 is available for preparation before billing starts. |
| Supported editions | Windows Server 2012/2012 R2 Standard and Datacenter; Storage is unsupported | Windows Server 2016 Standard and Datacenter | Reject unsupported editions/OS products; do not infer eligibility from the broader Windows Server 2016 lifecycle edition list. |
| Connected Machine agent | 1.34 or later | 1.62 or later | Bulk preflight threshold must depend on effective target. |
| OS preparation | Microsoft specifically points to KB5031043 for the licensing package and SSU | Microsoft says to install any required licensing package and SSU from the applicable Windows Server 2016 KB article, but the current page does not name one | Do not hardcode a 2012 KB as a 2016 prerequisite. Keep 2016 guidance linked to the current Microsoft page until a specific KB is published there. |
| Software Assurance / subscription | SA or equivalent Server Subscription; SPLA can also qualify 2012/R2 | SA or equivalent Server Subscription; SA required for on-premises workloads; SPLA is unavailable | Reject or clearly flag a 2016 workflow presented as SPLA-based. |
| Volume Licensing transition | Supported through `volumeLicenseDetails`, invoice ID, and program year under the documented 2012/R2 transition rules | Explicitly unsupported | Omit `volumeLicenseDetails` for 2016 and reject supplied transition values. |
| Visual Studio dev/test benefit | Documented for qualifying 2012/R2 systems, subject to the paid-production-license and tagging rules | Explicitly unavailable | Reject a 2016 row that attempts to use the repository's ESU exception/tag mechanism for this benefit. |
| Arc DR/exception tagging | The Arc delivery article documents WS2012-specific exception tags and conditions | The general ESU lifecycle FAQ recognizes a DR benefit, but the Arc article does not document a Windows Server 2016 tag protocol | Do not reuse reserved `WS2012 ...` exception values for 2016 or infer eligibility from a tag. Reject those known-incompatible values and direct customers to confirm current licensing terms. |
| Azure operated by 21Vianet | Unavailable | Unavailable | Document cloud limitation; current scripts target public Azure ARM endpoints only. |

The product lifecycle page lists the Windows Server 2016 extended-support end timestamp as January 13, 2027 in Pacific Time. The Azure Arc ESU pages consistently describe January 12, 2027 as the end-of-support date and January 13, 2027 as the billing start. Customer-facing ESU guidance should use the Arc-specific wording and link to the lifecycle page for the formal timestamp.

## Licensing rules that do not change

The following rules are documented for both target generations:

- Physical-core licensing has a minimum of 16 cores per machine.
- Virtual-core licensing has a minimum of 8 cores per VM.
- Virtual-core licensing cannot be used for physical servers.
- Virtual-core licenses must use Standard edition, not Datacenter.
- Valid combinations are Standard vCore, Standard pCore, and Datacenter pCore.
- A license can cover at most 10,000 cores.
- A resource group can contain at most 800 license resources.
- Core count can be changed after provisioning, subject to minimums and billing rules.
- Edition and core type are immutable after creation.
- Licenses can move across resource groups and subscriptions.
- A license can link to a server in another subscription in the same tenant.
- Cross-tenant linking is unsupported.
- Activated licenses initiate billing even when they are not linked to a server.
- Decrementing cores, deactivating, or deleting can continue billing for up to five calendar days.
- Reactivation and recreation remain subject to back-billing.

These existing safeguards should remain in place and become target-aware only where Microsoft documents a difference.

## REST API comparison

### License create or modify

The official programmatic article shows the same URI and body shape for both generations:

```http
PUT or PATCH /subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.HybridCompute/licenses/{licenseName}?api-version={licenseApiVersion}
```

```json
{
  "location": "{region}",
  "properties": {
    "licenseType": "ESU",
    "licenseDetails": {
      "state": "Activated",
      "target": "Windows Server 2016",
      "edition": "Standard",
      "type": "vCore",
      "processors": 8
    }
  }
}
```

For 2012/R2 Volume Licensing transition scenarios only, `licenseDetails` can also contain `volumeLicenseDetails`. That property must be absent for Windows Server 2016.

The URI, HTTP method, resource type, and property names do not otherwise differ by target.

### Link a license

The same request applies to both generations:

```http
PUT /subscriptions/{serverSubscriptionId}/resourceGroups/{serverResourceGroup}/providers/Microsoft.HybridCompute/machines/{machineName}/licenseProfiles/default?api-version={licenseProfileApiVersion}
```

```json
{
  "location": "{machineRegion}",
  "properties": {
    "esuProfile": {
      "assignedLicense": "/subscriptions/{licenseSubscriptionId}/resourceGroups/{licenseResourceGroup}/providers/Microsoft.HybridCompute/licenses/{licenseName}"
    }
  }
}
```

There is no target property in the assignment body. The selected license and Arc machine must still be eligible for the same Windows Server generation; Azure can reject an incompatible pairing.

### Unlink a license

The same request applies to both generations:

```json
{
  "location": "{machineRegion}",
  "properties": {
    "esuProfile": {}
  }
}
```

### Read status

Reading `machines/{machineName}/licenseProfiles/default` is generation-neutral. It reports assignment information such as `esuProfile.assignedLicense` and assignment state. The current repository can continue to use this mechanism for 2012/R2 and 2016.

The status script does not currently retrieve the assigned license resource, so it cannot report the license target without an additional GET. Adding that enrichment is optional and is not required for compatibility.

### Delete a license

The same target-neutral request applies to both generations:

```http
DELETE /subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.HybridCompute/licenses/{licenseName}?api-version={licenseApiVersion}
```

Deletion remains billing-sensitive for both generations.

## API-version findings

Official Microsoft sources are inconsistent about the version to use:

- The current programmatic ESU article shows `2023-06-20-preview` for 2012/R2 and 2016 create, modify, link, unlink, and delete examples.
- The repository's bulk license script uses `2025-02-19-preview` for licenses and license profiles.
- The published `2025-02-19-preview` and `2025-09-16-preview` license schemas list only `Windows Server 2012` and `Windows Server 2012 R2` as target values.
- The published `2026-02-12-preview`, `2026-06-04-preview`, and `2026-06-16-preview` schemas list all three target values, including `Windows Server 2016`.
- A direct first-party Azure resource-provider schema query performed during this research exposed stable `2026-07-15` schemas for licenses and license profiles, with Windows Server 2016 in the license target enum. However, the corresponding public Microsoft Learn template pages returned 404 on the research date. This separately observed provider evidence is not used as the implementation baseline below.
- The Microsoft Learn schema change log says no properties changed for these versions and does not record the target-enum expansion. It is therefore not sufficient evidence by itself.

### Recommended documented baseline

Use endpoint-specific constants. Select `2026-06-16-preview` for `Microsoft.HybridCompute/licenses` when adding Windows Server 2016 creation and modification support. Keep target-neutral `Microsoft.HybridCompute/machines/licenseProfiles` operations on their currently documented/verified endpoint version unless a focused runtime/provider check establishes a reason to coordinate that version separately.

Reasons:

- It is the newest publicly retrievable Microsoft Learn schema on the research date.
- Its license schema explicitly declares all three required targets.
- The target enum is a property of the license resource, not the license profile.
- The scenario-specific programmatic article continues to document `2023-06-20-preview` for link and unlink operations, and no target-specific profile change is required.

Do not select `2026-07-15` solely because it appears in the provider catalog until its public Learn contract is available or Microsoft otherwise documents it for this scenario.

If a later implementation coordinates profile API versions, first verify the candidate version against the provider and a non-mutating contract check, then assert every exact URI in mocked tests. It must not silently change API versions.

## Portal versus REST documentation tension

The portal delivery article says that Windows Server 2016 core type is selected later, when ESUs are enabled on machines. In contrast:

- The programmatic article includes `Type` in the Windows Server 2016 license create/modify body.
- The current license schema includes `licenseDetails.type`.
- The license-profile schema has no core-type property in `esuProfile`; it contains only `assignedLicense`.

Therefore, the scripts should continue to put `type` on the license resource and should not invent a core-type field in the assignment request. The portal wording should be treated as a UX workflow difference, not a different documented REST contract.

The current license-profile schema also exposes `softwareAssurance.softwareAssuranceCustomer`, but the programmatic ESU link example does not include it. The implementation should not add that property until Microsoft documents that it is required for scripted Windows Server 2016 enrollment.

## Repository impact

### Scripts that require target-aware behavior

#### `Scripts/windows/CreateESULicense.ps1`

Current state:

- Hardcodes `Windows Server 2012`.
- Uses `2023-06-20-preview` for license creation.
- Has no CSV and no Volume Licensing transition parameters.

Planned change:

- Add optional `-target` with exact validated values and default `Windows Server 2012`.
- Pass the selected target into the license body.
- Use the selected documented license API version.
- Preserve all existing parameters, aliases, authentication paths, `WhatIf`, exit codes, and core safeguards.

#### `Scripts/windows/ManageESULicenses.ps1`

Current state:

- Hardcodes a global `Windows Server 2012` target.
- Uses a fixed 1.34 agent threshold.
- Always constructs a `volumeLicenseDetails` array from batch `programYear`, even when `invoiceId` is empty.
- Uses batch-level `invoiceId` and `programYear` only.
- Has no target column.

Planned change:

- Add optional batch `-target` with default `Windows Server 2012`.
- Add optional CSV columns `Target`, `InvoiceId`, and `ProgramYear`.
- Resolve `Target` separately: nonempty row `Target`, then bound `-target`, then `Windows Server 2012`.
- Resolve `InvoiceId` separately: nonempty row `InvoiceId`, then explicitly bound batch `-invoiceId`, then no transition invoice.
- Resolve `ProgramYear` separately: nonempty row `ProgramYear`, then explicitly bound batch `-programYear`, then `Year 1` only when an effective invoice makes the row a transition request. A program year without an effective invoice is invalid.
- In a mixed-target file, batch transition defaults must be compatible with every row. To transition only selected 2012/R2 rows while retaining 2016 rows, leave batch transition parameters unbound and populate the per-row columns only on the applicable 2012/R2 rows.
- Store effective target and transition values in the validated plan object.
- Use target-specific agent minimums: 1.34 for 2012/R2 and 1.62 for 2016.
- Per clarified intent, reject unsupported agent versions during full CSV preflight rather than skipping them later. This intentionally changes the current `SkipAgentVersion` behavior and must be called out in release notes.
- Omit `volumeLicenseDetails` entirely when no applicable 2012/R2 transition is requested.
- Reject any 2016 row with effective `InvoiceId` or explicitly supplied `ProgramYear`.
- Reject reserved WS2012-specific `ESUException` values on 2016 rows. Do not claim that arbitrary tags establish a 2016 benefit or reduce billing.
- Continue validating every row before authentication or REST calls.
- Include target and any transition mode in dry-run/WhatIf plans and summaries.

### Scripts that are structurally compatible

#### `Scripts/windows/AssignESULicense.ps1`

The body contains only the assigned license resource ID. No target-specific REST change is documented. Verify against the selected profile API version and add mocked tests using a Windows Server 2016 license resource ID.

#### `Scripts/windows/ManageESUAssignments.ps1` and `Scripts/windows/ManageESUAssignmentsFR.ps1`

The same conclusion applies to bulk link/unlink operations, including cross-subscription same-tenant assignments. No target column is needed because these scripts assign existing licenses rather than create them. Azure remains responsible for rejecting an OS/license target mismatch.

A stronger local preflight could GET the Arc machine and compare its OS to the license target, but that would require additional REST calls and likely `Microsoft.HybridCompute/machines/read` in the custom role. Do not broaden RBAC without separate approval and documentation.

#### `Scripts/windows/CheckESUStatus.ps1`

The license-profile status mechanism is generation-neutral. Existing output remains compatible. Optional target reporting would require reading the assigned license and is outside the minimum compatibility change.

#### `Scripts/windows/DeleteESULicense.ps1`

Deletion is generation-neutral. Update only the endpoint API version if the coordinated API-version decision applies to all license operations, and preserve billing warnings.

### Other repository surfaces

The implementation phase should update:

- `samples/ManageESULicenses.csv`
- `tests/ManageESULicenses.Tests.ps1`
- `tests/ShouldProcess.Tests.ps1`
- API URI assertions in assignment/status/delete tests if versions are coordinated
- `README.md` and `LISEZMOI.md`
- English and French creation and bulk-license guides
- English and French assignment/status/delete guides where 2016 compatibility or prerequisites need clarification
- Comment-based help for every changed public parameter or behavior
- The Azure Graph query examples so they include Windows Server 2016 and emit a value that can map exactly to `Target`
- The quality workflow only if test discovery or sample-schema checks need expansion

## Proposed validation rules

Apply these rules during parameter binding or full CSV preflight:

| Rule | Result |
| --- | --- |
| Target is not one of the three exact API values | Error naming the accepted values. |
| CSV `Target` is empty | Use `-target`; if omitted, use `Windows Server 2012`. |
| CSV mixes supported targets | Allowed. |
| 2012/R2 agent is below 1.34 | Error before authentication or mutation. |
| 2016 agent is below 1.62 | Error explaining the Microsoft minimum. |
| 2016 has effective `InvoiceId` | Error: Volume Licensing transition is unsupported for Windows Server 2016 ESUs enabled by Azure Arc. |
| 2016 has explicitly supplied `ProgramYear` | Same error; do not silently ignore it. |
| 2016 uses a reserved WS2012 exception/tag value | Error explaining that the documented WS2012 tag mechanism does not apply to a 2016 target. |
| vCore with Datacenter | Error for every target. |
| vCore applied to a physical machine | Error for every target. |
| Core count below minimum or odd | Preserve the repository's documented normalization policy only if explicitly intended; otherwise error. Do not change this behavior as part of target support without approval. |
| License target and machine OS do not match | Let Azure reject it unless additional machine-read permission is separately approved; surface the service error clearly. |
| Cross-tenant license assignment | Error/clear service failure; unsupported for every target. |

To distinguish an explicitly supplied `ProgramYear` from the backward-compatible default, the implementation should avoid treating an unbound default `Year 1` as transition intent. Use `PSBoundParameters` for CLI input and explicit column presence/nonempty checks for CSV input. Require an effective invoice for any explicit program year.

## Proposed test matrix

All tests must mock authentication and REST. Do not use a live Azure tenant.

### Target and payload tests

- Default target remains `Windows Server 2012`.
- Each exact target value binds successfully.
- Any other target fails before REST.
- Create payload emits the selected exact target.
- Mixed CSV rows emit distinct exact targets.
- Empty row Target falls back to `-target` and then to 2012.
- Exact license and profile API URIs use the approved endpoint-specific versions.

### Agent and eligibility tests

- 2012 and 2012 R2 accept 1.34 and reject 1.33.
- 2016 accepts 1.62 and rejects 1.61.
- A file with any unsupported row fails wholly before authentication or mutation.
- Standard vCore, Standard pCore, and Datacenter pCore remain valid.
- Datacenter vCore remains invalid for all targets.

### Volume Licensing and exception tests

- 2012/R2 row transition values override batch values.
- Blank row values fall back to batch values.
- No transition request omits `volumeLicenseDetails` rather than sending empty invoice records.
- Year 2 and Year 3 preserve the existing preceding-year array behavior for applicable 2012/R2 transitions.
- Any 2016 invoice/program-year transition input fails preflight with the documented reason.
- Any WS2012-specific exception/tag value on a 2016 row fails preflight.

### Target-neutral operation tests

- Single and bulk assignment payloads remain identical for 2012/R2 and 2016 license IDs.
- Unlink payload remains target-neutral.
- Status reads remain target-neutral.
- Delete URI remains target-neutral.
- Same-tenant cross-subscription resource IDs remain explicit.
- `WhatIf` and `DryRun` send no mutation requests for all targets.

### Documentation and samples

- Sample CSV imports with the new columns.
- English and French parameter/column tables remain synchronized.
- Local Markdown links resolve after documentation updates.
- Examples contain only fictitious identifiers and secrets.

## Suggested implementation phases

1. Add failing tests for target values, 2016 payloads, mixed CSVs, agent thresholds, and unsupported transition combinations.
2. Introduce endpoint-specific API-version constants and target resolution without changing assignment semantics.
3. Refactor bulk planning so all target, transition, and agent validation completes before authentication.
4. Update payload construction to omit inapplicable properties and pass effective row values explicitly rather than through a global target.
5. Verify assignment, status, unlink, and delete compatibility through mocked contracts.
6. Update samples, comment-based help, README files, and paired English/French guides.
7. Run parser, PSScriptAnalyzer, full Pester, link, CSV, credential, and whitespace gates.

## Documentation gaps and cautions

- The programmatic article's `2023-06-20-preview` examples and the versioned provider schemas are not aligned. Use the newer publicly documented schema that explicitly lists Windows Server 2016.
- The schema change log does not record the target enum expansion between `2025-09-16-preview` and `2026-02-12-preview`.
- Stable `2026-07-15` was separately observed through a first-party Azure provider schema query, but its public Learn pages were unavailable on the research date; it is not the recommended documented baseline.
- The portal says 2016 core type is selected during enablement, but the REST creation contract places `type` on the license and provides no assignment-level core-type field.
- The 2016 troubleshooting page refers to an applicable licensing package/SSU KB but does not name it. Do not substitute the 2012 KB.
- Microsoft documentation does not currently provide Windows Server 2016 equivalents for the WS2012-specific Arc exception tags. Do not reuse those tag values for 2016 or infer that a tag changes billing; confirm any 2016 DR benefit implementation against current licensing terms.

These ambiguities should be rechecked immediately before implementation. If Microsoft documentation remains inconclusive, do not infer a new payload or licensing behavior.

## Official Microsoft sources

- [Prepare to deliver Extended Security Updates for Windows Server through Azure Arc](https://learn.microsoft.com/azure/azure-arc/servers/prepare-extended-security-updates)
- [Deliver Extended Security Updates for Windows Server through Azure Arc](https://learn.microsoft.com/azure/azure-arc/servers/deliver-extended-security-updates)
- [Programmatically deploy and manage Azure Arc ESU licenses](https://learn.microsoft.com/azure/azure-arc/servers/api-extended-security-updates)
- [License provisioning guidelines](https://learn.microsoft.com/azure/azure-arc/servers/license-extended-security-updates)
- [Billing service for ESUs enabled by Azure Arc](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates)
- [Troubleshoot delivery of ESUs through Azure Arc](https://learn.microsoft.com/azure/azure-arc/servers/troubleshoot-extended-security-updates)
- [Windows Server 2016 lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2016)
- [Lifecycle FAQ for Extended Security Updates](https://learn.microsoft.com/en-us/lifecycle/faq/extended-security-updates)
- [`Microsoft.HybridCompute/licenses@2025-02-19-preview` schema](https://learn.microsoft.com/azure/templates/microsoft.hybridcompute/2025-02-19-preview/licenses)
- [`Microsoft.HybridCompute/licenses@2025-09-16-preview` schema](https://learn.microsoft.com/azure/templates/microsoft.hybridcompute/2025-09-16-preview/licenses)
- [`Microsoft.HybridCompute/licenses@2026-02-12-preview` schema](https://learn.microsoft.com/azure/templates/microsoft.hybridcompute/2026-02-12-preview/licenses)
- [`Microsoft.HybridCompute/licenses@2026-06-16-preview` schema](https://learn.microsoft.com/azure/templates/microsoft.hybridcompute/2026-06-16-preview/licenses)
- [`Microsoft.HybridCompute/machines/licenseProfiles@2026-06-16-preview` schema](https://learn.microsoft.com/azure/templates/microsoft.hybridcompute/2026-06-16-preview/machines/licenseprofiles)
- [License API-version change log](https://learn.microsoft.com/azure/templates/microsoft.hybridcompute/change-log/licenses)
