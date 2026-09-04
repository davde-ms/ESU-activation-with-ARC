# CheckSQLServerESUStatus.ps1

## Purpose and scope

`CheckSQLServerESUStatus.ps1` reports host configuration, SQL Server 2014/2016 inventory, eligibility evidence, metering evidence, and SQL Server ESU status for one or more Windows machines enabled by Azure Arc. It uses only Azure Resource Manager GET requests and never registers, creates, updates, or deletes resources.

It supports already Arc-connected Windows machines in Commercial Azure only. Connected Machine agent installation, upgrade, or repair; native Azure VMs; Linux; other clouds; physical-core pooled licenses and unlimited virtualization; and automatic patch deployment are out of scope. Status reporting does not enroll a host or install an update.

## Prerequisites and boundaries

- PowerShell 7.x on Windows and an existing Arc machine resource.
- Read access to machine, extension, provider registration, and subscription-wide Arc SQL instance inventory.
- Registered providers and current inventory improve classification, but the script reports warnings/errors rather than changing Azure.

The ESU setting is host-level: all eligible instances and associated services on the operating system environment are affected. Same-version instances share one host/version meter; SQL Server 2014 and 2016 on the same host can each produce a meter. Output is evidence, not an entitlement decision. `AutomaticPatchStatus` is reported separately; enrollment does not mean this script deployed patches.

## Least-privilege role

Create [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) in each target subscription, then assign it to the identity at subscription scope. Subscription scope is required because provider state and Arc SQL inventory are subscription-level resources. Its actions are limited to machine, extension, Arc SQL instance, and provider-state reads.

## Authentication

Use exactly one path: an unexpired `Get-AzAccessToken` object through `-userToken`, or all of `-tenantId`, `-appID`, and `-clientSecret`. Supplying both paths is rejected. Credentials are never CSV fields.

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `subscriptionId` | Single mode; optional fallback in CSV mode | Subscription containing the machine and used for subscription-wide inventory. |
| `serverResourceGroupName`, `ARCServerName` | Single mode | Existing Arc machine target. |
| `csvFilePath` | CSV mode | Existing CSV with the exact three columns below. |
| `tenantId`, `appID`, `clientSecret` | Authentication dependent | Complete service-principal path. |
| `userToken` | Authentication dependent | User token object. |
| `exportCsvPath` | No | Writes flattened results to CSV. |

## Single-machine example

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/CheckSQLServerESUStatus.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-01' `
    -userToken $authenticationToken
```

## CSV input

Start with [CheckSQLServerESUStatus.csv](../../../samples/CheckSQLServerESUStatus.csv).

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-01
```

```powershell
./Scripts/sql/CheckSQLServerESUStatus.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\CheckSQLServerESUStatus.csv' `
    -userToken $authenticationToken `
    -exportCsvPath '.\sql-esu-status.csv'
```

The exact required columns are `SubscriptionId`, `ServerResourceGroupName`, and `ARCServerName`. A blank row subscription uses the command fallback. The script validates all rows before authentication and rejects missing/non-CSV files, empty files, missing columns, invalid GUIDs or names, and duplicate targets. Unrelated columns are warned and ignored.

## Read-only behavior

There is no `-DryRun` or `-WhatIf` because all Azure calls are GET-only. The script validates trusted ARM pagination, caps it at 100 pages, retries transient reads, caches provider/inventory reads per subscription, and correlates instances to machines by normalized `containerResourceId`.

## Output and exit semantics

Output fields are: `SubscriptionId`, `ResourceGroupName`, `MachineName`, `MachineResourceId`, `Evaluated`, `MachineExists`, `ConnectionStatus`, `AgentMode`, `OperatingSystem`, `NativeAzureExcluded`, `Location`, `HybridComputeRegistered`, `AzureArcDataRegistered`, `ExtensionInstalled`, `ExtensionPublisher`, `ExtensionType`, `ExtensionProvisioningState`, `ExtensionVersion`, `ExtensionVersionSupport`, `AutomaticUpgradeEnabled`, `LicenseType`, `SqlManagementEnabled`, `ESUEnabled`, `ESURawValue`, `ESULastUpdatedTimestamp`, `Instances`, `EligibleInstances`, `IneligibleInstances`, `UncertainInstances`, `EligibleVersions`, `Editions`, `Environments`, `MixedEligibleVersions`, `HostType`, `HostTypes`, `HostTypeEvidenceStatus`, `DetectedCores`, `DetectedCoreValues`, `DetectedCoresEvidenceStatus`, `MeteringEvidenceStatus`, `InventoryFreshness`, `UsageFreshness`, `AutomaticPatchStatus`, `PassiveDRState`, `Classification`, `Reasons`, and `Warnings`.

`Classification` is `Healthy`, `Warning`, `NotEnabled`, `Unknown`, or `Error`. `Healthy` still means the observed data met script checks, not that licensing entitlement or patch installation was independently proven. Exit `0` means every target was evaluated, including warning/not-enabled classifications. Exit `1` means input/authentication/export failed or any target has `Evaluated=False`. Other valid targets continue after a target failure.

## Billing and safety

The script is non-mutating. Review `HostTypes`, core evidence, version, edition, environment, passive/DR evidence, and freshness before making billing decisions. Current Microsoft rules can apply a four-core host minimum, separate meters for SQL Server 2014 and 2016, and current-year bill-back. Missing/conflicting evidence is deliberately classified as uncertain. Physical-core pooled licenses are outside this script.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `NotEnabled` | Verify the extension exists and `enableExtendedSecurityUpdates` is a recognizable true value. |
| `Warning` | Review provider, connection, extension version/upgrade, license, freshness, and metering warnings. |
| `Unknown` | Check eligible inventory and whether ESU or inventory values are missing/unrecognized. |
| `Error` | Check OS/native-Azure exclusion, extension identity/state, and request failures. |
| Metering evidence uncertain | Compare all `HostTypes` and `DetectedCoreValues`; do not use a single inferred value for billing. |
| ESU enabled but patches absent | Enrollment and patch deployment are separate. Review automatic update status or the documented manual download path. |

## References

- [SQL Server Extended Security Updates enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [Hybrid Compute REST API](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Azure custom roles](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)
