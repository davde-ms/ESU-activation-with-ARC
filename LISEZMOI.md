# Activation des ESU via Azure ARC

> English instructions can be found in the [README.md file](README.md).

## Introduction

Le but de ce référentiel est de faciliter la configuration rapide de vos serveurs Windows 2012/R2, garantissant qu'ils sont prêts à recevoir les prochaines mises à jour de sécurité étendues, appelées ESU.

L'activation préalable de vos serveurs Windows 2012/R2 est nécessaire pour recevoir les ESU. La non activation de vos serveurs entraînera l'impossibilité de recevoir les ESU.

> Il est crucial de bien comprendre les procédures de licence appropriées et les exigences pour les serveurs pour lesquels vous souhaitez activer les ESU (Extended Security Updates) en utilisant Azure ARC. Il est impératif de générer le BON type de licence, tel que Standard ou Datacenter, mais aussi de bien choisir le type de cœurs (virtuels ou physiques). Ne pas le faire pourrait entraîner soit une facturation excessive, soit une non-conformité avec les réglementations de licence de Microsoft. En cas de doute, veuillez consulter votre spécialiste Microsoft Azure dédié ou votre responsable de compte Microsoft.

Ces informations et scripts sont fournis "tels quels" et ne sont pas destinés à se substituer à des conseils professionnels ou à une consultation, y compris, mais sans s'y limiter, des conseils juridiques. Je ne donne aucune garantie, expresse, implicite ou légale, quant aux informations contenues dans ce document ou ces scripts. Je n'accepte aucune responsabilité pour les dommages, directs ou indirects, découlant de l'utilisation des informations contenues dans ce document ou ces scripts.

Cela étant clarifié, allons-y !

## Prérequis

Vous aurez besoin des éléments suivants pour commencer :

