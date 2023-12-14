# ManageESULicenses.ps1

This script will create, assign and manage ESU licenses in bulk, taking its information from a CSV file.
> **Note: license creation will be skipped if Arc agent version is lower than 1.34 since it is the minimum required version that is able to push the ESU activation to servers. Upgrade your ARC agent(s), run the Azure Graph Explorer query again and then rerun the script to process the newly upgraded servers.**

Here is the command line you should use to run it:
    
    ./ManageESULicenses.ps1 -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -location "EastUS" -state "Deactivated" - edition "Standard" -csvFilePath "C:\foldername\ESULicenses.csv" -licenseNamePrefix "ESU-" -licenseNameSuffix "-marketing" -token $authenticationToken


Where:

| Parameter | Description |
| --- | --- |
| subscriptionId | The subscription ID of the Azure subscription you want to use. |
| tenantId | The tenant ID of the Microsoft Entra ID tenant you want to use. |
| appID | The application ID of the service principal you created in the prerequisites section. |
| clientSecret | The secret key of the service principal you created in the prerequisites section. |
| licenseResourceGroupName | The name of the resource group that will contain the ESU license. |
| location | The Azure region where you want to deploy the ESU license. |
| state | The activation state of the ESU license. It can be "Activated" or "Deactivated". |
| edition | The edition of the ESU license. It can be "Standard" or "Datacenter". |
| csvFilePath | The path to the CSV file that contains the information about the ESU licenses you want to create. |
| licenseNamePrefix (optional) | The prefix that will be used to create the ESU licenses. The script will concatenate the prefix with the content of the 'Name' found in the CSV to create the license name. |
| licenseNameSuffix (optional) | The suffix that will be used to create the ESU licenses. The script will concatenate the suffix with the content of the 'Name' found in the CSV to create the license name. |
| token (optional) | A valid Microsoft Entra ID authentication object that has the rights to create and assign ESU licenses |

> **Note:** The token parameter offers a way for you to work without having to rely on a Service Principal for authentication. You can either provide a token OR provide the tenantID, appID and clientSecret parameters. If you provide both, **the token will be used**.

**Note**: you can use the optional parameters to add a prefix and/or suffix to the license name that will be created. If you specify "ESU-" as a prefix and "-marketing" as a suffix, the script will create licenses named "ESU-ServerName-marketing" for each server in the CSV file. That can help you differentiate licenses belonging to different departments or business units for example.


**Note**: you can use the optional parameters -log to specify a log file path.

---

## The creation of the CSV file can be done in 2 ways:
### **Manually**:
by providing the required information in the CSV file.

 Here are the columns that have to be present in the CSV file:
- Name: the name of the ESU license that will be created (usually matches a server name but not mandatory if you plan on using ESU licenses to cover multiple servers).
- Cores: the number of cores of the VM or physical server.
- IsVirtual: a value that indicates if the server is virtual or not, set is to **Virtual** for VMs or **Physical** for physical servers.
> **Note:** The IsVirtual column is only used to determine the type of core that is going to be assigned to the license. You usually will almost always use vCore licenses unless you are covering physical servers.
- AgentVersion: the version of the Azure ARC agent installed on the server. This information can be retrieved from the Azure portal or by running the [Azure Graph Explorer query](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview) mentioned below.
- ServerResourceGroupName: the name of the resource group that contains the Azure ARC server.
- AssignESULicense: Set it to **True** if you want the license to be assigned to the Azure ARC server, **False** to unlink the license from the Azure ARC server or omit the value altogether to create a license without assigning it.

> **Note:** The AssignedESULicense column is **optional** and is used IF/WHEN you want to manage license assignment as part of the script execution. Note that it is NOT automatically created when using Azure Graph Explorer to generate the CSV file. You will need to **manually** add it to the CSV file if you want to manage assignment of license as part of the execution of this script.

- ESUException: **IF** your server is eligible to receive Extended Security Updates patches at no additional cost, set it to whichever value that matches the use case. Those scenarios are detailed in the [Additional scenarios section of the Deliver Extended Security Updates for Windows Server 2012](https://learn.microsoft.com/en-us/azure/azure-arc/servers/deliver-extended-security-updates#additional-scenarios) article. If your server is not eligible for free ESU, omit the value altogether. Please make sure you fully understand the scenarios and their requirements before setting this value. Failure to do so could lead to either excessive billing or non-compliance with Microsoft's licensing regulations.

> **VERY IMPORTANT:** Make sure **NOT** to list servers that are eligible to receive ESUs at no additional cost in the CSV file, as those servers **should be assigned to an existing billable license** that has been properly tagged and not have their own license created. Failure to do so will lead to excessive billing.
The ability to bulk assign existing license will come shortly.

Here is an example of the expected format of the CSV file:

![Example CSV file](/media/ManageESULicenses_CSV_Example.jpg)

    
### **Automatically**:
by running the following [Azure Graph Explorer query](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview) and saving its output to a CSV:

    resources
    | where type == 'microsoft.hybridcompute/machines'  
    | extend agentVersion = tostring(properties.agentVersion), operatingSystem = tostring(properties.osSku)  
    | where operatingSystem has "Windows Server 2012"  
    | extend ESUStatus = properties.licenseProfile.esuProfile.licenseAssignmentState  
    | extend Cloud = tostring(properties.cloudMetadata.provider)  
    | extend isVirtual = iff(properties.detectedProperties.model == "Virtual Machine" or properties.detectedProperties.manufacturer == "VMware, Inc." or properties.detectedProperties.manufacturer == "Nutanix" or properties.cloudMetadata.provider == "AWS" or properties.cloudMetadata.provider == "GCP", "Virtual", "Physical")  
    | extend cores = properties.detectedProperties.coreCount, model = tostring(properties.detectedProperties.model), manufacturer = tostring(properties.detectedProperties.manufacturer)  
    | project name,cores,isVirtual,agentVersion,ServerResourceGroupName=resourceGroup,ESUStatus,operatingSystem,model,manufacturer,Cloud
    
> **Note:** The mentioned query will display all Azure ARC onboarded Windows 2012/R2 servers that haven't been assigned an ESU license yet. You have the option to adjust the query to retrieve all Windows 2012/R2 servers and subsequently filter the results in Excel, keeping only the servers you wish to assign ESU licenses to. While some of the columns returned might not be utilized by the script, they can be helpful for Excel-based result filtering. Ensure you retain the essential columns (as specified in the manual creation process mentioned earlier) to ensure smooth operations and that you add the optional columns as detailed in the manual CSV file creation process if you have a need for them.

Always ensure a thorough review of the CSV file's contents before utilization. Note that in rare cases, the Cores might return a NULL value instead of the actual number of cores. If this occurs, manual intervention is necessary, requiring you to edit the CSV file and replace the NULL value with the specific number of cores pertaining to the server.

