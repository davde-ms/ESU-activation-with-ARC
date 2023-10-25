# ESU activation with ARC

## Introduction

The aim of this repository is to facilitate the speedy activation of your Windows 2012/R2 Servers, ensuring they are prepared to receive the forthcoming Extended Security Updates (ESU).

Prior activation of your Windows 2012/R2 Servers is necessary for ESU reception. Failure to activate your servers will result in an inability to receive the ESU.

## Prerequisites

 - An Microsoft Entra ID tenant as well as an active Azure subscription.
 - Windows 2012/R2 Server(s) already onboarded to the Azure ARC platform. Please check the [Connected Machine agent prerequisites] (https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites) to ensure your servers are ready for onboarding.
 - An Azure resource group to store the ESU licenses that will be created with these scripts.
 - An Microsoft Entra Enterprise application and service principal that will be used to authenticate to Azure. Please check the [Create an Azure service principal with Azure CLI] (https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal) to create a service principal.
 - The Entra application ID and secret key for the service principal created above.
 - A delegation of rights to the resource group that holds the licenses as well as a delegation of rights to the resource group(s) that contain the Azure ARC servers. Please check the [Delegating access to Azure resources] (https://learn.microsoft.com/en-us/entra/identity-platform/howto-delegate-access-portal) to delegate access to the resource groups if you need assistance. The required delegated rights will be documented in the next section.
 - 
