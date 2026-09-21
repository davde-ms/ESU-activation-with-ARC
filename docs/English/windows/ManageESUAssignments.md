# ManageESUAssignments.ps1

This script assigns or unassigns existing ESU licenses in bulk from a CSV file. It supports one license assigned to multiple Azure Arc-enabled servers and licenses stored in a different subscription from the servers.

## Windows Server 2016 compatibility

Bulk assignment and unlink operations are target-neutral and support existing Windows Server 2012, Windows Server 2012 R2, and Windows Server 2016 ESU license resource IDs. The script has no target parameter, its CSV has no target column, and it does not inspect or validate each server's local operating system. Select an eligible license for each server generation; Azure can reject an incompatible pairing. Review Microsoft's current [Windows Server ESU preparation and eligibility guidance](https://learn.microsoft.com/azure/azure-arc/servers/prepare-extended-security-updates) before assignment.

## Authentication

Use either service principal credentials or a user-provided Microsoft Entra token.

### Service principal

```powershell
./Scripts/windows/ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"
```

### User token

```powershell
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./Scripts/windows/ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv" -userToken $authToken
```

If both authentication methods are provided, `-userToken` is used.

## Parameters

| Parameter | Description |
| --- | --- |
| arcServerSubscriptionId | Subscription containing the Azure Arc-enabled servers. `-subscriptionId` remains available as a backward-compatible alias. |
| licenseSubscriptionId | Optional subscription containing the ESU licenses. Used when a CSV row does not provide `LicenseSubscriptionId`. |
| tenantId | Microsoft Entra tenant ID used for service principal authentication. |
| appID | Application ID used for service principal authentication. |
| clientSecret | Client secret used for service principal authentication. |
| location | Azure region used by the assignment request. |
| csvFilePath | Path to the CSV assignment file. |
| logFileName | Optional transcript log path. |
| userToken | Token object returned by `Get-AzAccessToken`. |
| DryRun | Validates inputs and resource access without sending a mutation request. `-Preview` is an alias. |

## Cross-subscription assignments

Use `-licenseSubscriptionId` when all licenses are in another subscription:

```powershell
./Scripts/windows/ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseSubscriptionId "00000000-0000-0000-0000-000000000004" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"
```

The license subscription is selected in this order:

1. The CSV row's `LicenseSubscriptionId` value.
2. The `-licenseSubscriptionId` parameter.
3. The Azure Arc server subscription supplied through `-arcServerSubscriptionId`.

The identity must have the required access to both subscriptions when they differ.

## CSV format

The CSV file must be created manually.

Start with the copy-ready [ManageESUAssignments CSV template](../../../samples/ManageESUAssignments.csv). All included names and subscription IDs are fictitious and must be replaced.

| Column | Required | Description |
| --- | --- | --- |
| Name or ARCServerName | Yes | Name of the Azure Arc-enabled server. |
| ServerResourceGroupName | Yes | Resource group containing the server. |
| LicenseName | Yes | Name of the existing ESU license. |
| LicenseResourceGroupName | Yes | Resource group containing the ESU license. |
| AssignESULicense | Yes | `True` assigns the license; `False` unassigns it. |
| LicenseSubscriptionId | No | Subscription containing this row's license. Overrides the command-line value. |

![CSV File Layout](../../../media/ManageESUAssignments_CSV_example.jpg)

## Dry-run mode

Add `-DryRun` to validate the CSV data, authentication, and resource access before applying assignments:

```powershell
./Scripts/windows/ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv" -DryRun
```

Dry-run mode can send read-only `GET` requests to validate access and resource existence. It does not send `PUT`, `PATCH`, or `DELETE` requests.

## WhatIf and confirmation

Use `-WhatIf` for PowerShell-native previews. It performs the same read-only resource validation as `-DryRun`, displays each proposed assignment or unlink, and sends no mutation request. Use `-Confirm` to approve each operation during a live run.

```powershell
./Scripts/windows/ManageESUAssignments.ps1 <parameters> -WhatIf
./Scripts/windows/ManageESUAssignments.ps1 <parameters> -Confirm
```

## Troubleshooting

| Message or symptom | What to check |
| --- | --- |
| CSV validation fails | Start from the sample file and check the required headers, server names, resource groups, license names, and `True`/`False` action values. |
| Authentication token is missing or expired | Supply all three service principal parameters, or obtain a new `Get-AzAccessToken` token object. |
| Resource access validation fails | Verify the identity can read the Arc license profile and, for assignment, the ESU license in the resolved subscription. |
| `401` or `403` response | Check permissions in both the server and license subscriptions. |
![Manage ESU assignments CSV example](../../../media/ManageESUAssignments_CSV_example.jpg)
| Summary reports failures | Correct every failed row, then rerun the complete CSV with `-DryRun` or `-WhatIf` before a live run. |
