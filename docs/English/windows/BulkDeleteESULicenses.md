# BulkDeleteESULicenses.ps1

This script decommissions Windows Server ESU license resources (`Microsoft.HybridCompute/licenses`) in bulk. For each selected license, it unlinks every Azure Arc-enabled server it finds assigned to the license, confirms that each unlink took effect, and then deletes the license. A license is deleted only when every discovered server was unlinked successfully.

Use it after an ESU period ends. For example, the Windows Server 2012 and Windows Server 2012 R2 ESU period ended on October 13, 2026, and Azure Arc deactivated those licenses at midnight UTC on October 14, 2026. Deactivated licenses remain available to query until you delete them. See [Programmatically deploy and manage Azure Arc Extended Security Updates licenses](https://learn.microsoft.com/azure/azure-arc/servers/api-extended-security-updates).

> **Deleting or deactivating a license can remain billable for up to five calendar days. If you delete and then recreate an ESU license, back-billing still applies for the corresponding period; deletion does not exempt you from those charges. Confirm the current impact in the [official ESU billing guidance](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates#billing-associated-with-modifications-to-an-azure-arc-esu-license) before proceeding.**

## How it works

1. **Select licenses.** Choose CSV mode or discovery mode (see below). Only licenses whose `target` is listed in `-target` are processed. By default, that's `Windows Server 2012` and `Windows Server 2012 R2`. Windows Server 2016 licenses are left unchanged unless `-target` explicitly includes `Windows Server 2016`.
2. **Discover assigned servers.** An Azure Resource Graph query finds the `microsoft.hybridcompute/machines/licenseprofiles` resources whose `properties.esuProfile.assignedLicense` points to a selected license. The query searches **only the subscription that contains the license**.
3. **Export an inventory.** Before any change, the script writes a CSV that lists every selected license with its properties and assigned servers. Keep this file for audit or to recreate a license.
4. **Unlink each server.** The script reads the server's license profile, then sends the [documented unlink request](https://learn.microsoft.com/azure/azure-arc/servers/api-extended-security-updates#unlink-a-license): a `PUT` on `licenseProfiles/default` with the location and an empty `esuProfile`. Existing license profile tags are preserved.
5. **Verify.** The script reads the license profile again until the license is no longer assigned.
6. **Delete.** The license is deleted only if every discovered server was unlinked and verified. Otherwise, the error is logged, the license is kept, and the script continues with the next license.

### Servers that are skipped

A license profile can also hold Software Assurance (`softwareAssurance`) and product profile (`productProfile`, such as Windows Server pay-as-you-go or Hotpatch) settings. The documented unlink request doesn't include those settings, and Microsoft doesn't document whether omitting them preserves or resets them. To avoid an unintended licensing or billing change, the script **skips any server whose license profile contains these settings**. The license assigned to that server is kept, and the license is reported as failed. Unlink those servers manually after reviewing their settings, then run the script again.

A server that is already unlinked, or now assigned to a different license, is left unchanged and doesn't block deletion.

### Limits of assignment discovery

- Discovery searches only the subscription that contains each license. If a server in another subscription uses the license, it isn't detected, its assignment is left in place, and the license is still deleted. The script logs a warning about this on every run.
- Azure Resource Graph returns only resources the identity can read, and its data can lag recent changes by a short time. Review the inventory, and use [CheckESUStatus.ps1](CheckESUStatus.md) for servers you're unsure about.
- The license's `assignedLicenses` value is recorded in the inventory for information only. Microsoft describes it as "the number of assigned licenses," not as a server count, so the script doesn't use it to decide anything.

## Authentication

Use either service principal credentials or a user-provided Microsoft Entra token. If both are provided, `-userToken` is used.

### Service principal

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -DryRun
```

### User token

```powershell
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -userToken $authToken -DryRun
```

## Selecting licenses

### Discovery mode

Provide `-licenseSubscriptionId` without `-csvFilePath`. Every ESU license in the subscription, or only in `-licenseResourceGroupName` when you provide it, is evaluated against `-target`.

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -userToken $authToken
```

### CSV mode

Provide `-csvFilePath`. Start with the [BulkDeleteESULicenses CSV template](../../../samples/BulkDeleteESULicenses.csv). All included names and subscription IDs are fictitious and must be replaced.

| Column | Required | Description |
| --- | --- | --- |
| LicenseName | Yes | Name of the ESU license resource. |
| LicenseResourceGroupName | Yes | Resource group that contains the license. |
| LicenseSubscriptionId | No | Subscription that contains this row's license. Overrides `-licenseSubscriptionId`. |

A row without `LicenseSubscriptionId` uses `-licenseSubscriptionId`; if neither is provided, the row fails validation. Duplicate rows are ignored. A listed license whose target isn't selected by `-target` is reported as excluded and left unchanged.

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "00000000-0000-0000-0000-000000000001" -csvFilePath "C:\Temp\ESULicensesToDelete.csv" -userToken $authToken
```

## Parameters

| Parameter | Description | Required |
| --- | --- | --- |
| licenseSubscriptionId | Subscription that contains the licenses. Required in discovery mode; in CSV mode, the default for rows without `LicenseSubscriptionId`. Aliases: `licenseSub`, `subscriptionId`. | Discovery: Yes / CSV: No |
| licenseResourceGroupName | Discovery mode only. Limits discovery to one resource group. Alias: `lrg`. | No |
| csvFilePath | CSV mode. Path to the CSV file listing the licenses. Alias: `csv`. | CSV: Yes |
| target | License targets that may be deleted: `Windows Server 2012`, `Windows Server 2012 R2`, `Windows Server 2016`. Default: `Windows Server 2012`, `Windows Server 2012 R2`. | No |
| location | Fallback region for the unlink request, used only when a license profile doesn't return its location. Alias: `l`. | No |
| tenantId | Microsoft Entra tenant ID used for service principal authentication. | No\* |
| appID | Application ID used for service principal authentication. | No\* |
| clientSecret | Client secret used for service principal authentication. Aliases: `s`, `secret`, `sec`. | No\* |
| userToken | Token object returned by `Get-AzAccessToken`. Alias: `token`. | No\* |
| inventoryFilePath | Path of the before-change inventory CSV. Default: `ESULicenseDeletionInventory-<timestamp>.csv` in the current directory. Alias: `inventory`. | No |
| logFileName | Optional transcript log path. Alias: `log`. | No |
| DryRun | Validates everything without sending a `PUT` or `DELETE` request. Alias: `Preview`. | No |

\* Provide either `tenantId`, `appID`, and `clientSecret`, or `userToken`.

## Preview, confirmation, and automation

Always preview first. Both preview modes send only read requests (`GET` requests and the Resource Graph query `POST`), read every license profile to report which servers would be unlinked or skipped, and write the inventory file.

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 <parameters> -DryRun
./Scripts/windows/BulkDeleteESULicenses.ps1 <parameters> -WhatIf
```

A live run asks for confirmation **for each license**, for example *Unlink 3 Arc server(s), then delete ESU license*. Answer `Y` (yes), `A` (yes to all), `N` (no), or `L` (no to all). A declined license and its assignments are left unchanged. For a reviewed, unattended run, add `-Confirm:$false`.

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 <parameters> -Confirm:$false
```

## Before-change inventory

The inventory has one row per license and assigned server, and one row for each license with no discovered assignment. Columns include the license name, resource group, subscription ID, resource ID, location, target, state, edition, core type, processors, `assignedLicenses`, immutable ID, the full `licenseDetails` and tags as JSON, and each server's name, resource group, subscription ID, location, and license profile ID. The file contains subscription and resource IDs, so store it according to your organization's data-handling rules.

The inventory is written in every mode, including `-DryRun` and `-WhatIf`. If it can't be written, the script stops before changing anything.

## Required permissions

The identity needs these actions on the license scope and on the scope of each assigned Arc server:

- `Microsoft.HybridCompute/licenses/read`
- `Microsoft.HybridCompute/licenses/delete`
- `Microsoft.HybridCompute/machines/licenseProfiles/read`
- `Microsoft.HybridCompute/machines/licenseProfiles/write`
- `Microsoft.ResourceGraph/resources/read`, to submit the Azure Resource Graph query. Resource Graph returns only resources the identity can read.

The [ARC ESU License Administrator](../../../Custom%20Roles/ARC%20ESU%20License%20Administrator.json) custom role includes these actions.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every processed license succeeded, or nothing needed to be processed. Excluded and declined licenses aren't failures. |
| `1` | Fatal error: authentication, CSV file, license discovery, or inventory export. No license was changed. |
| `2` | Partial failure: at least one license couldn't be found, unlinked, verified, or deleted. Successful licenses were still processed. |

## Troubleshooting

| Message or symptom | What to check |
| --- | --- |
| Authentication token is missing or expired | Supply all three service principal parameters, or obtain a new `Get-AzAccessToken` token object. |
| `The license profile also contains softwareAssurance...` or `productProfile...` | The server was skipped on purpose. Review its Software Assurance and product profile settings, unlink the license manually, then run the script again. |
| `Target '...' is not selected by -target` | The license was excluded. Add its target to `-target` only if you intend to delete it. |
| `The license was not found` | Check the CSV row's name, resource group, and subscription. |
| `Assigned servers could not be discovered` | Check that the identity can submit Resource Graph queries and read license profiles in the license subscription. |
| `still assigned after ... verification attempt(s)` | Azure accepted the unlink but didn't apply it in time. Check the server with [CheckESUStatus.ps1](CheckESUStatus.md), then run the script again. |
| `401` or `403` response | Check the permissions above on both the license and server scopes. IDs in Azure error messages are shown as `<redacted-id>`; the resource group and resource names remain visible. |
| Script exits with code `2` | Review the summary table, correct each failed license, then preview again with `-DryRun` or `-WhatIf`. |
