# ESU activation with ARC

> Les instructions en français se trouvent dans le [fichier LISEZMOI.md](LISEZMOI.md).

## Introduction

The purpose of this repository is to streamline the rapid setup of your Windows 2012/R2 Servers, ensuring they are ready to receive the upcoming Extended Security Updates, referred to as ESU.

Prior activation of your Windows 2012/R2 Servers is necessary for ESU reception. Failure to activate your servers will result in an inability to receive the ESUs.

> It is crucial to thoroughly comprehend the appropriate licensing procedures and prerequisites for the servers you intend to enable ESUs for using Azure ARC. It is imperative to generate the CORRECT form of licenses, such as Standard or Datacenter, considering whether they are for virtual or physical cores. Failing to do so could lead to either excessive billing or non-compliance with Microsoft's licensing regulations. If you have any uncertainties, please seek advice from your dedicated Microsoft Azure specialist or Microsoft Account Executive.

This information and scripts are provided as is and are not intended to be a substitute for professional advice or consulting, including but not limited to legal advice. I do not make any warranties, express, implied or statutory, as to the information in this document or scripts. I do not accept any liability for any damages, direct or consequential, arising from the use of the information contained in this document or scripts.

That being said, let's get started!


## Prerequisites

 - An Microsoft Entra ID tenant as well as an active Azure subscription.
 - Windows 2012/R2 Server(s) already onboarded to the Azure ARC platform. Please check the [Connected Machine agent prerequisites](https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites) to ensure your servers are ready for onboarding.
 - An Azure resource group to store the ESU licenses that will be created with these scripts.
 - An Microsoft Entra Enterprise application and service principal that will be used to authenticate to Azure. Please check the [Create an Azure service principal with Azure CLI](https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal) to create a service principal.
 - The Microsoft Entra application ID and secret key for the service principal created above.
 - A delegation of rights to the resource group that holds the licenses as well as a delegation of rights to the resource group(s) that contain the Azure ARC servers. Please check the [Delegating access to Azure resources](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-steps) to delegate access to the resource groups if you need assistance. The required delegated rights will be documented in the next section.
 - A computer with Powershell 7.x or higher installed. Please check the [Installing PowerShell on Windows](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-core-on-windows) to install Powershell 7.x or higher. The current version of the scripts do not use the AZ Powershell module, but it is recommended to install it for future use. Please check the [Install Azure PowerShell on Windows](https://learn.microsoft.com/en-us/powershell/azure/install-azps-windows) to install the AZ Powershell module if you want to.
 
## Azure rights required for the scripts to work

The following rights have to be delegated on the resource groups you plan on using to store the ESU licence objects as well as the resource groups containing the Azure ARC servers:

- "Microsoft.HybridCompute/licenses/read"
- "Microsoft.HybridCompute/licenses/write"
- "Microsoft.HybridCompute/licenses/delete"
- "Microsoft.HybridCompute/machines/licenseProfiles/read"
- "Microsoft.HybridCompute/machines/licenseProfiles/write"
- "Microsoft.HybridCompute/machines/licenseProfiles/delete"

There is a custom role definition located in the Custom Roles folder in this repository that can be used to create a custom role with the required rights. Please check the [Create a custom role using Azure PowerShell](https://docs.microsoft.com/en-us/azure/role-based-access-control/custom-roles-powershell#create-a-custom-role-using-azure-powershell) to create a custom role with the custom role definition.

Once the role is created, assign it to the security principal and apply it to the all resource groups storing the licenses or the Azure ARC Server objects. For example, if you have 3 resource groups, one for the licenses and two for the Azure ARC servers, you will need to assign the custom role to the security principal and apply it to all three resource groups.

## How to use the scripts

There are currently 4 scripts in this repository (located in the Scripts folder):

- AssignESULicense.ps1
- CreateESULicense.ps1
- ManageESULicenses.ps1 (previously named CreateESULicensesFromCSV.ps1)
- DeleteESULicense.ps1

### AssignESULicense.ps1

This script will assign an ESU license to a specific Azure ARC server. Here is the command line you should use to run it:
    
    ./AssignESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arservers" -ARCServerName "Win2012" -location "EastUS"

where:
- subscriptionId is the subscription ID of the Azure subscription you want to use.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- licenseResourceGroupName is the name of the resource group that contains the ESU license you want to assign to the Azure ARC server.
- licenseName is the name of the ESU license you want to assign to the Azure ARC server.
- serverResourceGroupName is the name of the resource group that contains the Azure ARC server you want to assign the ESU license to.
- ARCServerName is the name of the Azure ARC server you want to assign the ESU license to.
- location is the Azure region where you ARC objects are deployed.

You can use the -u at the end of the command line to UNLINK an existing license from an Azure ARC server. If you do not specify the -u parameter, the script will link the license to the Azure ARC server (default behavior).

## CreateESULicense.ps1

This script will create an ESU license. Here is the command line you should use to run it:
    
    ./CreateESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8

where:
- subscriptionId is the subscription ID of the Azure subscription you want to use.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- licenseResourceGroupName is the name of the resource group that will contain the ESU license.
- licenseName is the name of the ESU license you want to create.
- location is the Azure region where you want to deploy the ESU license.
- state is the activation state of the ESU license. It can be "Activated" or "Deactivated".
- edition is the edition of the ESU license. It can be "Standard" or "Datacenter".
- coreType is the core type of the ESU license. It can be "vCore" or "pCore".
- coreCount is the number of cores of the ESU license.

You can type the exact cores your host or VM has and the script will automatically calculate the number of cores required for the ESU license.

**Note:** The script can also be rerun with the same base parameters to change some of the properties of the license. Those properties are:
- state (allows you to create a deactivated license and activate it later)
- coreCount (allows you to change the number of cores of the license if you have need to increase or decrease it)

All other parameters are immutable and cannot be changed once the license is created.

## ManageESULicenses.ps1

This script will create, assign and manage ESU licenses in bulk, taking its information from a CSV file.
> **Note: license creation will be skipped if Arc agent version is lower than 1.34 since it is the minimum required version that is able to push the ESU activation to servers. Upgrade your ARC agent(s), run the Azure Graph Explorer query again and then rerun the script to process the newly upgraded servers.**

The creation of the CSV file can be done in 2 ways:
### **Manually**:
(by providing the required information in the CSV file). Here are the columns that have to be present in the CSV file:
- Name: the name of the ESU license that will be created (usually matches a server name but not mandatory if you plan on using ESU licenses to cover multiple servers).
- Cores: the number of cores of the VM or physical server.
- IsVirtual: a value that indicates if the server is virtual or not, set is to **Virtual** for VMs or **Physical** for physical servers.
> **Note:** The IsVirtual column is only used to determine the type of core that is going to be assigned to the license. You usually will almost always use vCore licenses unless you are covering physical servers.
- AgentVersion: the version of the Azure ARC agent installed on the server. This information can be retrieved from the Azure portal or by running the [Azure Graph Explorer query](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview) mentioned below.
- ServerResourceGroupName: the name of the resource group that contains the Azure ARC server.
- AssignESULicense: Set it to **True** if you want the license to be assigned to the Azure ARC server, **False** to unlink the license from the Azure ARC server or omit the value altogether to create a license without assigning it.
    
> The AssignedESULicense column is **optional** and is used IF/WHEN you want to manage license assignment as part of the script execution. Note that it is NOT automatically created when using Azure Graph Explorer to generate the CSV file. You will need to **manually** add it to the CSV file if you want to manage assignment of license as part of the execution of this script.

![Example CSV file](media/csv-minmum-required-contents.jpg)

    
### **Automatically**:
(by running the following [Azure Graph Explorer query](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview) and saving its output to a CSV):

    resources
    | where type == 'microsoft.hybridcompute/machines'  
    | extend agentVersion = tostring(properties.agentVersion), operatingSystem = tostring(properties.osSku)  
    | where operatingSystem has "Windows Server 2012"  
    | extend ESUStatus = properties.licenseProfile.esuProfile.licenseAssignmentState  
    | extend Cloud = tostring(properties.cloudMetadata.provider)  
    | extend isVirtual = iff(properties.detectedProperties.model == "Virtual Machine" or properties.detectedProperties.manufacturer == "VMware, Inc." or properties.detectedProperties.manufacturer == "Nutanix" or properties.cloudMetadata.provider == "AWS" or properties.cloudMetadata.provider == "GCP", "Virtual", "Physical")  
    | extend cores = properties.detectedProperties.coreCount, model = tostring(properties.detectedProperties.model), manufacturer = tostring(properties.detectedProperties.manufacturer)  
    | project name,cores,isVirtual,agentVersion,ServerResourceGroupName=resourceGroup,ESUStatus,operatingSystem,model,manufacturer,Cloud
    
> **Note:** The mentioned query will display all Azure ARC onboarded Windows 2012/R2 servers that haven't been assigned an ESU license. You have the option to adjust the query to retrieve all Windows 2012/R2 servers and subsequently filter the results in Excel, keeping only the servers you wish to assign ESU licenses to. While some of the columns returned might not be utilized by the script, they can be helpful for Excel-based result filtering. Ensure you retain the essential columns (as specified in the manual creation process mentioned earlier) to ensure smooth operations.

Always ensure a thorough review of the CSV file's contents before utilization. Note that in rare cases, the Cores might return a NULL value instead of the actual number of cores. If this occurs, manual intervention is necessary, requiring you to edit the CSV file and replace the NULL value with the specific number of cores pertaining to the server.

Here is the command line you should use to run it:
    
    ./ManageESULicenses.ps1 -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -location "EastUS" -state "Deactivated" - edition "Standard" -csvFile "C:\foldername\ESULicenses.csv" 

where:
- subscriptionId is the subscription ID of the Azure subscription you want to use.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- licenseResourceGroupName is the name of the resource group that will contain the ESU licenses.
- location is the Azure region where you want to deploy the ESU licenses.
- state is the activation state of the ESU license. It can be "Activated" or "Deactivated".
- edition is the edition of the ESU license. It can be "Standard" or "Datacenter".
- csvFile is the path to the CSV file that contains the information about the ESU licenses you want to create.


**Note**: you can use the optional parameters to add a prefix and/or suffix to the license name that will be created. If you specify "ESU-" as a prefix and "-marketing" as a suffix, the script will create licenses named "ESU-ServerName-marketing" for each server in the CSV file. That can help you differentiate licenses belonging to different departments or business units for example.

- licenseNamePrefix (optional) is the prefix that will be used to create the ESU licenses. The script will concatenate the prefix with the content of the 'Name' found in the CSV to create the license name.
- licenseNameSuffix (optional) is the suffix that will be used to create the ESU licenses. The script will concatenate the suffix with the content of the 'Name' found in the CSV to create the license name.

**Note**: you can use the optional parameters -log to specify a log file path.

## DeleteESULicense.ps1

This script will delete an ESU license. When you delete a license, it will be removed from the Azure ARC server it was assigned to and stop the billing tied to that license.

> **Deleting an activated license and then recreating it is STRONGLY DISCOURAGED. This is because all activated licenses will incur the monthly ESU fee beginning on October 10, 2023. If you delete a license and subsequently recreate it, you will be charged for the new license from October 10, 2023 onwards, rather than from the time of its initial creation or activation.**

Here is the command line you should use to run it:
    
    ./DeleteESULicense -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores"

where:
- subscriptionId is the subscription ID of the Azure subscription you want to use.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- licenseResourceGroupName is the name of the resource group that contains the ESU license you want to delete.
- licenseName is the name of the ESU license you want to delete.

## License

This project is licensed under the terms of the MIT license. See the [LICENSE](LICENSE) file.
