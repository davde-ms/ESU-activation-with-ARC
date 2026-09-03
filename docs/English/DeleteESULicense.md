# DeleteESULicense.ps1

This script will delete an ESU license. When you delete a license, it will be removed from the Azure ARC server it was assigned to and stop the billing tied to that license.

> **Deleting or deactivating a license can remain billable for up to five calendar days. If you delete and then recreate an ESU license, back-billing still applies for the corresponding period; deletion does not exempt you from those charges. Confirm the current impact in the [official ESU billing guidance](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates#billing-associated-with-modifications-to-an-azure-arc-esu-license) before proceeding.**

Here are the command lines you should use to run it:

## Service Principal Authentication

    ./DeleteESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores"

## User Token Authentication

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./DeleteESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -userToken $authToken

## Parameters

Where:

| Parameter                | Description                                                                                | Required |
| ------------------------ | ------------------------------------------------------------------------------------------ | -------- |
| subscriptionId           | The subscription ID of the Azure subscription you want to use.                             | Yes      |
| tenantId                 | The tenant ID of the Microsoft Entra ID tenant you want to use.                            | No\*     |
| appID                    | The application ID of the service principal you created in the prerequisites section.      | No\*     |
| clientSecret             | The secret key of the service principal you created in the prerequisites section.          | No\*     |
| licenseResourceGroupName | The name of the resource group that contains the ESU license you want to delete.           | Yes      |
| licenseName              | The name of the ESU license you want to delete.                                            | Yes      |
| userToken                | A valid Microsoft Entra ID authentication token object (alternative to service principal). | No\*     |

**Authentication Requirements:**

- \* You must provide either service principal credentials (tenantId, appID, clientSecret) OR a valid userToken

> **Note:** The userToken parameter offers a way for you to work without having to rely on a Service Principal for authentication. You can either provide a token OR provide the tenantID, appID and clientSecret parameters. If you provide both, **the token will be used**.

## Preview and confirmation

Always run with `-WhatIf` first. It displays the license that would be deleted without sending the Azure REST delete. Run without `-WhatIf` only after checking the target; add `-Confirm` for an interactive PowerShell confirmation.

```powershell
./DeleteESULicense.ps1 <parameters> -WhatIf
./DeleteESULicense.ps1 <parameters> -Confirm
```

## Troubleshooting

| Message or symptom | What to check |
| --- | --- |
| Authentication token is missing or expired | Supply all three service principal parameters, or obtain a new `Get-AzAccessToken` token object. |
| `401` or `403` response | Verify the identity can delete ESU licenses in the target resource group. |
| `404` response | Check the subscription, resource group, and license name; confirm the license still exists. |
| Conflict response | Check whether the license is still assigned or another operation is in progress. |
| Script exits with code `1` | Read the final failure message and resolve it before retrying; preview the corrected command with `-WhatIf`. |
