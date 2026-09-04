# Dev Branch Recovery Plan

## Objective

Bring `dev` to a merge-ready state relative to `main` by correcting the identified runtime defects, restoring reliable automation behavior, synchronizing English and French documentation, and adding focused non-Azure validation.

Do not execute any live Azure mutation while implementing this plan. Authentication and REST behavior must be tested with mocks or local probes only.

## Guardrails

- Preserve existing public parameter names, aliases, CSV columns, authentication methods, output objects, and cross-subscription priority rules unless a compatibility change is explicitly approved.
- Keep the direct Azure Resource Manager REST implementation.
- Never print or persist bearer tokens, client secrets, or authorization headers.
- Make equivalent functional changes in `ManageESUAssignments.ps1` and `ManageESUAssignmentsFR.ps1`.
- Update English and French documentation together when counterparts exist.
- Use endpoint-specific API versions verified against the current `Microsoft.HybridCompute` provider catalog and Microsoft Learn.
- Parse and analyze every changed PowerShell script. Do not use a live Azure tenant as a test target.

## Recovery Order

The first two defects interact: pipeline-contaminating logging currently causes failed API-version checks to evaluate as successful. Fix and validate them as one change so correcting one does not leave the script either failing open or blocking all assignments.

### Phase 1: Establish Focused Tests

- [x] Add a small Pester test suite for pure and mocked behavior.
- [x] Mock `Invoke-RestMethod`, authentication calls, transcripts, progress output, and sleeps.
- [x] Add a test proving each Boolean helper emits exactly one Boolean value.
- [x] Add assignment success and failure tests that verify the summary counters and final exit-code decision.
- [x] Add access-check tests for both `Microsoft.HybridCompute/machines` and `Microsoft.HybridCompute/licenses`.
- [x] Add cross-subscription tests for this priority order:
  1. CSV `LicenseSubscriptionId`.
  2. `-licenseSubscriptionId` parameter.
  3. Arc server subscription fallback.
- [x] Add dry-run tests proving no `PUT`, `PATCH`, or `DELETE` request is sent. Read-only `GET` validation may remain and must be documented.
- [x] Add authentication rejection tests for missing credentials, expired user tokens, and failed service-principal token acquisition.

Suggested test files:

- `tests/ManageESUAssignments.Tests.ps1`
- `tests/AuthenticationExitCodes.Tests.ps1`
- `tests/CheckESUStatus.Tests.ps1`

### Phase 2: Repair Bulk-Assignment Result Handling

Affected files:

- `Scripts/windows/ManageESUAssignments.ps1`
- `Scripts/windows/ManageESUAssignmentsFR.ps1`

Tasks:

- [x] Remove `Write-Output $logMessage` from `Write-Logfile`, or replace it with a non-success-stream logging mechanism consistent with the current console/transcript design.
- [x] Ensure `Test-AzureResourceAccess` returns exactly one Boolean value on every path.
- [x] Ensure `AssignESULicense` returns exactly one Boolean value on every path.
- [x] Ensure `Test-ServicePrincipalPermissions`, if retained, also returns an uncontaminated Boolean.
- [x] Verify `$result` cannot become a multi-item array before incrementing success or failure counters.
- [x] Verify logging still appears once and is captured by `Start-Transcript` when enabled.

Acceptance criteria:

- A mocked failed access check is false in Boolean context.
- A mocked failed assignment increments `$errorCount`, not `$successCount`.
- Any failed non-dry-run operation produces final exit code `1`.
- English and French scripts behave identically.

### Phase 3: Correct Resource-Specific API Versions

Affected files:

- `Scripts/windows/ManageESUAssignments.ps1`
- `Scripts/windows/ManageESUAssignmentsFR.ps1`

Tasks:

- [x] Replace the generic `api-version=2022-11-01` access check with verified versions for each resource type.
- [x] Prefer explicit configuration entries such as `MachineApiVersion`, `LicenseApiVersion`, and `LicenseProfileApiVersion` rather than one version used for unrelated endpoints.
- [x] Keep the assignment request on a version that supports `Microsoft.HybridCompute/machines/licenseProfiles` and `esuProfile.assignedLicense`.
- [x] Reject unknown resource types rather than silently selecting an arbitrary API version.
- [x] Add tests that inspect generated URIs and assert the correct version for each resource type.
- [x] Record the Microsoft Learn/provider-catalog source used to choose each version in a concise code comment or documentation note.

Known evidence to revalidate during implementation:

- `2022-11-01` is not registered for either `Microsoft.HybridCompute/machines` or `Microsoft.HybridCompute/licenses`.
- `Microsoft.HybridCompute/licenses` supports `2023-06-20-preview` and later registered versions.
- The documented ESU license-profile contract supports `2023-06-20-preview`.

Acceptance criteria:

- Mocked access checks call only registered API versions.
- A failed access check stops the corresponding assignment.
- Cross-subscription resource IDs continue to use the license subscription explicitly.

### Phase 4: Make Failure Exit Codes Reliable

Affected files:

- `Scripts/windows/AssignESULicense.ps1`
- `Scripts/windows/CreateESULicense.ps1`
- `Scripts/windows/DeleteESULicense.ps1`
- `Scripts/windows/ManageESUAssignments.ps1`
- `Scripts/windows/ManageESUAssignmentsFR.ps1`

Tasks:

- [x] Replace bare `exit` statements on missing credentials and expired tokens with `exit 1`.
- [x] After service-principal authentication, stop with `exit 1` when no access token is returned.
- [x] Preserve exit code `0` only for completed successful operations and successful dry runs.
- [x] Confirm REST failures are surfaced consistently and do not fall through as successful script completion.

