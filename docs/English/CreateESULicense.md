# CreateESULicense.ps1

This script will create an ESU license.

Here are the command lines you should use to run it:

## Service Principal Authentication

    ./CreateESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8

## User Token Authentication

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./CreateESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8 -userToken $authToken

## Parameters

Where:

| Parameter                | Description                                                                                | Required |
| ------------------------ | ------------------------------------------------------------------------------------------ | -------- |
| subscriptionId           | The subscription ID of the Azure subscription you want to use.                             | Yes      |
| tenantId                 | The tenant ID of the Microsoft Entra ID tenant you want to use.                            | No\*     |
| appID                    | The application ID of the service principal you created in the prerequisites section.      | No\*     |
| clientSecret             | The secret key of the service principal you created in the prerequisites section.          | No\*     |
| licenseResourceGroupName | The name of the resource group that will contain the ESU license.                          | Yes      |
| licenseName              | The name of the ESU license you want to create.                                            | Yes      |
| location                 | The Azure region where you want to deploy the ESU license.                                 | Yes      |
| state                    | The activation state of the ESU license. It can be "Activated" or "Deactivated".           | Yes      |
| edition                  | The edition of the ESU license. It can be "Standard" or "Datacenter".                      | Yes      |
| coreType                 | The core type of the ESU license. It can be "vCore" or "pCore".                            | Yes      |
| coreCount                | The number of cores of the ESU license.                                                    | Yes      |
| userToken                | A valid Microsoft Entra ID authentication token object (alternative to service principal). | No\*     |

**Authentication Requirements:**

- \* You must provide either service principal credentials (tenantId, appID, clientSecret) OR a valid userToken

You can type the exact number of cores your host or VM has and the script will automatically calculate the number of cores required for the ESU license.

> **Note:** The userToken parameter offers a way for you to work without having to rely on a Service Principal for authentication. You can either provide a token OR provide the tenantID, appID and clientSecret parameters. If you provide both, **the token will be used**.

**Note:** The script can also be rerun with the same base parameters to change some of the properties of the license. Those properties are:

- **state** (allows you to create a deactivated license and activate it later)
- **coreCount** (allows you to change the number of cores of the license if you have need to increase or decrease it)

> **All other parameters are immutable and cannot be changed once the license is created.**

## Preview and confirmation

Add `-WhatIf` to preview the license target and normalized operation without sending the Azure REST update. Run without `-WhatIf` after reviewing the action. Add `-Confirm` when you want PowerShell to ask before creation or modification.

```powershell
./CreateESULicense.ps1 <parameters> -WhatIf
./CreateESULicense.ps1 <parameters> -Confirm
```

## Troubleshooting

| Message or symptom | What to check |
| --- | --- |
| Authentication token is missing or expired | Supply all three service principal parameters, or obtain a new `Get-AzAccessToken` token object. |
| `401` or `403` response | Verify the identity can create or update ESU licenses in the target resource group. |
| `404` response | Check the subscription and license resource group names. |
| Conflict or immutable-property response | Keep the existing license's edition, core type, and location; only supported properties can be updated. |
| Core-count validation fails | Use a positive whole number within the ranges accepted by this script and a supported edition/core-type combination. |
| Script exits with code `1` | Read the final failure message, correct the input or permission, and rerun with `-WhatIf`. |
