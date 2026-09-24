# SetSQLServerESUSubscription.ps1

## Purpose and scope

`SetSQLServerESUSubscription.ps1` enables or disables the per-Arc-machine/OSE SQL Server ESU setting on an existing `WindowsAgent.SqlServer` extension. It supports global Azure endpoints and Windows machines already connected to Azure Arc; it is not compatible with Azure Government endpoints as written. It does not install, upgrade, or repair the Connected Machine agent or SQL extension; manage native Azure VMs or Linux; deploy patches; configure automatic patching; accept customer core counts; or manage physical-core pooled ESU licenses/unlimited virtualization.

Review the [SQL Server ESU object-model overview](README.md) for VM vCore metering and the contrast with Windows Server license assignment. `ServerResourceGroupName` is the resource group containing the Arc machine; no separate SQL license object or license resource group is created.

Only SQL Server 2014 and 2016 are supported. Enablement requires eligible inventory and explicit billing acknowledgements. Disable remains available with degraded inventory/provider/machine evidence so a customer is not blocked from canceling future charges; it still requires a readable extension with the exact expected identity and public settings.

## Prerequisites and boundaries

- PowerShell 7.x on Windows; registered providers; an existing connected Arc machine whose `agentConfiguration.configMode` is `full`, and a healthy `WindowsAgent.SqlServer` extension at version `1.1.3518.465` or newer (the running version from `instanceView` is used when reported) for enablement.
- `SqlManagement.IsEnabled=true`, effective `LicenseType` `Paid` or `PAYG`, and discovered SQL Server 2014/2016 inventory. Standard/Enterprise are production editions; Developer requires confirmed qualifying nonproduction coverage.
- External entitlement, prior-year coverage, local permissions, connectivity, and HA/DR compliance must be confirmed outside ARM.

