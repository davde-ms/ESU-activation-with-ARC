# ManageESUAssignments.ps1

This script will assign ESU licenses in bulk, taking its information from a CSV file.

> **The main goal for this script is to enable one (license) to many (Azure ARC servers) assignments. This is useful if/when you have a large number of Azure ARC servers that need to be assigned to the same license.**


Here is the command line you should use to run it:
    
    ./ManageESUAssignments.ps1 -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"

Where:

| Parameter | Description |
| --- | --- |
| subscriptionId | The subscription ID of the Azure subscription you want to use. |
| tenantId | The tenant ID of the Microsoft Entra ID tenant you want to use. |
| appID | The application ID of the service principal you created in the prerequisites section. |
| clientSecret | The secret key of the service principal you created in the prerequisites section. |
| location | The Azure region where you ARC objects are deployed. |
| csvFilePath | The path to the CSV file that contains the information about the ESU licenses assignments you want to apply to Azure ARC servers. |

> The CSV file has to be **manually** created and should contain the following columns:

| Column Name | Value |
| --- | --- |
| Name | The name of the Azure ARC server you want to assign the ESU license to. |
| ServerResourceGroupName | The name of the resource group that contains the Azure ARC server you want to assign the ESU license to. |
| LicenseName | The name of the ESU license you want to assign to the Azure ARC server. |
| LicenseResourceGroupName | The name of the resource group that contains the ESU license you want to assign to the Azure ARC server. |
| AssignESULicense | Set it to **True** if you want the license to be assigned to the Azure ARC server or **False** to unlink the license from the Azure ARC server. |

Here is an example of the expected format of the CSV file:

![CSV File Layout](/media/ManageESUAssignments_CSV_example.jpg)
