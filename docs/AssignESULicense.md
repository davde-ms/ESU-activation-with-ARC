# AssignESULicense.ps1

This script will assign a single ESU license to a specific Azure ARC server.

Here is the command line you should use to run it:
    
    ./AssignESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arservers" -ARCServerName "Win2012" -location "EastUS"

Where:

| Parameter | Description |
| --- | --- |
| subscriptionId | The subscription ID of the Azure subscription you want to use. |
| tenantId | The tenant ID of the Microsoft Entra ID tenant you want to use. |
| appID | The application ID of the service principal you created in the prerequisites section. |
| clientSecret | The secret key of the service principal you created in the prerequisites section. |
| licenseResourceGroupName | The name of the resource group that contains the ESU license you want to assign to the Azure ARC server. |
| licenseName | The name of the ESU license you want to assign to the Azure ARC server. |
| serverResourceGroupName | The name of the resource group that contains the Azure ARC server you want to assign the ESU license to. |
| ARCServerName | The name of the Azure ARC server you want to assign the ESU license to. |
| location | The Azure region where you ARC objects are deployed. |


> You can use the `-u` at the end of the command line to UNLINK an existing license from an Azure ARC server. If you do not specify the `-u` parameter, the script will link the license to the Azure ARC server (default behavior).

[]: # Path: Scripts/docs/AssignESULicenses.md

