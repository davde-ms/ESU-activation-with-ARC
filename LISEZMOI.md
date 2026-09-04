# Activation des ESU via Azure ARC

> English instructions can be found in the [README.md file](README.md).

## Introduction

Ce référentiel fournit deux procédures PowerShell 7 distinctes : les ressources de licences ESU Azure Arc pour Windows Server 2012, Windows Server 2012 R2 et Windows Server 2016; et les abonnements ESU SQL Server au niveau de l'hôte pour SQL Server 2014 et SQL Server 2016 activés par Azure Arc.

Un serveur éligible avec Azure Arc doit être lié à une licence ESU activée correspondant à sa version cible de Windows Server avant de pouvoir recevoir les ESU. Les opérations d'attribution, d'état, de dissociation et de suppression fonctionnent avec les licences des trois cibles; la création d'une licence exige la valeur cible exacte.

> Il est crucial de bien comprendre les procédures de licence appropriées et les exigences pour les serveurs pour lesquels vous souhaitez activer les ESU (Extended Security Updates) en utilisant Azure ARC. Il est impératif de générer le BON type de licence, tel que Standard ou Datacenter, mais aussi de bien choisir le type de cœurs (virtuels ou physiques). Ne pas le faire pourrait entraîner soit une facturation excessive, soit une non-conformité avec les réglementations de licence de Microsoft. En cas de doute, veuillez consulter votre spécialiste Microsoft Azure dédié ou votre responsable de compte Microsoft.

Ces informations et scripts sont fournis "tels quels" et ne sont pas destinés à se substituer à des conseils professionnels ou à une consultation, y compris, mais sans s'y limiter, des conseils juridiques. Je ne donne aucune garantie, expresse, implicite ou légale, quant aux informations contenues dans ce document ou ces scripts. Je n'accepte aucune responsabilité pour les dommages, directs ou indirects, découlant de l'utilisation des informations contenues dans ce document ou ces scripts.

Cela étant clarifié, allons-y !

## Choisir la procédure ESU appropriée

Les licences ESU Windows Server et les abonnements ESU SQL Server utilisent des ressources Azure, scripts, autorisations, règles d'éligibilité et modèles de facturation différents. N'utilisez pas les scripts Windows Server pour gérer les ESU SQL Server ni les scripts SQL Server pour gérer les licences ESU Windows Server.

| Procédure | Périmètre | Ressources modifiées |
| --- | --- | --- |
| ESU Windows Server | Windows Server 2012, 2012 R2 et 2016 | `Microsoft.HybridCompute/licenses` et profils de licence des machines |
| ESU SQL Server | SQL Server 2014 et 2016 sur des machines Windows déjà connectées à Azure Arc dans Azure commercial | Paramètres `Microsoft.HybridCompute/machines/extensions/WindowsAgent.SqlServer` de l'hôte |

La procédure SQL Server est réservée à Windows et n'installe, ne met à niveau ni ne répare l'agent Connected Machine. Elle ne gère pas les machines virtuelles Azure natives, Linux, les licences mutualisées `sqlServerEsuLicenses` par cœurs physiques, la virtualisation illimitée ni le déploiement automatique des correctifs. L'inscription ESU accorde un accès selon les conditions applicables; ces scripts ne déploient pas les correctifs ESU.

### Navigation ESU SQL Server

