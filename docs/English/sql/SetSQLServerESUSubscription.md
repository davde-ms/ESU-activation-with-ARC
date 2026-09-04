# SetSQLServerESUSubscription.ps1

## Purpose and scope

`SetSQLServerESUSubscription.ps1` enables or disables the host-level SQL Server ESU setting on an existing `WindowsAgent.SqlServer` extension. It supports global Azure endpoints and Windows machines already connected to Azure Arc; it is not compatible with Azure Government endpoints as written. It does not install, upgrade, or repair the Connected Machine agent or SQL extension; manage native Azure VMs or Linux; deploy patches; configure automatic patching; accept customer core counts; or manage physical-core pooled ESU licenses/unlimited virtualization.

Only SQL Server 2014 and 2016 are supported. Enablement requires eligible inventory and explicit billing acknowledgements. Disable remains available with degraded inventory/provider/machine evidence so a customer is not blocked from canceling future charges; it still requires a readable extension with the exact expected identity and public settings.

## Prerequisites and boundaries

- PowerShell 7.x on Windows; registered providers; an existing connected, Full-mode Arc machine and healthy supported `WindowsAgent.SqlServer` extension for enablement.
- `SqlManagement.IsEnabled=true`, effective `LicenseType` `Paid` or `PAYG`, and discovered SQL Server 2014/2016 inventory. Standard/Enterprise are production editions; Developer requires confirmed qualifying nonproduction coverage.
- External entitlement, prior-year coverage, local permissions, connectivity, and HA/DR compliance must be confirmed outside ARM.

The setting affects the entire host/OSE, not one named SQL instance. All eligible instances and associated services can be affected, and SQL Server 2014 and 2016 can meter separately. This script performs a settings-preserving GET-merge-PUT: it GETs the extension, deep-copies public settings, changes only `enableExtendedSecurityUpdates`, `esuLastUpdatedTimestamp`, and an explicitly approved enable-time `LicenseType`, then PUTs and verifies semantic preservation. Protected and response-only properties are never copied.

For `Disable`, the script intentionally reads only the expected extension and bypasses machine, provider, and SQL inventory gates. This cancellation path remains available when inventory or health evidence is degraded because requiring healthy discovery could prevent a customer from stopping future ESU charges. Wrong extension identity or unreadable public settings still blocks mutation.

## Least-privilege role

Create both custom roles in each target subscription. Assign [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) at subscription scope for provider, inventory, machine, and extension reads. Assign [SQL Server Arc ESU Operator](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) only on each target machine resource group; it grants only extension write. This split avoids subscription-wide extension write access. Neither role grants machine write/delete, provider registration, or `sqlServerEsuLicenses` permissions.

## Authentication

Use exactly one path: `-userToken` with an unexpired `Get-AzAccessToken` object, or the complete `-tenantId`, `-appID`, `-clientSecret` service-principal set. Both paths together or an incomplete set fail. Keep secrets outside CSV and logs.

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `subscriptionId` | Single mode; optional CSV fallback | Subscription containing the Arc machine. |
| `serverResourceGroupName`, `ARCServerName` | Single mode | Existing target host. |
| `Action` | Single mode | `Enable` or `Disable`. |
| `LicenseType` | Enable only, optional | Empty preserves current value; otherwise `Paid` or `PAYG`. |
| `Environment` | Enable only | `Production` or `NonProduction`. |
| `AcceptBackBilling` | Enable only | Required acknowledgement. |
| `AcceptLicenseTypeChange` | Enable only when value changes | Explicitly approves changing the existing license type. |
| `ConfirmNonProductionCoverage` | Enable only when required | Required for Developer on `NonProduction`. |
| `ConfirmExternalPrerequisites` | Enable only | Required acknowledgement of checks ARM cannot prove. |
| `csvFilePath` | CSV mode | Exact schema below. |
| `tenantId`, `appID`, `clientSecret`; `userToken` | Authentication dependent | Choose one authentication path. |
| `DryRun` | No | Full read-only preflight and billing preview; no PUT. `Preview` alias. |
| `WhatIf`, `Confirm` | No | Standard high-impact `ShouldProcess` controls. |

## Single-machine example

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/SetSQLServerESUSubscription.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-01' `
    -Action Enable `
    -Environment Production `
    -AcceptBackBilling `
    -ConfirmExternalPrerequisites `
    -userToken $authenticationToken `
    -DryRun
```

