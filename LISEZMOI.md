# Activation des ESU via Azure ARC

## Introduction

Le but de ce dépôt est de faciliter la configuration rapide de vos serveurs Windows 2012/R2, garantissant qu'ils sont prêts à recevoir les prochaines mises à jour de sécurité étendues, appelées ESU.

L'activation préalable de vos serveurs Windows 2012/R2 est nécessaire pour recevoir les ESU. Ne pas activer vos serveurs entraînera l'impossibilité de recevoir les ESU.

> Il est crucial de bien comprendre les procédures de licence appropriées et les exigences pour les serveurs que vous souhaitez activer avec les ESU (Extended Security Updates) en utilisant Azure ARC. Il est impératif de générer le BON type de licences, telles que Standard ou Datacenter, en tenant compte s'il s'agit de cœurs virtuels ou physiques. Ne pas le faire pourrait entraîner soit une facturation excessive, soit une non-conformité avec les réglementations de licence de Microsoft. En cas de doute, veuillez consulter votre spécialiste Microsoft Azure dédié ou votre responsable de compte Microsoft.

Ces informations et scripts sont fournis tels quels et ne sont pas destinés à se substituer à des conseils professionnels ou à une consultation, y compris, mais sans s'y limiter, des conseils juridiques. Je ne donne aucune garantie, expresse, implicite ou légale, quant aux informations contenues dans ce document ou ces scripts. Je n'accepte aucune responsabilité pour les dommages, directs ou indirects, découlant de l'utilisation des informations contenues dans ce document ou ces scripts.

Cela étant clarifié, allons-y !


## Prérequis

Vous aurez besoin des éléments suivants pour commencer :