| Objectif | Guide | Modèle CSV | Rôle minimal |
| --- | --- | --- | --- |
| Évaluer les prérequis Arc, extension, inventaire et éligibilité | [TestSQLServerArcESUPrerequisites.ps1](docs/Français/sql/TestSQLServerArcESUPrerequisites.md) | Utilise le [modèle d'état à trois colonnes](samples/CheckSQLServerESUStatus.csv) | [SQL Server Arc ESU Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) |
| Installer l'extension Azure pour SQL Server lorsqu'elle est absente | [InstallSQLServerArcExtension.ps1](docs/Français/sql/InstallSQLServerArcExtension.md) | [Modèle d'installation](samples/InstallSQLServerArcExtension.csv) | [Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) sur l'abonnement + [Operator](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) sur le groupe de ressources cible |
| Vérifier sans modification les ESU, l'inventaire et les éléments de mesure | [CheckSQLServerESUStatus.ps1](docs/Français/sql/CheckSQLServerESUStatus.md) | [Modèle d'état](samples/CheckSQLServerESUStatus.csv) | [SQL Server Arc ESU Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) |
| Activer ou annuler un abonnement ESU SQL Server au niveau de l'hôte | [SetSQLServerESUSubscription.ps1](docs/Français/sql/SetSQLServerESUSubscription.md) | [Modèle de cycle de vie](samples/SetSQLServerESUSubscription.csv) | [Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) sur l'abonnement + [Operator](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) sur le groupe de ressources cible |

Commencez par l'évaluation des prérequis, installez l'extension uniquement si elle est absente, vérifiez l'état, puis utilisez `SetSQLServerESUSubscription.ps1 -DryRun` avant une activation ou annulation active. Le script de cycle de vie préserve les autres paramètres publics de l'extension au moyen d'une mise à jour GET-fusion-PUT. Sa voie `Disable` reste disponible lorsque les éléments d'inventaire sont dégradés afin de permettre l'annulation des frais futurs, tout en exigeant l'identité exacte de l'extension et des paramètres lisibles.

## Prérequis

Vous aurez besoin des éléments suivants pour commencer :

- Un locataire Microsoft Entra ainsi qu'un abonnement Azure actif.
- Des machines Windows Server 2012, Windows Server 2012 R2 ou Windows Server 2016 éligibles et déjà intégrées à Azure Arc. Utilisez l'agent Connected Machine version 1.34 ou ultérieure pour 2012/R2 et 1.62 ou ultérieure pour 2016. Consultez les [prérequis de l'agent Connected Machine](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prerequisites) et les [instructions de préparation des ESU](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prepare-extended-security-updates).
- Un ou plusieurs groupes de ressources Azure pour stocker les licences ESU qui seront créées avec ces scripts. Les licences ESU peuvent être situées dans le même abonnement que vos serveurs ARC ou dans un abonnement différent.
- Une Application d'Entreprise Microsoft Entra et un service principal actif qui seront utilisés pour l'authentification Azure. Veuillez vous référer au document [Créer un service principal Microsoft Entra](https://learn.microsoft.com/fr-fr/entra/identity-platform/howto-create-service-principal-portal) pour sa création.
- L'ID de l'application Microsoft Entra et la clé secrète pour le service principal créé ci-dessus.
- Une délégation de droits sur le groupe de ressources contenant les licences, ainsi qu'une délégation de droits sur les groupes de ressources contenant les serveurs ARC Azure. Veuillez consulter la rubrique [Déléguer l'accès aux ressources Azure](https://learn.microsoft.com/fr-fr/azure/role-based-access-control/role-assignments-steps) pour déléguer l'accès aux groupes de ressources si vous avez besoin d'aide. Les droits délégués requis seront documentés dans la section suivante.
- Un ordinateur avec Powershell 7.x ou une version ultérieure installée. Veuillez consulter la page [Installer PowerShell sur Windows](https://learn.microsoft.com/fr-fr/powershell/scripting/install/installing-powershell-on-windows) pour installer Powershell 7.x ou une version ultérieure. La version actuelle des scripts n'utilise pas le module AZ Powershell, mais il est recommandé de l'installer pour une utilisation future. Veuillez consulter la page [Installer Azure PowerShell sur Windows](https://learn.microsoft.com/fr-fr/powershell/azure/install-azps-windows) pour installer le module AZ Powershell si vous le souhaitez.

> **Note** : Les scripts AssignESULicense.ps1, CreateESULicense.ps1, DeleteESULicense.ps1, CheckESUStatus.ps1, ManageESUAssignments.ps1 et ManageESULicenses.ps1 prennent en charge un jeton utilisateur Microsoft Entra à la place d'un principal de service. L'utilisateur doit disposer des droits requis décrits dans la section suivante.

### Cibles prises en charge et éligibilité de Windows Server 2016

La création de licences accepte uniquement les valeurs `Target` exactes suivantes :

- `Windows Server 2012`
- `Windows Server 2012 R2`
- `Windows Server 2016`

Les ESU Windows Server 2016 activées par Azure Arc prennent en charge les éditions Standard et Datacenter. L'éligibilité générale exige une Software Assurance éligible dans le cadre d'un programme de licences en volume admissible ou un abonnement serveur équivalent. Pour les charges de travail Windows Server 2016 exécutées localement, la Software Assurance est obligatoire. Le programme SPLA n'est pas disponible pour les ESU Windows Server 2016 et la transition depuis les licences en volume au moyen de `InvoiceId` et `ProgramYear` n'est pas prise en charge.

Microsoft documente actuellement l'avantage Visual Studio dev/test et les étiquettes d'exception `WS2012 VISUAL STUDIO DEV TEST`, `WS2012 DISASTER RECOVERY` et `WS2012 MULTIPURPOSE` uniquement pour Windows Server 2012/R2. Aucun avantage Visual Studio dev/test équivalent ni protocole d'étiquettes d'exception Azure Arc n'est documenté pour Windows Server 2016. Ne réutilisez pas ces valeurs WS2012 pour 2016 et ne considérez aucune étiquette comme un contrôle d'éligibilité ou de facturation.

Les serveurs avec Azure Arc utilisés pour les ESU Windows Server 2012/R2 ou 2016 ne sont actuellement pas disponibles dans Azure géré par 21Vianet. Consultez les [instructions actuelles de préparation des ESU Windows Server](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prepare-extended-security-updates) avant l'inscription.

### Mises à jour du système d'exploitation et facturation

- Pour Windows Server 2012/R2, installez le package de licence et la mise à jour de la pile de maintenance (SSU) indiqués dans les instructions Microsoft. Pour Windows Server 2016, Microsoft demande actuellement d'installer tout package de licence et toute SSU requis selon l'article applicable de la Base de connaissances Windows Server 2016, mais ne nomme aucun KB précis. Suivez les [prérequis de dépannage ESU actuels](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/troubleshoot-extended-security-updates#esu-prerequisites); n'utilisez pas le KB Windows Server 2012 comme prérequis pour 2016.
- La fin du support de Windows Server 2016 est fixée au 12 janvier 2027. La facturation des ESU Windows Server 2016 activées par Azure Arc commence le 13 janvier 2027.
- Une licence activée est facturée selon ses cœurs provisionnés même si elle n'est liée à aucun serveur. Les clients doivent supprimer les licences activées non liées dont ils n'ont plus besoin.
- Une licence ou des cœurs supplémentaires provisionnés après la date de fin de support applicable peuvent être rétrofacturés jusqu'à cette date. Une inscription tardive, une activation ou réactivation, une suppression suivie d'une recréation, ainsi qu'un changement de région ou de locataire de la licence peuvent déclencher une rétrofacturation.
- La réduction du nombre de cœurs, la désactivation d'une licence ou sa suppression peuvent continuer à entraîner des frais pendant un maximum de cinq jours calendaires. La recréation n'évite pas les frais correspondant à cette période.

Confirmez les conditions actuelles dans les [informations officielles sur la facturation ESU](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/billing-extended-security-updates) avant toute opération ayant une incidence sur la facturation.

## Droits Azure requis pour exécuter les scripts

Les droits suivants doivent être délégués sur les groupes de ressources que vous prévoyez d'utiliser pour stocker les objets de licence ESU, ainsi que sur les groupes de ressources contenant les serveurs Azure ARC:

- "Microsoft.HybridCompute/licenses/read"
- "Microsoft.HybridCompute/licenses/write"
- "Microsoft.HybridCompute/licenses/delete"
- "Microsoft.HybridCompute/machines/licenseProfiles/read"
- "Microsoft.HybridCompute/machines/licenseProfiles/write"

Il y a une définition de rôle personnalisé située dans le dossier "Custom Roles" de ce référentiel qui peut être utilisée pour créer un rôle personnalisé avec les droits requis. Voir [Créer un rôle personnalisé à l'aide d'Azure PowerShell](https://learn.microsoft.com/fr-fr/azure/role-based-access-control/custom-roles-powershell#create-a-custom-role-with-json-template) pour créer un rôle personnalisé avec cette définition de rôle personnalisé.

Une fois que le rôle est créé, attribuez-le au service principal et appliquez-le à tous les groupes de ressources stockant les licences ou les objets de serveurs Azure ARC. Par exemple, si vous avez 3 groupes de ressources, un pour les licences et deux pour les serveurs Azure ARC, vous devrez attribuer le rôle personnalisé au service principal et l'appliquer à ces trois groupes de ressources. **Note importante** : Pour les scénarios inter-abonnements, assurez-vous que le service principal dispose des droits appropriés dans tous les abonnements concernés (abonnement des serveurs ARC et abonnement des licences ESU).

## Scripts ESU Windows Server

Les scripts suivants gèrent les ressources de licences ESU Windows Server et leurs attributions :

- [AssignESULicense.ps1](docs/Français/windows/AssignESULicense.md) (assigne une licence ESU à un serveur Azure ARC)
- [CreateESULicense.ps1](docs/Français/windows/CreateESULicense.md) (crée une licence ESU)
- [DeleteESULicense.ps1](docs/Français/windows/DeleteESULicense.md) (supprime une licence ESU)
- [CheckESUStatus.ps1](docs/Français/windows/CheckESUStatus.md) (vérifie l'état des licences ESU des serveurs avec Azure Arc)
- [ManageESUAssignments.ps1](docs/Français/windows/ManageESUAssignments.md) (assigne des licences ESU à de multiples serveurs Azure ARC, supporte les scénarios inter-abonnements)
- [ManageESULicenses.ps1](docs/Français/windows/ManageESULicenses.md) (crée, assigne et gère les licences ESU en bloc)

### Quel script dois-je utiliser ?

| Objectif | Script | Point de départ |
| --- | --- | --- |
| Vérifier l'état actuel des attributions ESU sans modification | `CheckESUStatus.ps1` | [Guide](docs/Français/windows/CheckESUStatus.md) et [modèle CSV](samples/CheckESUStatus.csv) |
| Créer ou mettre à jour une licence ESU 2012, 2012 R2 ou 2016 | `CreateESULicense.ps1` | Vérifiez le modèle de licence avant de choisir la cible, l'édition, le type de cœurs et leur nombre. |
| Attribuer ou dissocier une licence existante | `AssignESULicense.ps1` | Utilisez-le lorsque le serveur et la ressource de licence sont déjà connus. |
| Créer ou mettre à jour en bloc des licences à cibles mixtes, avec attribution ou dissociation facultative | `ManageESULicenses.ps1` | [Guide](docs/Français/windows/ManageESULicenses.md) et [modèle CSV](samples/ManageESULicenses.csv) |
| Attribuer ou dissocier des licences existantes en bloc, y compris entre abonnements | `ManageESUAssignments.ps1` | [Guide](docs/Français/windows/ManageESUAssignments.md) et [modèle CSV](samples/ManageESUAssignments.csv) |
| Supprimer une licence existante | `DeleteESULicense.ps1` | Lisez l'avertissement relatif à la suppression et à la facturation avant l'exécution. |

### Procédure client sécurisée

1. Exécutez d'abord `CheckESUStatus.ps1` pour inventorier les attributions actuelles. Ce script est en lecture seule.
2. Copiez le modèle approprié du dossier [`samples`](samples/) et remplacez toutes les valeurs fictives par des données client vérifiées.
3. Prévisualisez le plan avant toute modification. Utilisez `-DryRun` avec `ManageESUAssignments.ps1` ou `ManageESULicenses.ps1`; les deux scripts prennent également en charge `-WhatIf` et `-Confirm`.
4. Vérifiez chaque cible exacte, le mode de transition, la version minimale de l'agent, le nombre de cœurs normalisé, le choix de l'édition et du type de cœurs, le nom de licence généré et l'action d'attribution ou de dissociation affichés dans le plan et le récapitulatif.
5. Exécutez la même commande vérifiée sans `-DryRun` ni `-WhatIf` uniquement lorsque le plan est correct. Utilisez `-Confirm` pour demander une confirmation interactive pour chaque opération.

`ManageESULicenses.ps1` valide la totalité du fichier avant l'authentification ou toute requête Azure. Une seule ligne comportant une cible, une transition, une exception, une version d'agent, un nombre de cœurs, un nom ou une attribution non valide entraîne le rejet de tout le fichier. `ManageESUAssignments.ps1 -DryRun` valide le CSV et l'accès aux ressources au moyen de requêtes Azure `GET` en lecture seule; aucune requête de modification n'est envoyée. `ManageESULicenses.ps1 -DryRun` effectue tout le contrôle préalable et utilise des requêtes Azure `GET` en lecture seule pour compter les licences existantes et nouvelles; il ne crée, ne modifie, n'attribue, ne dissocie et ne supprime aucune ressource. `-WhatIf` empêche également toute modification tout en affichant les opérations proposées par PowerShell. Les deux modes de prévisualisation exigent toujours une authentification valide et peuvent effectuer les requêtes en lecture seule documentées.

## AssignESULicense.ps1

Ce script assignera une licence ESU au serveur ARC Azure spécifié. Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./Scripts/windows/AssignESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arservers" -ARCServerName "Win2012" -location "EastUS"

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

    ./Scripts/windows/CreateESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-exemple-esu" -licenseName "ESU-WS2016-App01" -location "EastUS" -state "Deactivated" -edition "Standard" -target "Windows Server 2016" -coreType "vCore" -coreCount 8 -WhatIf

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
- target est la version de Windows Server couverte par la licence. Il accepte exactement `Windows Server 2012`, `Windows Server 2012 R2` ou `Windows Server 2016` et utilise `Windows Server 2012` par défaut lorsqu'il est omis.
- coreType est le type e coeur à utiliser pour la licence ESU. Il peut s'agir de "vCore" (coeur virtuel) ou de "pCore" (coeur physique).
- coreCount est le nombre de cœurs associés à la licence ESU. Fournissez une valeur paire comprise entre 8 et 128 pour `vCore`, ou entre 16 et 256 pour `pCore`.

Le script rejette les nombres de cœurs impairs ou hors limites; il ne calcule ni ne normalise la valeur.

**Remarque :** Le script peut également être réexécuté avec les mêmes paramètres de base pour changer certaines des propriétés de la licence. Ces propriétés sont les suivantes :

- state (vous permet de créer une licence désactivée et de l'activer ultérieurement)
- coreCount (vous permet de modifier le nombre de cœurs de la licence si vous avez besoin de l'augmenter ou de le diminuer)

Tous les autres paramètres sont **immuables** et ne peuvent pas être modifiés une fois la licence créée.

Utilisez `-WhatIf` pour prévisualiser la création ou la modification d'une licence unique. Cette prévisualisation n'effectue aucune modification Azure.

## DeleteESULicense.ps1

Ce script supprimera une licence ESU. Lorsque vous supprimez une licence, elle est supprimée du serveur ARC Azure auquel elle a été affectée et arrête la facturation liée à cette licence.

> **La suppression ou la désactivation d'une licence peut rester facturée pendant un maximum de cinq jours calendaires. Si vous supprimez puis recréez une licence ESU, la rétrofacturation continue de s'appliquer à la période correspondante; la suppression ne vous exonère pas de ces frais. Vérifiez l'incidence actuelle dans les [informations officielles sur la facturation ESU](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates#billing-associated-with-modifications-to-an-azure-arc-esu-license) avant de continuer.**

Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./Scripts/windows/DeleteESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores"

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
./Scripts/windows/CheckESUStatus.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server"
```

Vous pouvez également fournir `-userToken`, traiter un fichier avec `-csvFilePath` et exporter les résultats avec `-exportCsvPath`. Le paramètre `-location` reste accepté pour assurer la compatibilité des commandes existantes, mais la requête d'état ne l'utilise pas. Consultez le [guide CheckESUStatus en français](docs/Français/windows/CheckESUStatus.md) pour les exemples détaillés.

## ManageESUAssignments.ps1

Ce script attribuera des licences ESU en masse, en extrayant les informations d'un fichier CSV. **Supporte désormais les scénarios inter-abonnements** où les licences ESU peuvent être situées dans des abonnements Azure différents de ceux des serveurs ARC.

> **L'objectif principal de ce script est de permettre l'attribution d'une licence à de nombreux serveurs Azure ARC. C'est très utile lorsque vous avez un grand nombre de serveurs Azure ARC auxquels vous devez attribuer une même licence.**

Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./Scripts/windows/ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"

**Pour les scénarios inter-abonnements**, vous pouvez optionnellement spécifier un abonnement différent pour les licences ESU :

    ./Scripts/windows/ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseSubscriptionId "00000000-0000-0000-0000-000000000004" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"

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

Ce script crée, attribue et gère en bloc les licences ESU Windows Server 2012, Windows Server 2012 R2 et Windows Server 2016 à partir d'un même fichier CSV.

> **Version de l'agent :** les lignes Windows Server 2012/R2 exigent l'agent Connected Machine 1.34 ou ultérieur; les lignes Windows Server 2016 exigent la version 1.62 ou ultérieure. Si une ligne est inférieure au minimum de sa cible, tout le CSV échoue à la validation avant l'authentification ou toute requête Azure.

La création du fichier CSV peut être effectuée de 2 manières :

### **Manuellement**:

(en fournissant les informations requises dans le fichier CSV).

Voici les colonnes qui doivent être présentes dans le fichier CSV :

- Nom : nom de la licence ESU qui sera créée (correspond généralement à un nom de serveur mais pas obligatoire si vous prévoyez d'utiliser des licences ESU pour couvrir plusieurs serveurs).
- Cores : nombre de cœurs de la machine virtuelle ou du serveur physique.
- IsVirtual : valeur qui indique si le serveur est virtuel ou non, soit **Virtual** pour les machines virtuelles ou **Physical** pour les serveurs physiques.

> **Remarque :** La colonne IsVirtual est seulement utilisée pour déterminer le type de noyau qui va être assigné à la licence. Vous utiliserez généralement presque toujours des licences vCore, sauf si vous couvrez des serveurs physiques.

- AgentVersion : version de l'agent ARC Azure installé sur le serveur. Ces informations peuvent être récupérées à partir du portail Azure ou en exécutant la requête [Azure Resource Graph Explorer](https://learn.microsoft.com/fr-fr/azure/governance/resource-graph/first-query-portal) mentionnée ci-dessous.
- Target (facultatif) : l'une des trois valeurs exactes `Windows Server 2012`, `Windows Server 2012 R2` ou `Windows Server 2016`. Une valeur de ligne non vide remplace `-target`; une valeur vide ou absente utilise `-target`, dont la valeur par défaut est `Windows Server 2012`.
- InvoiceId (facultatif) : ID de facture pour une transition de licences en volume Windows Server 2012/R2 applicable. Une valeur de ligne non vide remplace `-invoiceId`.
- ProgramYear (facultatif) : `Year 1`, `Year 2` ou `Year 3` pour une transition Windows Server 2012/R2 applicable. Une valeur de ligne non vide remplace `-programYear`. Une facture effective est obligatoire lorsqu'une année de programme est fournie explicitement.
- ServerResourceGroupName : nom du groupe de ressources qui contient le serveur ARC Azure auquel vous souhaitez assigner la licence ESU.
- AssignESULicense: lorsque la valeur est à **True**, la license sera automatiquement assignée au serveur ARC Azure. **False** désassociera la licence ESU du serveur ARC Azure. Enfin, si vous désirez créer une licence ESU sans l'assigner à un serveur ARC Azure, vous devez **omettre** une valeur pour la colonne AssignESULicense.

> **Note:** La colonne AssignESULicense est **optionelle** et n'est utile que quand/lorsque vous voulez gérer les attributions de licences via le fichier CSV. Notez qu'elle n'est PAS créée automatiquement lors de la génération du fichier CSV avec Azure Graph Explorer. Vous devrez donc l'ajouter **manuellement** si vous comptez gérer l'assignation des licenses lors de l'exécution de ce script.

- ESUException : texte facultatif copié dans l'étiquette `ESU Usage` de la ressource de licence. Établissez séparément l'éligibilité à tout scénario sans frais ou d'évaluation selon les conditions de licence Microsoft applicables avant d'utiliser ce champ.

Les lignes Windows Server 2016 rejettent toute valeur effective `InvoiceId` ou toute valeur `ProgramYear` explicite, ainsi que les valeurs d'exception WS2012 réservées. Pour un fichier à cibles mixtes qui applique une transition uniquement à certaines lignes 2012/R2, ne liez pas les paramètres de transition du lot et remplissez `InvoiceId` et `ProgramYear` uniquement sur ces lignes.

```csv
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException,Target,InvoiceId,ProgramYear
ws2012r2-app01,8,Virtual,1.62,rg-exemple-arc,True,,Windows Server 2012 R2,INV-EXEMPLE-001,Year 3
ws2016-app02,16,Physical,1.62,rg-exemple-arc,True,,Windows Server 2016,,
```

> **Avertissement de facturation :** les étiquettes n'établissent pas l'éligibilité et n'ont aucun effet sur la facturation. Microsoft indique que la facturation dépend du nombre de cœurs associé à la licence activée, quelles que soient les étiquettes. Ne provisionnez pas de cœurs pour les machines dont l'éligibilité à un scénario sans frais a été établie séparément. Consultez les [instructions officielles de provisionnement des licences](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/license-extended-security-updates).
> L'attribution en bloc de licences existantes est prise en charge par [ManageESUAssignments.ps1](docs/Français/windows/ManageESUAssignments.md).

Commencez avec le [modèle CSV ManageESULicenses](samples/ManageESULicenses.csv) prêt à copier.

Voici un example du format du fichier CSV:

![Exemple d'un fichier CSV type](media/ManageESULicenses_CSV_Example.jpg)

### **Automatiquement**

(en exécutant la requête suivante dans [Azure Resource Graph Explorer](https://learn.microsoft.com/fr-fr/azure/governance/resource-graph/first-query-portal) et en enregistrant les données ainsi produites dans un fichier CSV) :

```kusto
resources
| where type =~ 'microsoft.hybridcompute/machines'
| extend OperatingSystem = tostring(properties.osSku)
| extend Target = case(
    OperatingSystem has 'Windows Server 2012 R2', 'Windows Server 2012 R2',
    OperatingSystem has 'Windows Server 2012', 'Windows Server 2012',
    OperatingSystem has 'Windows Server 2016', 'Windows Server 2016',
    '')
| where isnotempty(Target)
| extend AgentVersion = tostring(properties.agentVersion)
| extend ESUStatus = tostring(properties.licenseProfile.esuProfile.licenseAssignmentState)
| extend Cloud = tostring(properties.cloudMetadata.provider)
| extend IsVirtual = iff(properties.detectedProperties.model == 'Virtual Machine' or properties.detectedProperties.manufacturer == 'VMware, Inc.' or properties.detectedProperties.manufacturer == 'Nutanix' or Cloud in~ ('AWS', 'GCP'), 'Virtual', 'Physical')
| extend Cores = toint(properties.detectedProperties.coreCount), Model = tostring(properties.detectedProperties.model), Manufacturer = tostring(properties.detectedProperties.manufacturer)
| project Name=name, Cores, IsVirtual, AgentVersion, ServerResourceGroupName=resourceGroup, AssignESULicense='', ESUException='', Target, InvoiceId='', ProgramYear='', ESUStatus, OperatingSystem, Model, Manufacturer, Cloud
```

La requête inclut Windows Server 2012, Windows Server 2012 R2 et Windows Server 2016 et produit les chaînes `Target` exactes acceptées par le script. Filtrez et vérifiez les lignes exportées avant de les utiliser. Vous pouvez conserver les colonnes d'inventaire supplémentaires pour l'analyse, mais conservez toutes les colonnes CSV obligatoires et les colonnes facultatives que vous comptez utiliser.

Vérifiez toujours `Cores` et `IsVirtual`. Azure Resource Graph peut renvoyer un nombre de cœurs nul ou incorrect, ou une classification physique/virtuelle incorrecte. Remplacez toute valeur nulle ou incorrecte par la valeur vérifiée de la machine avant d'exécuter le script; ne laissez jamais une valeur non vérifiée déterminer la facturation.

Voici la ligne de commande que vous devez utiliser pour l'exécuter :

    ./Scripts/windows/ManageESULicenses.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -licenseResourceGroupName "rg-exemple-esu" -location "EastUS" -state "Deactivated" -edition "Standard" -csvFilePath "C:\Exemples\CiblesMixtes.csv" -licenseNamePrefix "ESU-" -DryRun

où :

- subscriptionId est l'ID d'abonnement de l'abonnement Azure où se trouvent vos serveurs Azure ARC et où les licences ESU seront créées.
- tenantId est l'ID de locataire du locataire Microsoft Entra ID que vous souhaitez utiliser.
- appID est l'ID d'application du service principal que vous avez créé dans la section Prérequis.
- clientSecret est la clé secrète du service principal que vous avez créé dans la section Prérequis.
- licenseResourceGroupName est le nom du groupe de ressources qui contiendra les licences ESU.
- location est la Azure région où vos objets ARC sont déployés.
- state est l'état d'activation de la licence ESU. Il peut être "Activated" ou "Deactivated".
- edition est l'édition de la licence ESU. Il peut s'agir de "Standard" ou de "Datacenter".
- target (facultatif) définit la cible de secours du lot et accepte les trois valeurs cibles exactes. Sa valeur par défaut est `Windows Server 2012`; une valeur `Target` non vide dans une ligne est prioritaire.
- csvFilePath est le nom du fichier CSV qui contient les informations sur les licences ESU que vous voulez créer.
- licenseNamePrefix (facultatif) est le préfixe ajouté à la valeur `Name` de chaque ligne CSV pour créer le nom de licence.
- licenseNameSuffix (facultatif) est le suffixe ajouté à la valeur `Name` de chaque ligne CSV pour créer le nom de licence.
- token (facultatif) est un objet d'authentification Microsoft Entra ID valide disposant des droits nécessaires pour créer et attribuer des licences ESU. Il est prioritaire sur les paramètres du principal de service lorsque les deux méthodes sont fournies.
- invoiceId et programYear sont des valeurs de secours facultatives du lot, réservées aux lignes de transition de licences en volume Windows Server 2012/R2 applicables. Les valeurs de ligne non vides sont prioritaires. Ne liez pas ces paramètres pour un fichier mixte contenant Windows Server 2016, car les valeurs du lot s'appliqueraient aussi à ses lignes et entraîneraient l'échec de la validation de tout le fichier.
- DryRun valide tout le CSV, affiche le plan avec ses cibles et effectue uniquement les contrôles Azure en lecture seule documentés. `-WhatIf` empêche également les requêtes de création, de modification, d'attribution et de dissociation.

**Remarque**: vous pouvez utiliser des paramètres facultatifs pour ajouter un préfixe et/ou un suffixe au nom de licence qui sera créée. Par exemple, si vous spécifiez « ESU- » comme préfixe et « -marketing » comme suffixe, le script créera des licences nommées « ESU-ServerName-marketing » pour chaque serveur dans le fichier CSV. Cela peut vous aider à différencier les licences appartenant à différents départements ou unités commerciales par exemple.

> **Remarque :** `-invoiceId` et `-programYear` s'appliquent uniquement aux transitions de licences en volume Windows Server 2012/R2 éligibles. Windows Server 2016 ne prend pas en charge ce chemin de transition.

> **Remarque :** le paramètre `-token` permet d'utiliser un jeton à la place de `tenantId`, `appID` et `clientSecret`. Vous pouvez obtenir un objet de jeton valide avec `$authenticationToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/ -TenantId $tenantId`.

- licenseNamePrefix (facultatif) est le préfixe qui sera utilisé pour créer les licences ESU. Le script concaténera le préfixe avec le contenu du champ "Name" trouvé dans le fichier CSV pour créer le nom de la licence.
- licenseNameSuffix (facultatif) est le suffixe qui sera utilisé pour créer les licences ESU. Le script concaténera le suffixe avec le contenu du champ "Name" trouvé dans le CSV pour créer le nom de la licence.

**Remarque**: vous pouvez utiliser les paramètres facultatifs -log pour spécifier un chemin d'accès à un fichier journal.

## License

Ce projet est sous licence selon les termes de la licence MIT. Voir le [fichier LICENSE](LICENSE).
