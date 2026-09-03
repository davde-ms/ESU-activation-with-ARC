# DeleteESULicense.ps1

This script will delete an ESU license. When you delete a license, it will be removed from the Azure ARC server it was assigned to and stop the billing tied to that license.

> **Deleting an activated license and then recreating it is STRONGLY DISCOURAGED. This is because all activated licenses will incur the monthly ESU fee beginning on October 10, 2023. If you delete a license and subsequently recreate it, you will be charged for the new license from October 10, 2023 onwards, rather than from the time of its initial creation or activation.**

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
