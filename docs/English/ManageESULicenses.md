# ManageESULicenses.ps1

`ManageESULicenses.ps1` validates a CSV file, creates or updates Azure Arc ESU licenses in bulk, and can optionally assign or unlink those licenses from Azure Arc-enabled servers.

License edition, core type, core count, activation state, program year, and invoice ID affect licensing and billing. Confirm the correct choices for your organization before running the script live. The rules in this guide are grounded in Microsoft's [ESU license provisioning guidance](https://learn.microsoft.com/azure/azure-arc/servers/license-extended-security-updates) and [ESU API guidance](https://learn.microsoft.com/azure/azure-arc/servers/api-extended-security-updates).

## Safe workflow

1. Run `CheckESUStatus.ps1` to inventory current assignments. It is read-only.
2. Copy the [ManageESULicenses CSV template](../../samples/ManageESULicenses.csv) and replace its fictitious values.
3. Run `ManageESULicenses.ps1 -DryRun` with the intended parameters.
4. Review every row in the validated operation plan, especially `LicenseName`, `CoreType`, normalized `CoreCount`, `CreationAction`, and `AssignmentAction`.
5. Review the existing/new license counts and operation summary.
6. Run the same command without `-DryRun` only after the plan is correct. Use `-WhatIf` for PowerShell operation previews or `-Confirm` for an interactive prompt per operation.

## CSV columns

Column names and literal values are case-insensitive in PowerShell, but use the spellings below for consistency.

| Column | Required | Description |
| --- | --- | --- |
| `Name` | Yes | Base name used for the ESU license and, when assignment is requested, the Azure Arc-enabled server name. The final license name is `licenseNamePrefix` + `Name` + `licenseNameSuffix`. Each final name must be unique in the CSV. |
| `Cores` | Yes | Positive whole-number core count before normalization. |
| `IsVirtual` | Yes | `Virtual` creates a `vCore` plan; `Physical` creates a `pCore` plan. |
| `AgentVersion` | Yes | Azure Connected Machine agent version. Rows below `1.34` are validated but skipped during live processing. |
| `ServerResourceGroupName` | Only for assignment actions | Resource group containing the server. Required when `AssignESULicense` is `True` or `False`. |
| `AssignESULicense` | No | `True` assigns the created or updated license, `False` unlinks it, and an empty value performs no assignment action. |
| `ESUException` | No | Text copied to the license resource's `ESU Usage` tag. It does not establish eligibility or change billing. |

Additional columns exported for inventory or filtering are allowed and ignored by the script.

```csv
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException
ws2012r2-app-01,4,Virtual,1.34,rg-arc-servers,,
ws2012r2-db-01,16,Physical,1.35,rg-arc-database,,
```

The template contains fictitious names only. Replace all values and review the result before use.

## Core and edition normalization

The script converts each CSV row into a plan before authentication or Azure operations:

| Input | Planned license | Normalization |
| --- | --- | --- |
| `IsVirtual=Virtual` with `edition=Standard` | `Standard` + `vCore` | Rounded up to an even number, with a minimum of 8 cores. |
| `IsVirtual=Physical` with `edition=Standard` | `Standard` + `pCore` | Rounded up to an even number, with a minimum of 16 cores. |
| `IsVirtual=Physical` with `edition=Datacenter` | `Datacenter` + `pCore` | Rounded up to an even number, with a minimum of 16 cores. |
| `IsVirtual=Virtual` with `edition=Datacenter` | Invalid | Preflight fails. Datacenter virtual-core licensing is not a valid combination. |

Examples: 4 virtual cores normalize to 8 `vCore`; 15 physical cores normalize to 16 `pCore`; 17 cores normalize to 18. A normalized license cannot exceed 10,000 cores. Microsoft also limits a resource group to 800 license resources; the script counts existing licenses and only the planned names that are new before proceeding.

Virtual-core licensing cannot be used for physical servers. Always use `Standard` for `vCore` licenses, even when the guest operating system is Datacenter. `Datacenter` is supported only with `pCore` in this workflow.

## Eligibility and tags

Establish eligibility for any no-cost or evaluation scenario separately under the applicable Microsoft licensing terms. `ESUException` only adds an `ESU Usage` tag to the Azure resource.

Tags do not affect billing. Microsoft states that billing is tied to the cores associated with an activated license regardless of tags, and cores used for evaluation or no-cost scenarios should not be provisioned in the Azure Arc ESU license. Do not treat any `ESUException` value as an approval, entitlement, or billing exemption.

## Preflight validation

The script validates the entire CSV before authentication. No row is processed if preflight reports any error. It rejects:

- An empty CSV or missing `Name`, `Cores`, `IsVirtual`, or `AgentVersion` columns.
- Empty names, non-positive or non-integer core counts, invalid agent versions, and `IsVirtual` values other than `Virtual` or `Physical`.
- `AssignESULicense` values other than `True`, `False`, or empty.
- Assignment or unlink rows without `ServerResourceGroupName`.
- Generated license names containing characters other than letters, numbers, hyphens, underscores, or periods.
- Assignment or unlink rows whose Azure Arc server `Name` is longer than 54 characters or contains other characters.
- Duplicate final license names after applying the prefix and suffix.
- Datacenter virtual-core rows and normalized license sizes above 10,000 cores.

After CSV validation and authentication, the script sends paginated read-only `GET` requests to count existing license resources and determine how many planned names are new. It stops if the combined count would exceed 800 licenses in the target resource group.

## Preview and confirmation controls

