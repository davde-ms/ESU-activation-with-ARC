# ESU activation with ARC

## Introduction

The aim of this repository is to facilitate the speedy activation of your Windows 2012/R2 Servers, ensuring they are prepared to receive the forthcoming Extended Security Updates (ESU).

Prior activation of your Windows 2012/R2 Servers is necessary for ESU reception. Failure to activate your servers will result in an inability to receive the ESU.

## Prerequisites

 - An Microsoft Entra ID tenant as well as an active Azure subscription.
 - Windows 2012/R2 Server(s) already onboarded to the Azure ARC platform. Please check the [Connected Machine agent prerequisites] (https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites) to ensure your servers are ready for onboarding.
 - An Azure resource group to store the ESU licenses that will be created with these scripts.
 - An Microsoft Entra Enterprise application and service principal that will be used to authenticate to Azure. Please check the [Create an Azure service principal with Azure CLI] (https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal) to create a service principal.
 - The Microsoft Entra application ID and secret key for the service principal created above.
 - A delegation of rights to the resource group that holds the licenses as well as a delegation of rights to the resource group(s) that contain the Azure ARC servers. Please check the [Delegating access to Azure resources] (https://learn.microsoft.com/en-us/entra/identity-platform/howto-delegate-access-portal) to delegate access to the resource groups if you need assistance. The required delegated rights will be documented in the next section.
 - A computer with Powershell 7.x or higher installed. Please check the [Installing PowerShell on Windows] (https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-core-on-windows?view=powershell-7.1) to install Powershell 7.x or higher. The current version of the scripts do not use the AZ Powershell module, but it is recommended to install it for future use. Please check the [Install Azure PowerShell on Windows] (https://learn.microsoft.com/en-us/powershell/azure/install-azps-windows) to install the AZ Powershell module if you want to.
 
## Azure rights required for the scripts to work

The following rights have to be delegated on the resource groups you plan on using to store the ESU licence objects as well as the resource groups containing the Azure ARC servers:

- "Microsoft.HybridCompute/licenses/read"
- "Microsoft.HybridCompute/licenses/write"
- "Microsoft.HybridCompute/licenses/delete"
- "Microsoft.HybridCompute/machines/licenseProfiles/read"
- "Microsoft.HybridCompute/machines/licenseProfiles/write"
- "Microsoft.HybridCompute/machines/licenseProfiles/delete"

There is a custom role definition located in the Custom Roles folder in this repository that can be used to create a custom role with the required rights. Please check the [Create a custom role using Azure PowerShell] (https://docs.microsoft.com/en-us/azure/role-based-access-control/custom-roles-powershell#create-a-custom-role-using-azure-powershell) to create a custom role with the custom role definition.

Once the role is created, assign it to the security principal and apply it to the resource groups.

## How to use the scripts

There are currently 4 scripts in this repository (located in the Scripts folder):

- AssignESULicense.ps1
- CreateESULicense.ps1
- CreateESULicensesFromCSV.ps1
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

### CreateESULicense.ps1

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
- state is the state of the ESU license. It can be "Activated" or "Deactivated".
- edition is the edition of the ESU license. It can be "Standard" or "Datacenter".
- coreType is the core type of the ESU license. It can be "vCore" or "pCore".
- coreCount is the number of cores of the ESU license.

You can type the exact cores your host or VM has and the script will automatically calculate the number of cores required for the ESU license.

**Note:** The script can also be rerun with the same base parameters to change some of the properties of the license. Those properties are:
- state (allows you to create a deactivated license and activate it later)
- coreCount (allows you to change the number of cores of the license if you have need to increase or decrease it)

All other parameters are immutable and cannot be changed once the license is created.