- Un locataire Microsoft Entra ainsi qu'un abonnement Azure actif.
- Des serveurs Windows 2012/R2 déjà intégrés à la plateforme Azure ARC. Veuillez consulter les [prérequis de l'agent Connected Machine](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prerequisites) pour vous assurer que vos serveurs sont prêts pour l'intégration.
- Un groupe de ressources Azure pour stocker les licences ESU qui seront créées avec ces scripts.
- Une Application d'Entreprise Microsoft Entra et un service principal actif qui seront utilisés pour l'authentification d'Azure. Veuillez consulter le document [Créer un service principal Microsoft Entra](https://learn.microsoft.com/fr-fr/entra/identity-platform/howto-create-service-principal-portal) pour sa création.
- L'ID de l'application Microsoft Entra et la clé secrète pour le service principal créé ci-dessus.
- Une délégation de droits sur le groupe de ressources contenant les licences, ainsi qu'une délégation de droits sur le(s) groupe(s) de ressources contenant les serveurs Azure ARC. Veuillez consulter la rubrique [Déléguer l'accès aux ressources Azure](https://learn.microsoft.com/fr-fr/azure/role-based-access-control/role-assignments-steps) pour déléguer l'accès aux groupes de ressources si vous avez besoin d'aide. Les droits délégués requis seront documentés dans la section suivante.
- Un ordinateur avec Powershell 7.x ou une version ultérieure installée. Veuillez consulter la page [Installer PowerShell sur Windows](https://learn.microsoft.com/fr-fr/powershell/scripting/install/installing-powershell-on-windows) pour installer Powershell 7.x ou une version ultérieure. La version actuelle des scripts n'utilise pas le module AZ Powershell, mais il est recommandé de l'installer pour une utilisation future. Veuillez consulter la page [Installer Azure PowerShell sur Windows](https://learn.microsoft.com/fr-fr/powershell/azure/install-azps-windows) pour installer le module AZ Powershell si vous le souhaitez.
 
## Droits Azure requis pour exécuter les scripts

Les droits suivants doivent être délégués sur les groupes de ressources que vous prévoyez d'utiliser pour stocker les objets de licence ESU, ainsi que sur les groupes de ressources contenant les serveurs Azure ARC:

- "Microsoft.HybridCompute/licenses/read"
- "Microsoft.HybridCompute/licenses/write"
- "Microsoft.HybridCompute/licenses/delete"
- "Microsoft.HybridCompute/machines/licenseProfiles/read"
- "Microsoft.HybridCompute/machines/licenseProfiles/write"
- "Microsoft.HybridCompute/machines/licenseProfiles/delete"

Il y a une définition de rôle personnalisé située dans le dossier "Custom Roles" de ce dépôt qui peut être utilisée pour créer un rôle personnalisé avec les droits requis. Veuillez consulter le document [Créer un rôle personnalisé à l'aide d'Azure PowerShell](https://learn.microsoft.com/fr-fr/azure/role-based-access-control/custom-roles-powershell#create-a-custom-role-with-json-template) pour créer un rôle personnalisé avec cette définition de rôle personnalisé.

Une fois le rôle créé, assignez-le au service principal et appliquez le aux groupes de ressources.

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

## CreateESULicensesFromCSV.ps1

This script will create ESU licenses in bulk, taking its information from a CSV file.
> **Note: license creation will be skipped if Arc agent version is lower than 1.34 since it is the minimum required version that is able to push the ESU activation to servers. Upgrade your ARC agent(s), run the Azure Graph Explorer query again and then rerun the script to process the newly upgraded servers.**

The creation of the CSV file can be done in 2 ways:
- **Manually** (by providing the required information in the CSV file). Here are the columns that have to be present in the CSV file:
    - Name: the name of the ESU license that will be created (usually matches a server name but not mandatory if you plan on using ESU licenses to cover multiple servers).
    - IsVirtual: a value that indicates if the server is virtual or not, set is to **Virtual** for VMs or **Physical** for physical servers.
    > **Note:** The IsVirtual column is only used to determine the type of core that is going to be assigned to the license. You usually will almost always use vCore licenses unless you are covering physical servers.
    - Cores: the number of cores of the VM or physical server.
    - AgentVersion: the version of the Azure ARC agent installed on the server. This information can be retrieved from the Azure portal or by running the [Azure Graph Explorer query](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview) mentioned below.
    
- **Automatically** (by running the following [Azure Graph Explorer query](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview) and saving its output to a CSV):

    Resources
    | where type == 'microsoft.hybridcompute/machines'  
    | extend agentVersion = tostring(properties.agentVersion) , operatingSystem = tostring(properties.osSku)  
    | where operatingSystem has "Windows Server 2012"  
    | extend ESUStatus = properties.licenseProfile.esuProfile.licenseAssignmentState  
    | where ESUStatus == "NotAssigned"  
    | extend Cloud = tostring(properties.cloudMetadata.provider)  
    | extend isVirtual = iff(properties.detectedProperties.model == "Virtual Machine" or properties.detectedProperties.manufacturer == "VMware, Inc." or properties.detectedProperties.manufacturer == "Nutanix" or properties.cloudMetadata.provider == "AWS" or properties.cloudMetadata.provider == "GCP", "Virtual", "Physical")  
    | extend cores = properties.detectedProperties.coreCount, model = tostring(properties.detectedProperties.model), manufacturer = tostring(properties.detectedProperties.manufacturer)  
    | project name,operatingSystem,model,manufacturer,cores,isVirtual,Cloud,ESUStatus,agentVersion
    
> **Note:** The mentioned query will display all Azure ARC onboarded Windows 2012/R2 servers that haven't been assigned an ESU license. You have the option to adjust the query to retrieve all Windows 2012/R2 servers and subsequently filter the results in Excel, keeping only the servers you wish to assign ESU licenses to. While some of the columns returned might not be utilized by the script, they can be helpful for Excel-based result filtering. Ensure you retain the essential columns (as specified in the manual creation process mentioned earlier) to ensure smooth operations.

Always ensure a thorough review of the CSV file's contents before utilization. Note that in rare cases, the Cores might return a NULL value instead of the actual number of cores. If this occurs, manual intervention is necessary, requiring you to edit the CSV file and replace the NULL value with the specific number of cores pertaining to the server.

Here is the command line you should use to run it:
    
    ./CreateESULicensesFromCSV.ps1 -subscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -location "EastUS" -state "Deactivated" - edition "Standard" -csvFile "C:\foldername\ESULicenses.csv" 

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
