# DeleteESULicense.ps1

This script will delete an ESU license. When you delete a license, it will be removed from the Azure ARC server it was assigned to and stop the billing tied to that license.

> **Deleting an activated license and then recreating it is STRONGLY DISCOURAGED. This is because all activated licenses will incur the monthly ESU fee beginning on October 10, 2023. If you delete a license and subsequently recreate it, you will be charged for the new license from October 10, 2023 onwards, rather than from the time of its initial creation or activation.**

Here is the command line you should use to run it:
    
    ./DeleteESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores"

Where:

| Parameter | Description |
| --- | --- |
| subscriptionId | The subscription ID of the Azure subscription you want to use. |
| tenantId | The tenant ID of the Microsoft Entra ID tenant you want to use. |
| appID | The application ID of the service principal you created in the prerequisites section. |
| clientSecret | The secret key of the service principal you created in the prerequisites section. |
| licenseResourceGroupName | The name of the resource group that will contain the ESU license. |
| licenseName | The name of the ESU license you want to create. |