| Control | Behavior |
| --- | --- |
| `-DryRun` | Validates the full CSV, authenticates, performs the read-only license-count `GET` requests, prints the normalized plan and summary, and performs no mutations. It does not create, modify, assign, unlink, or delete resources. `-Preview` is an alias. |
| `-WhatIf` | Uses PowerShell `ShouldProcess` to preview each create/modify and assignment operation. CSV validation and the read-only license-count check still run. No mutation request is sent. |
| `-Confirm` | Prompts before each create/modify operation and, after a license is ready, before its assignment or unlink operation. CSV validation and the license-count check occur before the prompts. |

`-DryRun` is the clearest first pass because it prints one complete normalized plan without entering the live processing loop.

## Authentication precedence

Use one of these methods:

- `-userToken`: an unexpired token object returned by `Get-AzAccessToken -ResourceUrl https://management.azure.com/`.
- Service principal: provide `-tenantId`, `-appID`, and `-clientSecret` together.

If both methods are supplied, `-userToken` takes precedence. The identity must be authorized for the target license resource group and for server license profiles when assignment actions are requested. Never place credentials or tokens in a CSV file.

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/

./ManageESULicenses.ps1 `
    -subscriptionId "11111111-1111-1111-1111-111111111111" `
    -licenseResourceGroupName "rg-arc-esu-licenses" `
    -location "EastUS" `
    -state "Deactivated" `
    -edition "Standard" `
    -csvFilePath ".\samples\ManageESULicenses.csv" `
    -licenseNamePrefix "ESU-" `
    -userToken $authenticationToken `
    -DryRun
```

All IDs and names in this example are fictitious.

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `subscriptionId` | Yes | Subscription where licenses are created and where optional server assignments are performed. |
| `licenseResourceGroupName` | Yes | Resource group containing the licenses. |
| `location` | Yes | Azure region for the license and license-profile requests. |
| `state` | Yes | `Activated` or `Deactivated`. Activation state affects billing; validate the intended state. |
| `edition` | Yes | `Standard` or `Datacenter`. One value applies to every CSV row. |
| `csvFilePath` | Yes | Path to the input CSV. |
| `tenantId`, `appID`, `clientSecret` | Authentication dependent | All three are required for service-principal authentication when `userToken` is not provided. |
| `userToken` | Authentication dependent | User token object; takes precedence over service-principal credentials. `token` is an alias. |
| `licenseNamePrefix` | No | Text prepended to every `Name`; maximum 20 characters under the script's parameter validation. |
| `licenseNameSuffix` | No | Text appended to every `Name`; maximum 20 characters under the script's parameter validation. |
| `invoiceId` | No | Invoice number for an applicable Volume Licensing transition entitlement. Confirm applicability before use. |
| `programYear` | No | `Year 1`, `Year 2`, or `Year 3`; defaults to `Year 1`. The script includes preceding years when Year 2 or Year 3 is selected. |
| `logFileName` | No | Transcript log path. `log` is an alias. |
| `DryRun` | No | Complete non-mutating preview described above. |

The API provisions or modifies license resources and links or unlinks them through server license profiles. Microsoft documents these as Azure Resource Manager write operations. Do not run a live command until the preview is approved.

When a license is deactivated, billing may continue for up to five calendar days. Recreating a license remains subject to Microsoft's back-billing rules.

## Plan and summary

Before any live row processing, the script prints a `Validated operation plan` with:

- CSV row number and server name.
- Final license name.
- Core type and normalized core count.
- Agent version and creation action.
- Assignment action.

The final `ESU License Operation Summary` reports total validated rows, licenses created or modified, assignments completed, unlinks completed, rows skipped for agent version, previewed or declined operations, and failures. Any recorded failure produces a nonzero exit code.

## Live execution

After reviewing a successful dry run, remove `-DryRun` without changing the reviewed CSV or licensing parameters. Add `-Confirm` when you want an interactive decision for each operation:

```powershell
./ManageESULicenses.ps1 `
    -subscriptionId "11111111-1111-1111-1111-111111111111" `
    -licenseResourceGroupName "rg-arc-esu-licenses" `
    -location "EastUS" `
    -state "Deactivated" `
    -edition "Standard" `
    -csvFilePath ".\samples\ManageESULicenses.csv" `
    -licenseNamePrefix "ESU-" `
    -userToken $authenticationToken `
    -Confirm
```

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Missing-column or invalid-row error | Use the exact required headings, remove blank required values, and verify `Cores`, `IsVirtual`, `AgentVersion`, and `AssignESULicense`. Preflight lists all detected row errors together. |
| Duplicate final license name | Make `Name` values unique or change the prefix/suffix so every generated name is unique. |
| Datacenter virtual-core error | Use `-edition Standard` for a virtual CSV batch, or separate physical Datacenter rows into their own CSV and run. |
| Normalized count is higher than the CSV value | This is expected for odd counts and values below the 8-vCore or 16-pCore minimum. Review the printed plan before proceeding. |
| More than 10,000 normalized cores | Split the required cores across multiple licenses and unique `Name` values. |
| Resource-group count exceeds 800 | Use another resource group or reduce the number of new license resources in the batch. Existing names are treated as updates, not new licenses. |
| Agent version below 1.34 | Upgrade the Azure Connected Machine agent and regenerate or update the CSV. The row is skipped during live processing. |
| Authentication fails | Refresh `userToken`, or provide all three service-principal parameters. Confirm the identity has access to every affected resource. |
| Assignment fails after license creation | Check the server name, `ServerResourceGroupName`, location, permissions, and current license-profile state. Use `CheckESUStatus.ps1` to recheck the assignment. |
| Unsure whether a scenario is no-cost | Stop before activation. Confirm eligibility under Microsoft's current terms; do not rely on `ESUException` or Azure resource tags. |

For bulk assignment of licenses that already exist, use [ManageESUAssignments.ps1](ManageESUAssignments.md) and its [CSV template](../../samples/ManageESUAssignments.csv).
