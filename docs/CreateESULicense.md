# CreateESULicense.ps1

This script will create an ESU license.

Here is the command line you should use to run it:
    
    ./CreateESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8

Where:

| Parameter | Description |
| --- | --- |
| subscriptionId | The subscription ID of the Azure subscription you want to use. |
| tenantId | The tenant ID of the Microsoft Entra ID tenant you want to use. |
| appID | The application ID of the service principal you created in the prerequisites section. |
| clientSecret | The secret key of the service principal you created in the prerequisites section. |
| licenseResourceGroupName | The name of the resource group that will contain the ESU license. |
| licenseName | The name of the ESU license you want to create. |
| location | The Azure region where you want to deploy the ESU license. |
| state | The activation state of the ESU license. It can be "Activated" or "Deactivated". |
| edition | The edition of the ESU license. It can be "Standard" or "Datacenter". |
| coreType | The core type of the ESU license. It can be "vCore" or "pCore". |
| coreCount | The number of cores of the ESU license. |

You can type the exact number of cores your host or VM has and the script will automatically calculate the number of cores required for the ESU license.


**Note:** The script can also be rerun with the same base parameters to change some of the properties of the license. Those properties are:
- **state** (allows you to create a deactivated license and activate it later)
- **coreCount** (allows you to change the number of cores of the license if you have need to increase or decrease it)

> **All other parameters are immutable and cannot be changed once the license is created.** 