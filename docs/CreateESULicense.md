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