Acceptance criteria:

- Missing credentials, expired tokens, token acquisition failures, validation failures, and REST failures return nonzero process exit codes.
- Valid dry runs return `0` without mutation.
- Existing successful output objects remain unchanged where scripts currently return ARM responses.

### Phase 5: Resolve the Status-Script Parameter Contract

Affected files:

- `Scripts/windows/CheckESUStatus.ps1`
- `docs/CheckESUStatus.md`
- `README.md`
- New French counterparts described in Phase 6

Decision checkpoint:

- [x] Confirm whether `-location` should be removed, retained as an optional compatibility parameter, or used for an additional validated purpose.

Recommended compatibility path:

- Retain `-location` temporarily but make it optional because the read-only license-profile `GET` does not consume it.
- Mark it as retained for backward compatibility in comment-based help.
- Remove it from new examples while continuing to accept existing command lines.

Additional tasks:

- [x] Remove or use the unused `retryCount` and `retryDelaySeconds` parameters. Prefer making retry logic consume the parameters rather than retaining misleading controls.
- [x] Add tests for single-server mode, CSV mode, `Name`/`ARCServerName` compatibility, per-row subscription overrides, status counts, CSV export failure, and final exit codes.

Acceptance criteria:

- Status checks no longer require irrelevant location input.
- Existing callers that still pass `-location` continue to work under the recommended path.
- PSScriptAnalyzer no longer reports the status script's unused `location` or retry parameters.

### Phase 6: Restore Documentation Parity

Affected files:

- `README.md`
- `LISEZMOI.md`
- `docs/ManageESUAssignments.md`
- `docs/ManageESUAssignmentsFR.md`
- `docs/CheckESUStatus.md`
- New `docs/CheckESUStatusFR.md`
- Comment-based help in changed scripts

Tasks:

- [x] Update `README.md` authentication guidance to include `ManageESUAssignments.ps1` user-token support.
- [x] Document `-arcServerSubscriptionId` as the canonical parameter and `-subscriptionId` as its compatibility alias.
- [x] Document `-licenseSubscriptionId`, CSV `LicenseSubscriptionId` precedence, `-userToken`, and `-DryRun` in the dedicated assignment documentation.
- [x] Rewrite `docs/ManageESUAssignmentsFR.md` in French rather than leaving it as an English duplicate.
- [x] Add `CheckESUStatus.ps1` to the French script inventory and correct the script count.
- [x] Create `docs/CheckESUStatusFR.md` synchronized with the English status documentation.
- [x] Apply the Phase 5 `-location` decision consistently to help and examples.
- [x] State clearly that dry-run performs read-only validation requests but sends no mutation request.
- [x] Remove the stale claim that bulk assignment support is still forthcoming.
- [x] Correct the pre-existing French `AssignESULicense` example that passes unsupported `-invoiceId` and `-programYear` parameters.
- [x] Verify all examples use fictitious IDs and secrets.
- [x] Check every Markdown link and image path from the repository root and from `docs/`.

Acceptance criteria:

- English and French documentation describe the same scripts, parameters, authentication methods, CSV columns, and safety behavior.
- Every documented command binds successfully without contacting Azure when inspected or tested with mocks.
- No documentation recommends unsupported parameters or broader RBAC than required.

### Phase 7: Analyzer and Code-Quality Follow-up

Do not mix broad style churn into the runtime-recovery commits. Address correctness-related analyzer findings first, then handle remaining cleanup in a separate change.

- [x] Eliminate unused retry parameters or wire them into retry logic.
- [x] Review global variables introduced or touched by this branch and replace them with script-scoped values where behavior can be preserved.
- [x] Decide and document repository encoding policy before addressing BOM warnings, especially for French files.
- [x] Remove branch-introduced trailing whitespace.
- [x] Keep existing `Write-Host` behavior unless output-contract changes are explicitly approved; do not mass-convert it as part of recovery.
- [x] Capture a PSScriptAnalyzer baseline so new warnings can be distinguished from legacy warnings.

## Validation Checklist

Run after each implementation phase:

```powershell
$errors = @()
Get-ChildItem -Path . -Filter *.ps1 -Recurse -File | ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    $errors += $parseErrors
}
if ($errors) { $errors; exit 1 }
```

```powershell
Invoke-ScriptAnalyzer -Path .\Scripts -Recurse
```

```powershell
Invoke-Pester -Path .\tests
```

Final review:

- [x] All changed `.ps1` files parse successfully.
- [x] Focused Pester tests pass without Azure credentials or network access.
- [x] No new PSScriptAnalyzer correctness or security warnings remain.
- [x] No token, secret, tenant ID, subscription ID, or authorization header appears in the diff or test output.
- [x] English/French counterparts are synchronized.
- [x] Public parameters, aliases, CSV schemas, and output objects remain compatible except for explicitly approved changes.
- [x] `git diff origin/main...dev` contains no unrelated formatting churn.

## Suggested Commit Sequence

1. `Add mocked tests for ESU assignment behavior`
2. `Fix bulk assignment result handling and API validation`
3. `Return nonzero exit codes for authentication failures`
4. `Make status check location parameter optional`
5. `Synchronize English and French ESU documentation`
6. `Address branch-introduced analyzer findings`

## Merge Exit Criteria

The branch is ready to merge only when:

- Bulk assignments cannot report a failed REST operation as successful.
- Access validation uses registered, resource-specific API versions and fails closed.
- Authentication and operational failures return nonzero exit codes.
- Dry-run sends no mutation requests.
- The status checker has a compatible and meaningful parameter contract.
- English and French documentation are complete and synchronized.
- Parser, focused Pester, and PSScriptAnalyzer validation have been recorded.