Cancellation has no enable-only values:

```powershell
./Scripts/sql/SetSQLServerESUSubscription.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-01' `
    -Action Disable `
    -userToken $authenticationToken `
    -WhatIf
```

## CSV input

Start with [SetSQLServerESUSubscription.csv](../../../samples/SetSQLServerESUSubscription.csv).

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName,Action,LicenseType,Environment,AcceptBackBilling,AcceptLicenseTypeChange,ConfirmNonProductionCoverage,ConfirmExternalPrerequisites
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-01,Enable,,Production,TRUE,FALSE,FALSE,TRUE
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-02,Disable,,,,,,
```

```powershell
./Scripts/sql/SetSQLServerESUSubscription.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\SetSQLServerESUSubscription.csv' `
    -userToken $authenticationToken `
    -DryRun
```

All ten displayed columns are required. A blank subscription uses the command fallback. Boolean controls accept only `TRUE`, `FALSE`, or empty where optional. `Enable` requires a valid environment, `AcceptBackBilling=TRUE`, and `ConfirmExternalPrerequisites=TRUE`; a license change requires `AcceptLicenseTypeChange=TRUE`; nonproduction Developer requires `ConfirmNonProductionCoverage=TRUE`. `Disable` requires every enable-only field to be empty. Duplicate/contradictory hosts are rejected. Unknown columns resembling a billing/control field are rejected; unrelated unknown columns are warned and ignored. Any local error rejects the complete file before authentication.

## Preview and execution safety

`-DryRun` completes preflight, prints exact host/license/version/core/billing evidence, and sends no PUT. `-WhatIf` adds `ShouldProcess` preview; `-Confirm` prompts for each host. All Azure preflight finishes before the first mutation. A preflight failure makes valid rows `NotStarted`; after mutations begin, independent rows continue after runtime failures.

An already matching state returns `AlreadyCompliant` without PUT or timestamp change. Live operations retry transient responses, accept trusted asynchronous polling URLs only, and repeatedly GET until the desired state, timestamp, license type, and unrelated settings are verified.

## Output and exit semantics

Each result contains `RowNumber`, `SubscriptionId`, `ResourceGroupName`, `MachineName`, `MachineResourceId`, `RequestedAction`, `PreviousState`, `DesiredState`, `EffectiveState`, `PreviousLicenseType`, `DesiredLicenseType`, `EffectiveLicenseType`, `HostType`, `DetectedCores`, `InstanceNames`, `ServiceTypes`, `EligibleVersions`, `InventoryFreshness`, `UsageFreshness`, `OperationStatus`, `VerificationSucceeded`, and `Message`.

`OperationStatus` is `Succeeded`, `AlreadyCompliant`, `Previewed`, `Declined`, `Failed`, or `NotStarted`. Exit `0` means every row succeeded, was already compliant, or was previewed. Exit `1` means validation/authentication failed or any row was failed, declined, or not started.

## Billing and safety

Enablement can cause current-year bill-back: Microsoft documents July 10, 2024 as the SQL Server 2014 ESU year-one start and July 14, 2026 for SQL Server 2016. Re-enable/reconnection scenarios can also bill back. Host usage has a four-core minimum, and each eligible version on one host can meter separately. `AcceptBackBilling` records acknowledgement; it does not establish entitlement.

Cancellation stops future ESU charges under Microsoft's current guidance, but removes future update access; later reactivation can bill back. The script does not deploy ESU patches or enable automatic patching. Physical-core pooled licenses and unlimited virtualization are separate resource/lifecycle models and are not changed.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Enable acknowledgement error | Supply required `TRUE` values only after licensing and external review. |
| License change rejected | Add `AcceptLicenseTypeChange=TRUE` only after approving the displayed old/new value. |
| Developer rejected | Use `NonProduction` and confirm qualifying coverage, or stop and resolve entitlement. |
| Stale inventory warning | Refresh inventory; staleness alone does not block enablement, but evidence is uncertain. |
| Disable warns about degraded evidence | Expected behavior: cancellation proceeds from the verified extension settings so future charges can be stopped. |
| Verification timeout | Check extension health and whether another process changed ESU, license, or unrelated settings. |
| Patches are not installed | Enrollment is not patch deployment. Review automatic update configuration or Microsoft's manual download process. |

## References

- [SQL Server Extended Security Updates enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [Hybrid Compute REST API](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Azure custom roles](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)