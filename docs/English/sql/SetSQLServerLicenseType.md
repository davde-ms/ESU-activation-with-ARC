# SetSQLServerLicenseType.ps1

> [!WARNING]
> `LicenseType` is a **licensing attestation** (`Paid`) or an **Azure billing decision for the SQL Server software license** (`PAYG`). It applies to **every SQL Server instance on the host**, not only SQL Server 2014 or 2016. Only the license owner should choose the value. An incorrect `Paid` value is a licensing compliance issue; `PAYG` starts hourly Azure charges for the SQL Server software license. This script can't verify your entitlement.

## Purpose and scope

`SetSQLServerLicenseType.ps1` sets `LicenseType` on the existing `WindowsAgent.SqlServer` extension of an Arc-enabled Windows machine **only when the current value is empty** (shown as `Configuration needed` by Microsoft's Resource Graph query). It exists so that hosts left without a license type by onboarding can proceed to ESU enrollment after the license owner has made a decision.

It deliberately:

- **Never overwrites an existing value.** A host that already has the requested value is reported as `AlreadyCompliant`. A host with any other value fails preflight and isn't changed. To change an existing value, use the Azure portal or Microsoft's [modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type) sample after a licensing decision.
- **Never enables or cancels ESUs.** It doesn't change `enableExtendedSecurityUpdates`. Run [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) separately afterward.
- **Preserves every other public extension setting**, tags, and extension properties through a verified GET-merge-PUT. Protected settings are never copied.

It doesn't install the extension (see [InstallSQLServerArcExtension.ps1](InstallSQLServerArcExtension.md)), manage native Azure VMs or Linux, change Azure tags, or manage physical-core pooled licenses. It supports global Azure endpoints only.

`SetSQLServerESUSubscription.ps1` still never changes `LicenseType`. The reasons are in [Why LicenseType is never changed](SetSQLServerESUSubscription.md#why-licensetype-is-never-changed); this separate script keeps the licensing decision a distinct, explicitly acknowledged step.

<a id="when-licensetype-is-empty"></a>

## When LicenseType is empty

See [How LicenseType gets populated](README.md#how-licensetype-gets-populated) for the full explanation. In short, Microsoft documents that:

- Automatic onboarding reads the `ArcSQLServerExtensionDeployment` tag (`Paid`, `PAYG`, `PAYG-Recurring`, or `LicenseOnly`) on the subscription, resource group, or Arc server. The installation step "Set the license type" happens only if that tag is set.
- "If no tag is set and you have Software Assurance or SQL Server subscription with available licenses, Microsoft automatically sets the license type to **Paid** for newly onboarded instances."
- Otherwise the value stays empty: "The value `Configuration needed` indicates that the onboarding process didn't have enough information to configure the license type automatically."

An empty value blocks ESU enrollment because Microsoft requires `Paid` or `PAYG` for an Arc-enabled SQL Server ESU subscription.

## Choose the value: impact of each LicenseType

| Value | Use only when | Impact | Required acknowledgement |
| --- | --- | --- | --- |
| `Paid` | Every SQL Server instance on the host is covered by Standard or Enterprise **core-based** licenses with active Software Assurance, or by an active SQL Server subscription. | You attest: "By selecting a license with Software Assurance, you attest that you have Enterprise or Standard licenses with active Software Assurance or an active SQL Server subscription license, and that the device is in compliance with the Product Terms outsourcing restrictions." Eligible for ESUs. | `AttestSoftwareAssurance`. Also `ConfirmCoreBasedEnterpriseLicense` when an Enterprise instance is reported or no inventory is available. |
| `PAYG` | The license owner has approved paying for the SQL Server software license through Azure. | **Starts hourly Azure billing** for the SQL Server software license of the host, in addition to any ESU charges. Intermittent connectivity doesn't stop PAYG billing. Eligible for ESUs. | `AcceptPaygBilling`. Optional `ConsentToRecurringPAYG` for CSP-managed subscriptions. |
| `LicenseOnly` | Server+CAL, a perpetual license without Software Assurance, or free Developer, Evaluation, or Express editions. | **Not eligible** for an Arc-enabled ESU subscription. | None. |

Key Microsoft rules:

- **Server+CAL must be `LicenseOnly`.** "If your instance uses this license, you must set the license type to LicenseOnly, even if you have active Software Assurance for it." Microsoft also states that the installation of the Enterprise edition indicates the Server+CAL licensing model. The Azure inventory `edition` value doesn't distinguish Enterprise from Enterprise Core, so `Paid` on a host with an Enterprise instance requires `ConfirmCoreBasedEnterpriseLicense`.
- **No Software Assurance means no `Paid`.** "To subscribe to ESUs, you must have active Software Assurance or enable a pay-as-you-go billing for SQL Server software."
- **ESU requires `Paid` or `PAYG`.** A `LicenseOnly` host can't enroll in Arc-enabled ESUs.

### Recurring PAYG consent (CSP only)

`ConsentToRecurringPAYG` writes `ConsentToRecurringPAYG` with `Consented=true` and the current UTC `ConsentTimestamp`, the format Microsoft documents in [Recurring billing consent](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-pay-as-you-go-transition?view=sql-server-ver17#recurring-billing-consent). Use it only for CSP-managed subscriptions:

- Microsoft states that recurring pay-as-you-go billing "is enabled and required in the CSP-managed subscriptions. It's not available with other subscription offers."
- "Once registered, the consent property can't be changed without reinstalling the extension."
- After the consent time, a disconnection longer than 30 days activates recurring PAYG billing, including backfilled charges.

An existing consent is never rewritten. Without the switch, the script warns that CSP-managed subscriptions require it.

## Required order

1. Run [CheckSQLServerESUStatus.ps1](CheckSQLServerESUStatus.md) or [SetSQLServerLicenseType.kql](../../../samples/SetSQLServerLicenseType.kql) to find hosts with an empty `LicenseType`.
2. The license owner decides the value for each whole host by using the table above.
3. Run this script with `-DryRun` and review every warning.
4. Run it live. It sets the value and verifies that nothing else changed.
5. Confirm the value with the status script.
6. Only then run [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) with `-DryRun`, then live, to enable ESUs.

## Safeguards

- All parameter and CSV validation, including the acknowledgement rules, happens before authentication. Any invalid row rejects the whole file.
- Each acknowledgement belongs to one value: for example, `AcceptPaygBilling` is rejected with `Paid`, and `AttestSoftwareAssurance` is rejected with `PAYG`. `LicenseOnly` accepts none.
- Read-only preflight completes for every target before any PUT. Preflight checks registered providers, a connected Windows Arc machine in `full` configuration mode that isn't an Azure VM, the exact extension identity, `Succeeded` provisioning, readable settings, and SQL inventory.
- The script refuses `LicenseOnly` while ESU is enabled, because Microsoft states that you can't change the value to License only until the ESU subscription is canceled.
- The request is refused if any setting other than `LicenseType` (and the requested consent) would change. After the PUT, the script verifies the result.
- Immediately before each PUT, the script reads the extension again. If `LicenseType` was set to the requested value in the meantime, the host is reported as `AlreadyCompliant`; if anything else changed since preflight, the host fails and isn't changed. Existing settings are sent back with their JSON strings (including dates) unchanged.
- There is no `-Force`, and no parameter or CSV column overwrites an existing value.

## Least-privilege role

Use the same roles as the other SQL scripts. Assign [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) at subscription scope and [SQL Server Arc ESU Operator](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) on each target machine resource group.

## Authentication

Use exactly one path: `-userToken` with an unexpired `Get-AzAccessToken` object, or the complete `-tenantId`, `-appID`, `-clientSecret` service-principal set. Keep secrets outside CSV files and logs.

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `subscriptionId` | Single mode; optional CSV fallback | Subscription containing the Arc machine. |
| `serverResourceGroupName`, `ARCServerName` | Single mode | Existing target host. |
| `LicenseType` | Single mode | `Paid`, `PAYG`, or `LicenseOnly`. Written only when the current value is empty. |
| `AttestSoftwareAssurance` | Required for `Paid` | Software Assurance or SQL subscription attestation for the whole host. |
| `AcceptPaygBilling` | Required for `PAYG` | Accepts hourly Azure billing for the SQL Server software license. |
| `ConsentToRecurringPAYG` | Optional, `PAYG` only | Records recurring PAYG consent for CSP-managed subscriptions. Irreversible without reinstalling the extension. |
| `ConfirmCoreBasedEnterpriseLicense` | `Paid` only, when required | Confirms that every Enterprise instance on the host is core-based, not Server+CAL. |
| `csvFilePath` | CSV mode | Exact schema below. |
| `tenantId`, `appID`, `clientSecret`; `userToken` | Authentication dependent | Choose one authentication path. |
| `DryRun` | No | Full read-only preflight and warnings; no PUT. `Preview` alias. |
| `WhatIf`, `Confirm` | No | Standard high-impact `ShouldProcess` controls. |

## Examples

Preview `Paid` with a user token:

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/SetSQLServerLicenseType.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-01' `
    -LicenseType Paid `
    -AttestSoftwareAssurance `
    -userToken $authenticationToken `
    -DryRun
```

Preview `PAYG` with a service principal:

```powershell
./Scripts/sql/SetSQLServerLicenseType.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-02' `
    -LicenseType PAYG `
    -AcceptPaygBilling `
    -tenantId '00000000-0000-0000-0000-000000000002' `
    -appID '00000000-0000-0000-0000-000000000003' `
    -clientSecret $clientSecret `
    -DryRun
```

## CSV input

Start with [SetSQLServerLicenseType.csv](../../../samples/SetSQLServerLicenseType.csv). To build the file from Azure inventory, set the values at the top of [SetSQLServerLicenseType.kql](../../../samples/SetSQLServerLicenseType.kql), run it in Azure Resource Graph Explorer, and download the result as CSV. The query returns only hosts with an empty `LicenseType`, and no rows until the selected value and its matching acknowledgement are set.

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,AttestSoftwareAssurance,AcceptPaygBilling,ConsentToRecurringPAYG,ConfirmCoreBasedEnterpriseLicense
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-01,Paid,TRUE,FALSE,FALSE,FALSE
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-02,LicenseOnly,FALSE,FALSE,FALSE,FALSE
```

```powershell
./Scripts/sql/SetSQLServerLicenseType.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\SetSQLServerLicenseType.csv' `
    -userToken $authenticationToken `
    -DryRun
```

All eight columns are required. A blank subscription uses the command fallback. Acknowledgement columns accept only `TRUE`, `FALSE`, or empty. Duplicate hosts are rejected. Unknown columns that resemble a license or billing field are rejected; other unknown columns are warned about and ignored.

## Preview and execution safety

`-DryRun` completes preflight, prints every warning (host-wide scope, attestation, billing, consent, or eligibility) with instances, host type, and detected cores, and sends no PUT. `-WhatIf` previews through `ShouldProcess`; `-Confirm` prompts for each host. A preflight failure on any target makes the other rows `NotStarted`. Live operations retry transient responses, accept trusted asynchronous polling URLs only, and verify the final settings.

## Output and exit semantics

Each result contains `RowNumber`, `SubscriptionId`, `ResourceGroupName`, `MachineName`, `MachineResourceId`, `PreviousLicenseType`, `RequestedLicenseType`, `EffectiveLicenseType`, `ConsentToRecurringPAYGRecorded`, `EsuEnabled`, `HostType`, `DetectedCores`, `InstanceNames`, `Editions`, `OperationStatus`, `VerificationSucceeded`, and `Message`.

`OperationStatus` is `Succeeded`, `AlreadyCompliant`, `Previewed`, `Declined`, `Failed`, or `NotStarted`. Exit `0` means every row succeeded, was already compliant, or was previewed. Exit `1` means validation or authentication failed, or any row failed, was declined, or wasn't started.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Acknowledgement error | Supply only the acknowledgement that matches the selected value, and only after the license owner's decision. |
| "never overwrites an existing value" | The host already has a `LicenseType`. Change it only through the Azure portal or Microsoft's sample after a licensing decision. |
| Enterprise or missing inventory blocks `Paid` | Confirm that every Enterprise instance is core-based, then add `ConfirmCoreBasedEnterpriseLicense`. Otherwise the host is Server+CAL and must be `LicenseOnly`. |
| `LicenseOnly` refused while ESU is enabled | Cancel the ESU subscription first with [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) `-Action Disable`. |
| CSP subscription warning with `PAYG` | Stop, and rerun with `ConsentToRecurringPAYG` only if the subscription is CSP-managed. |

## References

- [Manage automatic connection: Specify license type](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy?view=sql-server-ver17#specify-license-type)
- [Manage automatic connection: Verify and correct the license type configuration](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy?view=sql-server-ver17#verify-and-correct-the-license-type-configuration)
- [Manage licensing and billing of SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing?view=sql-server-ver17)
- [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [Manage pay-as-you-go transition: Recurring billing consent](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-pay-as-you-go-transition?view=sql-server-ver17#recurring-billing-consent)
- [SQL Server enabled by Azure Arc FAQ](https://learn.microsoft.com/sql/sql-server/azure-arc/faq?view=sql-server-ver17)
- [SQL Server Extended Security Updates enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Microsoft sample: modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type)