`LicenseType` describes the underlying SQL Server software license; it does not indicate that ESUs are paid. `Paid` means qualifying Software Assurance/SQL subscription rights, while `PAYG` means Azure bills the SQL software license hourly. The separate `enableExtendedSecurityUpdates` setting starts or stops the ESU subscription and its metering. This script never changes `LicenseType`, so it cannot switch a host to `PAYG` or change any other SQL payment model; hosts that are `LicenseOnly` or undefined are blocked, not converted. To fill an undefined value after a licensing decision, use the separate [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md). See [Why LicenseType is never changed](#why-licensetype-is-never-changed) and [LicenseType describes the SQL Server software license](README.md#sql-license-type).

The setting affects the entire host/OSE, not one named SQL instance. All eligible instances and associated services can be affected, and SQL Server 2014 and 2016 can meter separately. This script performs a settings-preserving GET-merge-PUT: it GETs the extension, deep-copies public settings, changes only `enableExtendedSecurityUpdates` and `esuLastUpdatedTimestamp`, refuses to send any request that would change `LicenseType`, then PUTs and verifies semantic preservation, including an unchanged `LicenseType`. Protected and response-only properties are never copied.

For `Disable`, the script intentionally reads only the expected extension and bypasses machine, provider, and SQL inventory gates. This cancellation path remains available when inventory or health evidence is degraded because requiring healthy discovery could prevent a customer from stopping future ESU charges. Wrong extension identity or unreadable public settings still blocks mutation.

<a id="why-licensetype-is-never-changed"></a>

## Why LicenseType is never changed

This script only turns the ESU subscription on or off. It **never sets, changes, or clears `LicenseType`**. There is deliberately no switch, parameter, or CSV column that makes it do so, even as an opt-in. Adding a "set the license type before enabling ESU" option was evaluated and rejected for the following reasons.

1. **It protects the customer's SQL payment model.** Enabling ESUs must never change how SQL Server software is paid for. Any code path in the ESU script that can write `LicenseType` can be triggered by mistake, even behind a switch: a copied CSV row, a Resource Graph export, or a pipeline default. At scale, that could move many hosts to `PAYG` and start Azure billing for SQL Server software that the customer already licensed. Filling an empty `LicenseType` is therefore a separate, explicitly acknowledged step in [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md), which never overwrites an existing value.
2. **`Paid` is a legal attestation that a script can't verify.** Microsoft states: "By selecting a license with Software Assurance, you attest that you have Enterprise or Standard licenses with active Software Assurance or an active SQL Server subscription license, and that the device is in compliance with the Product Terms outsourcing restrictions." Only the license owner can make that statement. An ESU operator or an automated job shouldn't make it on their behalf.
3. **`PAYG` is an Azure billing decision for the SQL Server software license.** It bills the SQL software license hourly through Azure, in addition to the ESU charge. For subscriptions managed by a Cloud Solution Provider (CSP), enabling pay-as-you-go also requires consent to recurring billing.
4. **Customers without Software Assurance can't legitimately become `Paid`.** Microsoft states: "To subscribe to ESUs, you must have active Software Assurance or enable a pay-as-you-go billing for SQL Server software." A license without Software Assurance isn't eligible. A host that is `LicenseOnly` because it has no Software Assurance therefore has only one Arc ESU route: `PAYG`. That is exactly the billing change this repository refuses to make on the customer's behalf.
5. **Server+CAL hosts must stay `LicenseOnly`.** Microsoft states: "If your instance uses this license, you must set the license type to LicenseOnly, even if you have active Software Assurance for it." Microsoft also states that the Arc ESU subscription isn't available for the Server+CAL licensing model; its only Arc route is to switch to `PAYG`. An Enterprise (non-Core) installation indicates Server+CAL. Automatically switching such a host to `Paid` would create a licensing compliance violation.
6. **`LicenseType` applies to the whole host, not only the out-of-support instance.** It is a setting of the single `WindowsAgent.SqlServer` extension on the Arc machine. It therefore applies to every SQL Server instance in that OSE, including supported SQL Server 2017 or later instances that don't need ESUs. Changing it to enable ESUs for SQL Server 2014/2016 would also re-attest or re-bill those other instances.
7. **Separate changes keep billing auditable and reversible.**
   - When ESU is enabled, Azure billing begins at the start of the current ESU year (bill-back). Combining a license type change and ESU enablement in one write mixes two billing events, which makes charge verification, auditing, and root-cause analysis harder.
   - The two changes also can't always be undone independently. Microsoft's own license type script refuses to switch a host to `LicenseOnly` while ESU is enabled.

### What to do when a host is LicenseOnly or undefined

`Enable` fails preflight for that host and no change is made. Then:

1. **The license owner decides** the correct `LicenseType` for the whole host based on entitlement:
   - Active Software Assurance or SQL Server subscription for the host's core-based licenses: `Paid`.
   - An approved decision to pay for the SQL Server software license through Azure: `PAYG`.
   - Server+CAL, or a perpetual license without Software Assurance: `LicenseOnly`. That host isn't eligible for ESU through this script.
2. **Set it outside this script:**
   - **Undefined (empty) `LicenseType`:** use [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md). It fills an empty value only, never overwrites an existing one, shows the impact of the chosen value, and requires the matching acknowledgement. See [How LicenseType gets populated](README.md#how-licensetype-gets-populated) for why a host can be empty.
   - **`LicenseOnly` or any other existing value:** no script in this repository changes it. If the license owner decides a change is legitimate, use the Azure portal, or Microsoft's official [modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type) sample, which is referenced from [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17#modify-sql-server-configuration).
   - When you use the sample, keep the two changes separate: run it with `-LicenseType` only, without `-EnableESU`.
   - Scope the sample to the intended machines, for example with `-MachineName` and a CSV. Without `-MachineName`, it targets every Arc-enabled SQL Server in the given subscription or resource group, or in all subscriptions if none is given. Run it with `-ReportOnly` first to list what would change.
   - Without `-Force`, the sample sets `-LicenseType` only on extensions where it is undefined. With `-Force`, it overwrites the existing value on every extension in scope, including hosts that are already `Paid` or `PAYG`.
   - Don't select `PAYG` with any tool unless Azure billing for the SQL Server software license is the intended, approved decision.
3. **Verify, then enable:** confirm the new value with [CheckSQLServerESUStatus.ps1](CheckSQLServerESUStatus.md) or [TestSQLServerArcESUPrerequisites.ps1](TestSQLServerArcESUPrerequisites.md). Then run this script with `-DryRun`, and finally run the live `Enable`.

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
| `LicenseType` | Enable only, optional | Assertion of the current value (`Paid` or `PAYG`). The script never changes `LicenseType`; a mismatch fails preflight. |
| `Environment` | Enable only | `Production` or `NonProduction`. |
| `AcceptBackBilling` | Enable only | Required acknowledgement. |
| `AcceptLicenseTypeChange` | Must be empty or FALSE | Retained for compatibility; TRUE is rejected because license type changes are not supported. |
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
To build the file from current Azure inventory, review every constant at the top of [SetSQLServerESUSubscription.kql](../../../samples/SetSQLServerESUSubscription.kql), run it in Azure Resource Graph Explorer, and download the result as CSV. The query returns one row per host and deliberately returns no Enable rows until the required billing and prerequisite acknowledgements are `TRUE`.

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

All ten displayed columns are required. A blank subscription uses the command fallback. Boolean controls accept only `TRUE`, `FALSE`, or empty where optional. `Enable` requires a valid environment, `AcceptBackBilling=TRUE`, and `ConfirmExternalPrerequisites=TRUE`; a non-empty `LicenseType` must match the current host value and `AcceptLicenseTypeChange` must be empty or `FALSE`; nonproduction Developer requires `ConfirmNonProductionCoverage=TRUE`. `Disable` requires every enable-only field to be empty. Duplicate/contradictory hosts are rejected. Unknown columns resembling a billing/control field are rejected; unrelated unknown columns are warned and ignored. Any local error rejects the complete file before authentication.

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
| LicenseType mismatch or `AcceptLicenseTypeChange` rejected | This script never changes `LicenseType`. Clear the `LicenseType` value or set it to the current host value, and leave `AcceptLicenseTypeChange` empty or `FALSE`. Make any licensing change separately, only after a licensing decision. |
| Current LicenseType is `LicenseOnly` or undefined | Expected block, no change made. Follow [What to do when a host is LicenseOnly or undefined](#what-to-do-when-a-host-is-licenseonly-or-undefined); for an undefined value, use [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md) after a licensing decision. See [Why LicenseType is never changed](#why-licensetype-is-never-changed). |
| Developer rejected | Use `NonProduction` and confirm qualifying coverage, or stop and resolve entitlement. |
| Stale inventory warning | Refresh inventory; staleness alone does not block enablement, but evidence is uncertain. |
| Disable warns about degraded evidence | Expected behavior: cancellation proceeds from the verified extension settings so future charges can be stopped. |
| Verification timeout | Check extension health and whether another process changed ESU, license, or unrelated settings. |
| Patches are not installed | Enrollment is not patch deployment. Review automatic update configuration or Microsoft's manual download process. |

## References

- [SQL Server Extended Security Updates enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [Manage licensing and billing of SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing?view=sql-server-ver17)
- [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md) (fills an empty `LicenseType` only)
- [Microsoft sample: modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type)
- [Hybrid Compute REST API](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Azure custom roles](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)