# AssignESULicense.ps1

This script will assign a single ESU license to a specific Azure ARC server.

Here are the command lines you should use to run it:

## Service Principal Authentication

    ./AssignESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arservers" -ARCServerName "Win2012" -location "EastUS"

## User Token Authentication

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./AssignESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arservers" -ARCServerName "Win2012" -location "EastUS" -userToken $authToken

## Parameters

Where:

| Parameter                | Description                                                                                              | Required |
| ------------------------ | -------------------------------------------------------------------------------------------------------- | -------- |
| subscriptionId           | The subscription ID of the Azure subscription you want to use.                                           | Yes      |
| tenantId                 | The tenant ID of the Microsoft Entra ID tenant you want to use.                                          | No\*     |
| appID                    | The application ID of the service principal you created in the prerequisites section.                    | No\*     |
| clientSecret             | The secret key of the service principal you created in the prerequisites section.                        | No\*     |
| licenseResourceGroupName | The name of the resource group that contains the ESU license you want to assign to the Azure ARC server. | Yes      |
| licenseName              | The name of the ESU license you want to assign to the Azure ARC server.                                  | Yes      |
| serverResourceGroupName  | The name of the resource group that contains the Azure ARC server you want to assign the ESU license to. | Yes      |
| ARCServerName            | The name of the Azure ARC server you want to assign the ESU license to.                                  | Yes      |
| location                 | The Azure region where you ARC objects are deployed.                                                     | Yes      |
| userToken                | A valid Microsoft Entra ID authentication token object (alternative to service principal).               | No\*     |
| unassign                 | Unlinks the license instead of assigning it. `-u` is an alias.                                           | No       |

**Authentication Requirements:**

- \* You must provide either service principal credentials (tenantId, appID, clientSecret) OR a valid userToken

> **Note:** The userToken parameter offers a way for you to work without having to rely on a Service Principal for authentication. You can either provide a token OR provide the tenantID, appID and clientSecret parameters. If you provide both, **the token will be used**.

> You can use the `-u` at the end of the command line to UNLINK an existing license from an Azure ARC server. If you do not specify the `-u` parameter, the script will link the license to the Azure ARC server (default behavior).

## Preview and confirmation

Add `-WhatIf` to preview the assignment or unlink operation without sending the Azure REST update. After checking the displayed target and action, run without `-WhatIf`. Add `-Confirm` when you want PowerShell to ask before the update.

```powershell
./AssignESULicense.ps1 <parameters> -WhatIf
./AssignESULicense.ps1 <parameters> -Confirm
```

## Troubleshooting

| Message or symptom | What to check |
| --- | --- |
| Authentication token is missing or expired | Supply all three service principal parameters, or obtain a new `Get-AzAccessToken` token object. |
| `401` or `403` response | Verify the identity has access to both the Arc server and ESU license resources. |
| `404` response | Check the subscription, resource groups, server name, and license name. |
| Conflict response | Check whether another license operation is in progress or the requested assignment already exists. |
| Script exits with code `1` | Read the final failure message, correct the named resource or permission, and rerun with `-WhatIf`. |
