# TestSQLServerArcESUPrerequisites.ps1

## Purpose and scope

`TestSQLServerArcESUPrerequisites.ps1` performs a read-only Azure Resource Manager assessment before Azure Extension for SQL Server installation or SQL Server ESU enrollment. It checks the Arc machine, provider registration, `WindowsAgent.SqlServer`, correlated Arc SQL inventory, SQL Server 2014/2016 eligibility evidence, and inventory freshness. It never registers a provider or creates, updates, or deletes a resource.

This workflow is for Windows machines already connected to Commercial Azure Arc. Connected Machine agent installation, upgrade, and repair are out of scope. Native Azure VMs, Linux, Azure Government and other clouds, SQL versions other than 2014/2016, physical-core pooled ESU licenses, unlimited virtualization, and automatic patch deployment are out of scope.

## Prerequisites and boundaries

- PowerShell 7.x on Windows and network access to Commercial Azure endpoints.
- An existing Arc machine that reports `Connected`, agent mode `Full`, Windows, a location supported for `Microsoft.AzureArcData/sqlServerInstances`, and a non-Azure cloud provider.
- Registered `Microsoft.HybridCompute` and `Microsoft.AzureArcData` providers. The script reports missing registration but does not register providers.
- For ESU enablement readiness: a healthy supported `WindowsAgent.SqlServer` extension, `SqlManagement.IsEnabled=true`, `LicenseType` `Paid` or `PAYG`, and at least one SQL Server 2014/2016 Standard or Enterprise instance.
- Independently confirm outbound connectivity, local Windows and SQL permissions, entitlement and prior-year coverage, Developer nonproduction eligibility, and HA/DR compliance. ARM inventory cannot prove these items.

The ESU setting is host-level and affects eligible SQL instances and associated services on the operating system environment. Multiple eligible versions on one host can produce separate meters. Assessment does not enroll the host and does not deploy patches.

## Least-privilege role

Create [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) in each target subscription, then assign it to the identity at subscription scope. Subscription scope is required because provider state and Arc SQL inventory are subscription-level resources. The role grants only machine, extension, Arc SQL instance, and provider-state reads. Replace the fictitious subscription in the role template before creating it.

## Authentication

Use one authentication path:

- User token: pass an unexpired object returned by `Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'` to `-userToken` (`-token` alias). The object must contain `Token` and a future `ExpiresOn` value.
- Service principal: pass `-tenantId`, `-appID`, and `-clientSecret` together.

When `-userToken` is supplied, this script uses it. Never put tokens or secrets in CSV files, output, or source control.

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `subscriptionId` | Yes | Default subscription and the subscription used for a single target. Must be a GUID. |
| `serverResourceGroupName` | Single mode | Resource group name, 1-90 supported characters, not ending in a period. |
| `ARCServerName` | Single mode | Arc machine name, 1-54 supported characters, not ending in a period. |
| `csvFilePath` | CSV mode | Existing `.csv` file. Mutually exclusive with the single-machine parameters. |
| `tenantId`, `appID`, `clientSecret` | Authentication dependent | Complete service-principal credential set. IDs must be GUIDs. |
| `userToken` | Authentication dependent | `Get-AzAccessToken` token object. |
| `exportCsvPath` | No | Writes flattened assessment results to CSV. |

## Single-machine example

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/TestSQLServerArcESUPrerequisites.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-01' `
    -userToken $authenticationToken
```

For service-principal authentication, replace `-userToken` with fictitious or securely supplied `-tenantId`, `-appID`, and `-clientSecret` values.

## CSV input

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-01
```

```powershell
./Scripts/sql/TestSQLServerArcESUPrerequisites.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\CheckSQLServerESUStatus.csv' `
    -userToken $authenticationToken `
    -exportCsvPath '.\prerequisite-results.csv'
```

The exact required columns are `SubscriptionId`, `ServerResourceGroupName`, and `ARCServerName`. A blank row subscription falls back to the command subscription. Every row is validated before authentication; invalid GUIDs, invalid names, missing columns, no data rows, and case-insensitive duplicate machine targets reject the whole file. Use the same three-column shape as the [status sample](../../../samples/CheckSQLServerESUStatus.csv).

## Read-only behavior

The script supports neither `-DryRun` nor `-WhatIf` because its Azure operations are already GET-only. It validates the complete input before authentication, follows only trusted `https://management.azure.com` pagination links, and correlates SQL instances by `containerResourceId`.

## Output and exit semantics

Each result contains: `SubscriptionId`, `ResourceGroupName`, `MachineName`, `MachineResourceId`, `MachineExists`, `ConnectionStatus`, `AgentMode`, `OperatingSystem`, `Location`, `HybridComputeRegistered`, `AzureArcDataRegistered`, `RegionSupported`, `ExtensionState`, `ExtensionVersion`, `ExtensionSupported`, `AutomaticUpgradeEnabled`, `LicenseType`, `SqlManagementEnabled`, `ESUEnabled`, `ESULastUpdatedTimestamp`, `EligibleInstances`, `IneligibleInstances`, `MixedEligibleVersions`, `HostType`, `DetectedCores`, `InventoryFreshness`, `UsageFreshness`, `BlockingIssues`, `Warnings`, `ExternalChecks`, `ReadyForExtensionInstall`, and `ReadyForESUEnablement`.

`ReadyForExtensionInstall` is true only when the base machine checks pass and the extension is absent. `ReadyForESUEnablement` is stricter and requires the supported extension and eligible inventory. Stale or missing timestamps are warnings and do not alone block readiness.

Exit code `0` means input/authentication completed and no target was missing or failed assessment. Exit code `1` means input, authentication, export, a missing machine, or an assessment request failed. Eligibility blockers can still be returned with exit `0`; inspect the readiness fields and issues.

## Billing and safety

This assessment creates no subscription and no charge. Results are evidence, not proof of licensing entitlement. SQL Server ESU enrollment is billed per host/OSE and version under current Microsoft terms, with a four-core minimum and possible current-year bill-back. Verify detected host type, cores, edition, version, passive status, and prior coverage before enabling. Physical-core pooled licenses and unlimited virtualization are not managed here.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `ReadyForExtensionInstall=False` | Review provider registration, connection, Full mode, Windows, native-Azure exclusion, location, and whether the extension already exists. |
| `ReadyForESUEnablement=False` | Review `BlockingIssues`, extension identity/version/state, SQL management, license type, and eligible SQL inventory. |
| Freshness is `Stale` or `Unknown` | Refresh SQL inventory and investigate extension connectivity; freshness is warning-only but makes evidence uncertain. |
| Developer edition is uncertain | Confirm qualifying nonproduction coverage outside ARM before enrollment. |
| Exit code `1` | Check input/authentication first, then missing-machine or `Assessment failed` details and export-path access. |

## References

- [SQL Server Extended Security Updates enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [Hybrid Compute REST API](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Azure custom roles](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)