- Un locataire Microsoft Entra ainsi qu'un abonnement Azure actif.
- Des serveurs Windows 2012/R2 déjà intégrés à la plateforme Azure ARC. Veuillez consulter les [prérequis de l'agent Connected Machine](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prerequisites) pour vous assurer que vos serveurs sont prêts pour l'intégration.
- Un ou plusieurs groupes de ressources Azure pour stocker les licences ESU qui seront créées avec ces scripts. Les licences ESU peuvent être situées dans le même abonnement que vos serveurs ARC ou dans un abonnement différent.
- Une Application d'Entreprise Microsoft Entra et un service principal actif qui seront utilisés pour l'authentification Azure. Veuillez vous référer au document [Créer un service principal Microsoft Entra](https://learn.microsoft.com/fr-fr/entra/identity-platform/howto-create-service-principal-portal) pour sa création.
- L'ID de l'application Microsoft Entra et la clé secrète pour le service principal créé ci-dessus.
- Une délégation de droits sur le groupe de ressources contenant les licences, ainsi qu'une délégation de droits sur les groupes de ressources contenant les serveurs ARC Azure. Veuillez consulter la rubrique [Déléguer l'accès aux ressources Azure](https://learn.microsoft.com/fr-fr/azure/role-based-access-control/role-assignments-steps) pour déléguer l'accès aux groupes de ressources si vous avez besoin d'aide. Les droits délégués requis seront documentés dans la section suivante.
- Un ordinateur avec Powershell 7.x ou une version ultérieure installée. Veuillez consulter la page [Installer PowerShell sur Windows](https://learn.microsoft.com/fr-fr/powershell/scripting/install/installing-powershell-on-windows) pour installer Powershell 7.x ou une version ultérieure. La version actuelle des scripts n'utilise pas le module AZ Powershell, mais il est recommandé de l'installer pour une utilisation future. Veuillez consulter la page [Installer Azure PowerShell sur Windows](https://learn.microsoft.com/fr-fr/powershell/azure/install-azps-windows) pour installer le module AZ Powershell si vous le souhaitez.

> **Note** : Les scripts AssignESULicense.ps1, CreateESULicense.ps1, DeleteESULicense.ps1, CheckESUStatus.ps1, ManageESUAssignments.ps1 et ManageESULicenses.ps1 prennent en charge un jeton utilisateur Microsoft Entra à la place d'un principal de service. L'utilisateur doit disposer des droits requis décrits dans la section suivante.

## Droits Azure requis pour exécuter les scripts

Les droits suivants doivent être délégués sur les groupes de ressources que vous prévoyez d'utiliser pour stocker les objets de licence ESU, ainsi que sur les groupes de ressources contenant les serveurs Azure ARC:

- "Microsoft.HybridCompute/licenses/read"
- "Microsoft.HybridCompute/licenses/write"
- "Microsoft.HybridCompute/licenses/delete"
- "Microsoft.HybridCompute/machines/licenseProfiles/read"
- "Microsoft.HybridCompute/machines/licenseProfiles/write"
- "Microsoft.HybridCompute/machines/licenseProfiles/delete"

Il y a une définition de rôle personnalisé située dans le dossier "Custom Roles" de ce référentiel qui peut être utilisée pour créer un rôle personnalisé avec les droits requis. Voir [Créer un rôle personnalisé à l'aide d'Azure PowerShell](https://learn.microsoft.com/fr-fr/azure/role-based-access-control/custom-roles-powershell#create-a-custom-role-with-json-template) pour créer un rôle personnalisé avec cette définition de rôle personnalisé.

Une fois que le rôle est créé, attribuez-le au service principal et appliquez-le à tous les groupes de ressources stockant les licences ou les objets de serveurs Azure ARC. Par exemple, si vous avez 3 groupes de ressources, un pour les licences et deux pour les serveurs Azure ARC, vous devrez attribuer le rôle personnalisé au service principal et l'appliquer à ces trois groupes de ressources. **Note importante** : Pour les scénarios inter-abonnements, assurez-vous que le service principal dispose des droits appropriés dans tous les abonnements concernés (abonnement des serveurs ARC et abonnement des licences ESU).

## Comment utiliser les scripts

Il y a actuellement 6 scripts dans ce référentiel (situé dans le dossier Scripts) :

- [AssignESULicense.ps1](docs/Français/AssignESULicense.md) (assigne une licence ESU à un serveur Azure ARC)
- [CreateESULicense.ps1](docs/Français/CreateESULicense.md) (crée une licence ESU)
- [DeleteESULicense.ps1](docs/Français/DeleteESULicense.md) (supprime une licence ESU)
- [CheckESUStatus.ps1](docs/Français/CheckESUStatus.md) (vérifie l'état des licences ESU des serveurs avec Azure Arc)
- [ManageESUAssignments.ps1](docs/Français/ManageESUAssignments.md) (assigne des licences ESU à de multiples serveurs Azure ARC, supporte les scénarios inter-abonnements)
- [ManageESULicenses.ps1](docs/Français/ManageESULicenses.md) (crée, assigne et gère les licences ESU en bloc)

### Quel script dois-je utiliser ?

| Objectif | Script | Point de départ |
| --- | --- | --- |
| Vérifier l'état actuel des attributions ESU sans modification | `CheckESUStatus.ps1` | [Guide](docs/Français/CheckESUStatus.md) et [modèle CSV](samples/CheckESUStatus.csv) |
| Créer ou mettre à jour une seule licence ESU | `CreateESULicense.ps1` | Vérifiez le modèle de licence avant de choisir l'édition, le type de cœurs et leur nombre. |
| Attribuer ou dissocier une licence existante | `AssignESULicense.ps1` | Utilisez-le lorsque le serveur et la ressource de licence sont déjà connus. |
| Créer ou mettre à jour des licences en bloc, avec attribution ou dissociation facultative | `ManageESULicenses.ps1` | [Guide](docs/Français/ManageESULicenses.md) et [modèle CSV](samples/ManageESULicenses.csv) |
| Attribuer ou dissocier des licences existantes en bloc, y compris entre abonnements | `ManageESUAssignments.ps1` | [Guide](docs/Français/ManageESUAssignments.md) et [modèle CSV](samples/ManageESUAssignments.csv) |
| Supprimer une licence existante | `DeleteESULicense.ps1` | Lisez l'avertissement relatif à la suppression et à la facturation avant l'exécution. |

### Procédure client sécurisée

1. Exécutez d'abord `CheckESUStatus.ps1` pour inventorier les attributions actuelles. Ce script est en lecture seule.
2. Copiez le modèle approprié du dossier [`samples`](samples/) et remplacez toutes les valeurs fictives par des données client vérifiées.
3. Prévisualisez le plan avant toute modification. Utilisez `-DryRun` avec `ManageESUAssignments.ps1` ou `ManageESULicenses.ps1`; les deux scripts prennent également en charge `-WhatIf` et `-Confirm`.
4. Vérifiez les nombres de cœurs normalisés, le choix de l'édition et du type de cœurs, les noms de licence générés et les actions d'attribution ou de dissociation affichés dans le plan et le récapitulatif.
5. Exécutez la même commande vérifiée sans `-DryRun` ni `-WhatIf` uniquement lorsque le plan est correct. Utilisez `-Confirm` pour demander une confirmation interactive pour chaque opération.

`ManageESUAssignments.ps1 -DryRun` valide le CSV et l'accès aux ressources au moyen de requêtes Azure `GET` en lecture seule; aucune requête de modification n'est envoyée. `ManageESULicenses.ps1 -DryRun` valide l'ensemble du CSV et utilise des requêtes Azure `GET` en lecture seule pour compter les licences existantes et nouvelles; il ne crée, ne modifie, n'attribue, ne dissocie et ne supprime aucune ressource.

## AssignESULicense.ps1

Ce script assignera une licence ESU au serveur ARC Azure spécifié. Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./AssignESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arservers" -ARCServerName "Win2012" -location "EastUS"

où :

- subscriptionId est l'ID d'abonnement de l'abonnement Azure où se trouvent vos serveurs Azure ARC et licences ESU.
- tenantId est l'ID de locataire du locataire Microsoft Entra ID que vous souhaitez utiliser.
- appID est l'ID d'application du service principal que vous avez créé dans la section Prérequis.
- clientSecret est la clé secrète du service principal que vous avez créé dans la section Prérequis.
- licenseResourceGroupName est le nom du groupe de ressources qui contient la licence ESU que vous souhaitez assigner au serveur ARC Azure.
- licenseName est le nom de la licence ESU que vous souhaitez assigner au serveur ARC Azure.
- serverResourceGroupName est le nom du groupe de ressources qui contient le Azure serveur ARC auquel vous souhaitez assigner la licence ESU.
- ARCServerName est le nom du serveur ARC Azure auquel vous souhaitez assigner la licence ESU.
- location est la Azure région où vos objets ARC sont déployés.

Vous pouvez utiliser -u à la fin de la ligne de commande pour DISSOCIER (unlink) une licence existante d'un serveur ARC Azure. Si vous ne spécifiez pas le paramètre -u, le script assignera la licence au serveur ARC Azure (comportement par défaut).

## CreateESULicense.ps1

Ce script créera une licence ESU. Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./CreateESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8

où :

- subscriptionId est l'ID d'abonnement de l'abonnement Azure où se trouvent vos serveurs Azure ARC et licences ESU.
- tenantId est l'ID de locataire du locataire Microsoft Entra ID que vous souhaitez utiliser.
- appID est l'ID d'application du service principal que vous avez créé dans la section Prérequis.
- clientSecret est la clé secrète du service principal que vous avez créé dans la section Prérequis.
- licenseResourceGroupName est le nom du groupe de ressources qui contient la licence ESU que vous souhaitez assigner au serveur ARC Azure.
- licenseName est le nom de la licence ESU que vous souhaitez assigner au serveur ARC Azure.
- location est la Azure région où vos objets ARC sont déployés.
- state est l'état d'activation de la licence ESU. Il peut être "Activated" ou "Deactivated.
- edition est l'édition de la licence ESU. Il peut s'agir de "Standard" ou de "Datacenter".
- coreType est le type e coeur à utiliser pour la licence ESU. Il peut s'agir de "vCore" (coeur virtuel) ou de "pCore" (coeur physique).
- coreCount est le nombre de cœurs associés la licence ESU.

Vous pouvez entrer le nombre exact de cœurs dont dispose votre hôte ou votre machine virtuelle et le script calculera automatiquement le nombre de cœurs requis pour la licence ESU.

**Remarque :** Le script peut également être réexécuté avec les mêmes paramètres de base pour changer certaines des propriétés de la licence. Ces propriétés sont les suivantes :

- state (vous permet de créer une licence désactivée et de l'activer ultérieurement)
- coreCount (vous permet de modifier le nombre de cœurs de la licence si vous avez besoin de l'augmenter ou de le diminuer)

Tous les autres paramètres sont **immuables** et ne peuvent pas être modifiés une fois la licence créée.

## DeleteESULicense.ps1

Ce script supprimera une licence ESU. Lorsque vous supprimez une licence, elle est supprimée du serveur ARC Azure auquel elle a été affectée et arrête la facturation liée à cette licence.

> **La suppression ou la désactivation d'une licence peut rester facturée pendant un maximum de cinq jours calendaires. Si vous supprimez puis recréez une licence ESU, la rétrofacturation continue de s'appliquer à la période correspondante; la suppression ne vous exonère pas de ces frais. Vérifiez l'incidence actuelle dans les [informations officielles sur la facturation ESU](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates#billing-associated-with-modifications-to-an-azure-arc-esu-license) avant de continuer.**

Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./DeleteESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores"

où :

- subscriptionId est l'ID d'abonnement de l'abonnement Azure où se trouvent vos licences ESU.
- tenantId est l'ID de locataire du locataire Microsoft Entra ID que vous souhaitez utiliser.
- appID est l'ID d'application du service principal que vous avez créé dans la section Prérequis.
- clientSecret est la clé secrète du service principal que vous avez créé dans la section Prérequis.
- licenseResourceGroupName est le nom du groupe de ressources qui contiendra les licences ESU.
- licenseName est le nom de la licence ESU que vous souhaitez supprimer.

## CheckESUStatus.ps1

Ce script vérifie en lecture seule l'état des licences ESU d'un serveur ou d'une liste de serveurs avec Azure Arc.

```powershell
./CheckESUStatus.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server"
```

Vous pouvez également fournir `-userToken`, traiter un fichier avec `-csvFilePath` et exporter les résultats avec `-exportCsvPath`. Le paramètre `-location` reste accepté pour assurer la compatibilité des commandes existantes, mais la requête d'état ne l'utilise pas. Consultez le [guide CheckESUStatus en français](docs/Français/CheckESUStatus.md) pour les exemples détaillés.

## ManageESUAssignments.ps1

Ce script attribuera des licences ESU en masse, en extrayant les informations d'un fichier CSV. **Supporte désormais les scénarios inter-abonnements** où les licences ESU peuvent être situées dans des abonnements Azure différents de ceux des serveurs ARC.

> **L'objectif principal de ce script est de permettre l'attribution d'une licence à de nombreux serveurs Azure ARC. C'est très utile lorsque vous avez un grand nombre de serveurs Azure ARC auxquels vous devez attribuer une même licence.**

Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"

**Pour les scénarios inter-abonnements**, vous pouvez optionnellement spécifier un abonnement différent pour les licences ESU :

    ./ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseSubscriptionId "00000000-0000-0000-0000-000000000004" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"

où :

- arcServerSubscriptionId est l'ID de l'abonnement Azure contenant vos serveurs Azure ARC. L'ancien nom `-subscriptionId` reste disponible comme alias de compatibilité.
- licenseSubscriptionId _(optionnel)_ est l'ID d'abonnement où se trouvent vos licences ESU. Si non fourni, utilise le même abonnement que les serveurs ARC.
- tenantId est l'ID de locataire du locataire Microsoft Entra ID que vous souhaitez utiliser.
- appID est l'ID d'application du service principal que vous avez créé dans la section Prérequis.
- clientSecret est la clé secrète du service principal que vous avez créé dans la section Prérequis.
- location est la Azure région où vos objets ARC sont déployés.
- csvFilePath est le nom du fichier CSV qui contient les informations sur les assignations de licences ESU que vous appliquer à vos serveurs Azure ARC.

> Le fichier CSV doit être créé **manuellement** et doit contenir les colonnes suivantes:

- Name: Le nom du serveur Azure ARC auquel vous souhaitez assigner la licence ESU.
- ServerResourceGroupName: le nom du groupe de ressources qui contient le serveur Azure ARC auquel vous souhaitez assigner la licence ESU.
- LicenseName: le nom de la licence ESU que vous souhaitez assigner au serveur Azure ARC.
- LicenseResourceGroupName: le nom du groupe de ressources qui contient la licence ESU que vous souhaitez assigner au serveur Azure ARC.
- AssignESULicense: lorsque la valeur est à **True**, la license sera automatiquement assignée au serveur ARC Azure. **False** désassociera la licence ESU du serveur ARC Azure.
- LicenseSubscriptionId _(optionnel)_: L'ID d'abonnement où se trouve la licence spécifique. **Cette colonne a toujours la priorité** sur le paramètre de ligne de commande lorsqu'elle est fournie. Si omise, utilise le paramètre du script ou par défaut l'abonnement du serveur ARC pour la compatibilité descendante.

Voici un example du format du fichier CSV:

![CSV File Layout](media/ManageESUAssignments_CSV_example.jpg)

### Exemples inter-abonnements

**CSV de scénario mixte** (certaines licences dans différents abonnements) :

```csv
Name,ServerResourceGroupName,LicenseName,LicenseResourceGroupName,AssignESULicense,LicenseSubscriptionId
Server1,rg-servers,ESU-License-1,rg-licenses,True,00000000-0000-0000-0000-000000000004
Server2,rg-servers,ESU-License-2,rg-licenses,True,
Server3,rg-servers,ESU-License-3,rg-licenses,False,00000000-0000-0000-0000-000000000005
```

**Logique de priorité des abonnements :**

1. **Colonne CSV en premier** : Si `LicenseSubscriptionId` est fourni dans la ligne CSV → toujours utiliser celui-ci
2. **Paramètre de ligne de commande** : Si aucune valeur CSV mais `-licenseSubscriptionId` fourni → utiliser celui-ci
3. **Par défaut** : Utiliser l'abonnement du serveur ARC (compatibilité descendante)

> **Authentification** : Vous pouvez transmettre avec `-userToken` un jeton renvoyé par `Get-AzAccessToken -ResourceUrl https://management.azure.com/` au lieu de fournir `tenantId`, `appID` et `clientSecret`.

> **Mode de simulation** : `-DryRun` valide le fichier CSV et l'accès aux ressources avec des requêtes `GET` en lecture seule. Il n'envoie aucune requête `PUT`, `PATCH` ou `DELETE`.

## ManageESULicenses.ps1

Ce script créera, assignera et gèrera les licences ESU en bloc, en prenant ses informations d'un fichier CSV.

> **Remarque : la création de licence sera ignorée si la version de l'agent Arc est inférieure à 1.34, car il s'agit de la version minimale requise capable de pousser l'activation ESU vers les serveurs. Mettez à niveau vos agents ARC, réexécutez la requête Azure Graph Explorer, puis réexécutez le script pour traiter les serveurs nouvellement mis à niveau.**

La création du fichier CSV peut être effectuée de 2 manières :

### **Manuellement**:

(en fournissant les informations requises dans le fichier CSV).

Voici les colonnes qui doivent être présentes dans le fichier CSV :

- Nom : nom de la licence ESU qui sera créée (correspond généralement à un nom de serveur mais pas obligatoire si vous prévoyez d'utiliser des licences ESU pour couvrir plusieurs serveurs).
- Cores : nombre de cœurs de la machine virtuelle ou du serveur physique.
- IsVirtual : valeur qui indique si le serveur est virtuel ou non, soit **Virtual** pour les machines virtuelles ou **Physical** pour les serveurs physiques.

> **Remarque :** La colonne IsVirtual est seulement utilisée pour déterminer le type de noyau qui va être assigné à la licence. Vous utiliserez généralement presque toujours des licences vCore, sauf si vous couvrez des serveurs physiques.

- AgentVersion : version de l'agent ARC Azure installé sur le serveur. Ces informations peuvent être récupérées à partir du portail Azure ou en exécutant la requête [Azure De Graph Explorer](https://learn.microsoft.com/fr-fr/graph/graph-explorer/graph-explorer-overview) mentionnée ci-dessous.
- ServerResourceGroupName : nom du groupe de ressources qui contient le serveur ARC Azure auquel vous souhaitez assigner la licence ESU.
- AssignESULicense: lorsque la valeur est à **True**, la license sera automatiquement assignée au serveur ARC Azure. **False** désassociera la licence ESU du serveur ARC Azure. Enfin, si vous désirez créer une licence ESU sans l'assigner à un serveur ARC Azure, vous devez **omettre** une valeur pour la colonne AssignESULicense.

> **Note:** La colonne AssignESULicense est **optionelle** et n'est utile que quand/lorsque vous voulez gérer les attributions de licences via le fichier CSV. Notez qu'elle n'est PAS créée automatiquement lors de la génération du fichier CSV avec Azure Graph Explorer. Vous devrez donc l'ajouter **manuellement** si vous comptez gérer l'assignation des licenses lors de l'exécution de ce script.

- ESUException : texte facultatif copié dans l'étiquette `ESU Usage` de la ressource de licence. Établissez séparément l'éligibilité à tout scénario sans frais ou d'évaluation selon les conditions de licence Microsoft applicables avant d'utiliser ce champ.

> **Avertissement de facturation :** les étiquettes n'établissent pas l'éligibilité et n'ont aucun effet sur la facturation. Microsoft indique que la facturation dépend du nombre de cœurs associé à la licence activée, quelles que soient les étiquettes. Ne provisionnez pas de cœurs pour les machines dont l'éligibilité à un scénario sans frais a été établie séparément. Consultez les [instructions officielles de provisionnement des licences](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/license-extended-security-updates).
> L'attribution en bloc de licences existantes est prise en charge par [ManageESUAssignments.ps1](docs/Français/ManageESUAssignments.md).

Commencez avec le [modèle CSV ManageESULicenses](samples/ManageESULicenses.csv) prêt à copier.

Voici un example du format du fichier CSV:

![Exemple d'un fichier CSV type](media/ManageESULicenses_CSV_Example.jpg)

### **Automatiquement**

(en exécutant la requête suivante de [Azure De Graph Explorer](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview) et en enregistrant les données ainsi produites dans un fichier CSV) :

    resources
    | where type == 'microsoft.hybridcompute/machines'
    | extend agentVersion = tostring(properties.agentVersion), operatingSystem = tostring(properties.osSku)
    | where operatingSystem has "Windows Server 2012"
    | extend ESUStatus = properties.licenseProfile.esuProfile.licenseAssignmentState
    | extend Cloud = tostring(properties.cloudMetadata.provider)
    | extend isVirtual = iff(properties.detectedProperties.model == "Virtual Machine" or properties.detectedProperties.manufacturer == "VMware, Inc." or properties.detectedProperties.manufacturer == "Nutanix" or properties.cloudMetadata.provider == "AWS" or properties.cloudMetadata.provider == "GCP", "Virtual", "Physical")
    | extend cores = properties.detectedProperties.coreCount, model = tostring(properties.detectedProperties.model), manufacturer = tostring(properties.detectedProperties.manufacturer)
    | project name,cores,isVirtual,agentVersion,ServerResourceGroupName=resourceGroup,ESUStatus,operatingSystem,model,manufacturer,Cloud

> **Remarque :** La requête mentionnée affichera tous les serveurs Windows 2012/R2 intégrés à Azure ARC qui n'ont pas encore reçu de licence ESU. Vous avez la possibilité d'ajuster la requête pour récupérer tous les serveurs Windows 2012/R2 et ensuite filtrer les résultats dans Excel, en ne conservant que les serveurs auxquels vous souhaitez attribuer des licences ESU. Bien que certaines des colonnes retournées puissent ne pas être utilisées par le script, elles peuvent être utiles pour le filtrage des résultats dans Excel. Assurez-vous de conserver les colonnes essentielles (comme spécifié dans le processus de création manuel mentionné précédemment) pour assurer le bon fonctionnement du script.

Assurez-vous toujours de faire un examen approfondi du contenu du fichier CSV avant son utilisation. Notez que dans de rares cas, la reqûete Azure Graph Explorer peut renvoyer une valeur 'NULL' pour les cœurs des machines analysées au lieu du nombre réel de cœurs. Si cela se produit, une intervention manuelle est nécessaire, vous obligeant à modifier le fichier CSV et à remplacer la valeur NULL par le nombre spécifique de cœurs relatifs au serveur.

Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./ManageESULicenses.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -location "EastUS" -state "Deactivated" -edition "Standard" -csvFilePath "C:\foldername\ESULicenses.csv" -licenseNamePrefix "ESU-" -licenseNameSuffix "-marketing" -token $authenticationToken -invoiceId "5555555" -programYear "Year 1"

où :

- subscriptionId est l'ID d'abonnement de l'abonnement Azure où se trouvent vos serveurs Azure ARC et où les licences ESU seront créées.
- tenantId est l'ID de locataire du locataire Microsoft Entra ID que vous souhaitez utiliser.
- appID est l'ID d'application du service principal que vous avez créé dans la section Prérequis.
- clientSecret est la clé secrète du service principal que vous avez créé dans la section Prérequis.
- licenseResourceGroupName est le nom du groupe de ressources qui contiendra les licences ESU.
- location est la Azure région où vos objets ARC sont déployés.
- state est l'état d'activation de la licence ESU. Il peut être "Activated" ou "Deactivated".
- edition est l'édition de la licence ESU. Il peut s'agir de "Standard" ou de "Datacenter".
- csvFilePath est le nom du fichier CSV qui contient les informations sur les licences ESU que vous voulez créer.
- licenseNamePrefix (facultatif) est le préfixe ajouté à la valeur `Name` de chaque ligne CSV pour créer le nom de licence.
- licenseNameSuffix (facultatif) est le suffixe ajouté à la valeur `Name` de chaque ligne CSV pour créer le nom de licence.
- token (facultatif) est un objet d'authentification Microsoft Entra ID valide disposant des droits nécessaires pour créer et attribuer des licences ESU. Il est prioritaire sur les paramètres du principal de service lorsque les deux méthodes sont fournies.
- invoiceId (facultatif) est le numéro de facture d'un droit de transition applicable acquis par le programme de licences en volume.
- programYear (facultatif) accepte `Year 1`, `Year 2` ou `Year 3` et indique l'année du programme ESU applicable.

**Remarque**: vous pouvez utiliser des paramètres facultatifs pour ajouter un préfixe et/ou un suffixe au nom de licence qui sera créée. Par exemple, si vous spécifiez « ESU- » comme préfixe et « -marketing » comme suffixe, le script créera des licences nommées « ESU-ServerName-marketing » pour chaque serveur dans le fichier CSV. Cela peut vous aider à différencier les licences appartenant à différents départements ou unités commerciales par exemple.

> **Remarque :** les options `-invoiceId` et `-programYear` permettent la transition d'un droit de licences en volume applicable vers les ESU activées par Azure Arc. Confirmez l'applicabilité du droit avant de les utiliser.

> **Remarque :** le paramètre `-token` permet d'utiliser un jeton à la place de `tenantId`, `appID` et `clientSecret`. Vous pouvez obtenir un objet de jeton valide avec `$authenticationToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/ -TenantId $tenantId`.

- licenseNamePrefix (facultatif) est le préfixe qui sera utilisé pour créer les licences ESU. Le script concaténera le préfixe avec le contenu du champ "Name" trouvé dans le fichier CSV pour créer le nom de la licence.
- licenseNameSuffix (facultatif) est le suffixe qui sera utilisé pour créer les licences ESU. Le script concaténera le suffixe avec le contenu du champ "Name" trouvé dans le CSV pour créer le nom de la licence.

**Remarque**: vous pouvez utiliser les paramètres facultatifs -log pour spécifier un chemin d'accès à un fichier journal.

## License

Ce projet est sous licence selon les termes de la licence MIT. Voir le [fichier LICENSE](LICENSE).
