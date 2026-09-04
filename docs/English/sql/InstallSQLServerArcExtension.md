# InstallSQLServerArcExtension.ps1

## Purpose and scope

`InstallSQLServerArcExtension.ps1` installs `Microsoft.AzureData/WindowsAgent.SqlServer` on an existing Windows Arc machine only when the extension is absent. It enables SQL management and automatic extension upgrades and sets `LicenseType` to `Paid`, `PAYG`, or `LicenseOnly`. It does not update, upgrade, repair, or replace an existing extension, enable ESUs, or deploy patches.

This workflow supports Commercial Azure and Windows only, on machines already connected to Azure Arc. Connected Machine agent installation, upgrade, and repair, native Azure VMs, Linux, other clouds, SQL versions beyond this repository's SQL Server 2014/2016 ESU workflow, physical-core pooled licenses, unlimited virtualization, and automatic patch deployment are out of scope.

## Prerequisites and boundaries

- PowerShell 7.x on Windows; an existing Arc machine reporting `Connected`, agent mode `Full`, Windows, and a supported Arc SQL location.
- Registered `Microsoft.HybridCompute` and `Microsoft.AzureArcData` providers. The script does not register them.
- Customer confirmation of the external prerequisites represented by `-ConfirmExternalPrerequisites` or the CSV `TRUE` value.
- A reviewed `LicenseType`. `Paid` represents a qualifying license with Software Assurance/subscription, `PAYG` uses pay-as-you-go SQL software billing, and `LicenseOnly` does not qualify for Arc-enabled SQL Server ESUs.

The extension is a host resource and its settings apply across SQL instances discovered on that host. Installation is create-only: if the expected extension exists, the script returns `AlreadyInstalled` and leaves all settings untouched. Later ESU lifecycle changes use [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md), which reads current settings, merges only approved ESU changes, and PUTs the preserved settings.

## Least-privilege role

Create both custom roles in each target subscription. Assign [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) at subscription scope for provider, inventory, machine, and extension reads. Assign [SQL Server Arc ESU Operator](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) only on each target machine resource group; it grants only `Microsoft.HybridCompute/machines/extensions/write`. This split avoids subscription-wide extension write access. Neither role grants machine write/delete, provider registration, or `sqlServerEsuLicenses` permission. Replace the fictitious assignable subscription before creating each role.

## Authentication

Use exactly one path:

- `-userToken`: an unexpired `Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'` token object.
- Service principal: `-tenantId`, `-appID`, and `-clientSecret` together.

Supplying both paths or an incomplete path fails authentication. Never store credentials in the CSV.

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `subscriptionId` | Single mode; optional fallback in CSV mode | Subscription containing the Arc machine. |
| `serverResourceGroupName`, `ARCServerName` | Single mode | Existing machine target. |
| `LicenseType` | Single mode | Exact value `Paid`, `PAYG`, or `LicenseOnly`. |
| `ConfirmExternalPrerequisites` | Single mode | Must be present; records customer confirmation of checks ARM cannot perform. |
| `csvFilePath` | CSV mode | Existing CSV using the exact schema below. |
| `tenantId`, `appID`, `clientSecret` | Authentication dependent | Complete service-principal path. |
| `userToken` | Authentication dependent | User token path. |
| `DryRun` | No | Full read-only preflight; sends no PUT. `Preview` is an alias. |
| `WhatIf`, `Confirm` | No | Standard `ShouldProcess` preview or high-impact confirmation controls. |

## Single-machine example

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/InstallSQLServerArcExtension.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-01' `
    -LicenseType Paid `
    -ConfirmExternalPrerequisites `
    -userToken $authenticationToken `
    -DryRun
```

After review, remove `-DryRun` and use `-Confirm` for the live installation.

## CSV input

Start with [InstallSQLServerArcExtension.csv](../../../samples/InstallSQLServerArcExtension.csv).

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,ConfirmExternalPrerequisites
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-01,Paid,TRUE
```

```powershell
./Scripts/sql/InstallSQLServerArcExtension.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\InstallSQLServerArcExtension.csv' `
    -userToken $authenticationToken `
    -DryRun
```

The exact required columns are `SubscriptionId`, `ServerResourceGroupName`, `ARCServerName`, `LicenseType`, and `ConfirmExternalPrerequisites`. A blank row subscription uses `-subscriptionId`. Names must use supported Azure characters; the machine name is 1-54 characters. `LicenseType` must be `Paid`, `PAYG`, or `LicenseOnly`; confirmation must be `TRUE`. Duplicate machine targets are rejected case-insensitively. Missing files, non-CSV files, no data rows, missing columns, and any invalid row reject the entire plan before authentication. Unknown columns are warned and ignored.

## Preview and execution safety

`-DryRun` performs complete machine, provider, regional capability, and extension preflight, then returns `Previewed` without PUT. `-WhatIf` performs the same preflight and invokes `ShouldProcess` without PUT. `-Confirm` prompts before each installation. All targets complete preflight before the first mutation; one preflight failure makes otherwise valid rows `NotStarted`. An expected existing extension is never modified.

The live PUT creates object-built settings with SQL management and automatic extension upgrades enabled, the reviewed license type, and an empty excluded-instance list. It intentionally omits the ESU setting. The script polls accepted operations, then GETs and verifies the final extension.

## Output and exit semantics

Each result contains `RowNumber`, `SubscriptionId`, `ServerResourceGroupName`, `ARCServerName`, `LicenseType`, `Status`, `ProvisioningState`, and `Message`.

Statuses are `Succeeded`, `AlreadyInstalled`, `Previewed`, `Declined`, `Failed`, or `NotStarted`. Exit `0` means every row succeeded, was already installed, or was previewed. Exit `1` means validation/authentication failed or at least one row was failed, declined, or not started. Runtime failures do not prevent later independent rows from running.

## Billing and safety

Installing this extension does not enroll the host in ESUs and does not deploy patches. However, `LicenseType` also represents SQL Server software licensing configuration, so confirm `Paid`, `PAYG`, or `LicenseOnly` with your licensing owner. ESU enrollment is a separate billing-sensitive operation. The extension detects host type and cores; do not infer physical-pool or unlimited-virtualization coverage from this script.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Confirmation validation fails | Set `-ConfirmExternalPrerequisites` or CSV `ConfirmExternalPrerequisites=TRUE` only after completing external checks. |
| Provider/capability failure | Register providers separately with an authorized identity and verify the machine region supports Arc SQL inventory. |
| `AlreadyInstalled` | This is idempotent success; use supported extension-management tooling for upgrades or repair. |
| Identity conflict | Inspect the existing extension publisher/type; the script refuses to overwrite an unexpected extension. |
| Final verification fails | Check extension provisioning, automatic upgrade, SQL management, license type, and that ESU was not unexpectedly enabled. |
| Exit `1` in a batch | Review `Failed`, `Declined`, and `NotStarted`; preflight failures prevent all PUTs, while runtime failures allow independent rows to continue. |

## References

- [SQL Server Extended Security Updates enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [Hybrid Compute REST API](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Azure custom roles](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)
