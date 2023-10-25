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

