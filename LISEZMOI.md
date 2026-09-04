# Activation des ESU avec Azure Arc

> English instructions are available in [README.md](README.md).

<a id="table-des-matieres"></a>
## Table des matières

- [Vue d'ensemble](#vue-densemble)
- [Choisir une procédure ESU](#choisir-une-procedure-esu)
- [Avant de commencer](#avant-de-commencer)
- [ESU Windows Server](#esu-windows-server)
- [ESU SQL Server](#esu-sql-server)
- [Exemples et documentation détaillée](#exemples-et-documentation-detaillee)
- [Contribution](#contribution)
- [Licence](#licence)

<a id="vue-densemble"></a>
## Vue d'ensemble

Ce référentiel fournit deux procédures PowerShell 7 distinctes pour les mises à jour de sécurité étendues (ESU) activées par Azure Arc :

- Les ressources de licences ESU Azure Arc pour Windows Server 2012, Windows Server 2012 R2 et Windows Server 2016.
- Les abonnements ESU SQL Server au niveau de l'hôte pour SQL Server 2014 et SQL Server 2016.

Les scripts utilisent directement les API REST Azure Resource Manager. Ils prennent en charge les opérations individuelles et en bloc, les contrôles d'état en lecture seule, les modes de prévisualisation pour les modifications prises en charge, ainsi que l'authentification par jeton utilisateur ou principal de service.

Ces scripts n'intègrent pas les machines à Azure Arc et ne déploient pas les correctifs ESU. Les machines doivent déjà être connectées à Azure Arc et satisfaire aux exigences de la procédure sélectionnée.

<a id="choisir-une-procedure-esu"></a>
## Choisir une procédure ESU

Les licences ESU Windows Server et les abonnements ESU SQL Server utilisent des ressources Azure, des autorisations, des règles d'éligibilité et des modèles de facturation différents. N'utilisez pas une procédure pour gérer l'autre.

| Procédure | Produits pris en charge | Ressource Azure modifiée | Point de départ |
| --- | --- | --- | --- |
| ESU Windows Server | Windows Server 2012, 2012 R2 et 2016 | `Microsoft.HybridCompute/licenses` et profils de licence des machines | [ESU Windows Server](#esu-windows-server) |
| ESU SQL Server | SQL Server 2014 et 2016 sur des machines Windows connectées à Azure Arc | Paramètres d'hôte de `Microsoft.HybridCompute/machines/extensions/WindowsAgent.SqlServer` | [ESU SQL Server](#esu-sql-server) |

<a id="avant-de-commencer"></a>
## Avant de commencer

### Prérequis communs

- Un locataire Microsoft Entra et un abonnement Azure actif.
- PowerShell 7.x ou une version ultérieure. Consultez [Installer PowerShell sur Windows](https://learn.microsoft.com/fr-fr/powershell/scripting/install/install-powershell-on-windows).
- Des machines cibles déjà connectées à Azure Arc. Consultez les [prérequis de l'agent Connected Machine](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prerequisites).
- Les autorisations Azure requises pour la procédure sélectionnée et pour chaque abonnement et groupe de ressources concerné.
- Un inventaire client, une éligibilité de licence et des informations de facturation vérifiés avant toute modification.

Les scripts n'exigent pas le module Az PowerShell lorsque l'authentification par principal de service est utilisée. L'authentification par jeton utilisateur exige un objet de jeton tel que celui renvoyé par `Get-AzAccessToken`.

<a id="prise-en-charge-des-environnements-azure"></a>
### Prise en charge des environnements Azure

Les scripts actuels ciblent Azure global. Ils utilisent le point de terminaison Azure Resource Manager global (`management.azure.com`) et le point de terminaison Microsoft Entra global (`login.microsoftonline.com`), et ils valident les URL des réponses ARM par rapport à l'hôte Azure global. Ils ne sont pas compatibles avec Azure Government dans leur état actuel.

Azure Government utilise des points de terminaison de gestion et d'authentification différents, et la disponibilité des fonctionnalités peut varier selon le cloud et la région. Microsoft documente actuellement SQL Server activé par Azure Arc dans la région US Government Virginia sous Windows avec un ensemble limité de fonctionnalités. Consultez [SQL Server activé par Azure Arc dans Azure Government](https://learn.microsoft.com/fr-fr/sql/sql-server/azure-arc/us-government-region?view=sql-server-ver17) pour connaître la disponibilité et les limitations actuelles.

La prise en charge d'Azure Government nécessiterait une configuration tenant compte du cloud pour les points de terminaison et l'audience des jetons, la validation des hôtes approuvés pour les réponses ARM Government, les points de terminaison régionaux propres à Government, ainsi qu'une validation distincte des API, fournisseurs, rôles et tests de régression. N'adaptez pas ces scripts en remplaçant simplement les URL sans effectuer cette validation.

### Options d'authentification

Utilisez l'une des méthodes d'authentification suivantes :

1. Transmettez un objet de jeton utilisateur avec `-userToken` :

   ```powershell
   $authenticationToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
   ```

2. Transmettez `-tenantId`, `-appID` et `-clientSecret` pour un principal de service Microsoft Entra.

L'identité authentifiée doit disposer des attributions de rôles requises dans tous les abonnements concernés. Ne placez jamais de véritables informations d'identification dans les fichiers CSV, l'historique des commandes, la documentation ou les journaux.

### Sécurité, licences et facturation

L'édition ESU, le type et le nombre de cœurs, la cible, l'état d'activation, l'année du programme, l'ID de facture et la gestion des exceptions peuvent avoir une incidence sur la facturation et la conformité. Vérifiez les conditions de licence Microsoft applicables avant d'utiliser ces scripts. Des choix incorrects peuvent entraîner des frais excessifs ou une non-conformité.

- Commencez par les scripts d'état en lecture seule.
- Utilisez `-DryRun` ou `-WhatIf` lorsque le script sélectionné le prend en charge, puis examinez le plan complet avant toute modification.
- Remplacez chaque valeur fictive des exemples par des données client vérifiées.
- Confirmez le résultat avec le script d'état en lecture seule correspondant.
- Ne supposez pas que l'activation de l'accès ESU installe les correctifs.

Les licences ESU Windows Server activées sont facturées selon les cœurs provisionnés, même lorsqu'elles ne sont pas attribuées. Une inscription tardive et certaines modifications de licence peuvent entraîner une rétrofacturation. La réduction du nombre de cœurs, la désactivation ou la suppression d'une licence peuvent rester facturables pendant un maximum de cinq jours calendaires. Confirmez les conditions actuelles dans les [informations officielles sur la facturation ESU Windows Server](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/billing-extended-security-updates).

Les informations et scripts de ce référentiel sont fournis tels quels et ne remplacent pas des conseils professionnels, juridiques ou relatifs aux licences.

<a id="esu-windows-server"></a>
## ESU Windows Server

### Périmètre et exigences

La création de licences accepte les valeurs `Target` exactes suivantes :

- `Windows Server 2012`
- `Windows Server 2012 R2`
- `Windows Server 2016`

Utilisez l'agent Connected Machine 1.34 ou ultérieur pour Windows Server 2012/R2 et 1.62 ou ultérieur pour Windows Server 2016. Consultez les [instructions actuelles de préparation des ESU Windows Server](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prepare-extended-security-updates) avant l'inscription.

Les ESU Windows Server 2016 activées par Azure Arc prennent en charge les éditions Standard et Datacenter. Le programme SPLA et les mécanismes `InvoiceId`, `ProgramYear`, Visual Studio dev/test et d'étiquettes d'exception de Windows Server 2012/R2 ne sont pas pris en charge pour Windows Server 2016. La fin du support de Windows Server 2016 est fixée au 12 janvier 2027 et la facturation ESU commence le 13 janvier 2027.

Les serveurs avec Azure Arc utilisés pour ces ESU ne sont actuellement pas pris en charge dans Azure géré par 21Vianet. Installez le package de licence et la mise à jour de la pile de maintenance applicables au système d'exploitation cible; ne réutilisez pas un package Windows Server 2012 comme prérequis Windows Server 2016.

### Autorisations requises

Le rôle personnalisé [ARC ESU License Administrator](Custom%20Roles/ARC%20ESU%20License%20Administrator.json) contient les actions requises sur les licences et les profils de licence des machines :

- `Microsoft.HybridCompute/licenses/read`
- `Microsoft.HybridCompute/licenses/write`
- `Microsoft.HybridCompute/licenses/delete`
- `Microsoft.HybridCompute/machines/licenseProfiles/read`
- `Microsoft.HybridCompute/machines/licenseProfiles/write`

Attribuez le rôle à chaque étendue contenant des licences ESU Windows Server ou des machines Azure Arc cibles. Les attributions inter-abonnements exigent un accès aux abonnements des machines et des licences.

### Procédure recommandée

1. Exécutez `CheckESUStatus.ps1` pour inventorier les attributions existantes sans effectuer de modification.
2. Choisissez le script de ressource unique ou en bloc correspondant à l'opération souhaitée.
3. Copiez le modèle CSV applicable et vérifiez la cible, l'édition, le type et le nombre de cœurs, la version de l'agent, les valeurs de transition et l'intention d'attribution.
4. Exécutez un mode de prévisualisation pris en charge et examinez le plan complet.
5. Exécutez la modification approuvée, puis vérifiez de nouveau l'état.

### Catalogue des scripts et guides

| Objectif | Guide | Modèle CSV ou point de départ |
| --- | --- | --- |
| Vérifier l'état des attributions sans modification | [CheckESUStatus.ps1](docs/Français/windows/CheckESUStatus.md) | [Modèle d'état](samples/CheckESUStatus.csv) |
| Créer ou mettre à jour une licence | [CreateESULicense.ps1](docs/Français/windows/CreateESULicense.md) | Vérifiez la cible, l'édition, le type et le nombre de cœurs et l'état dans le guide |
| Attribuer ou dissocier une licence existante | [AssignESULicense.ps1](docs/Français/windows/AssignESULicense.md) | Utilisez ce script lorsque les ressources du serveur et de la licence sont connues |
| Créer ou mettre à jour des licences en bloc, avec attribution facultative | [ManageESULicenses.ps1](docs/Français/windows/ManageESULicenses.md) | [Modèle de licences](samples/ManageESULicenses.csv) |
| Attribuer ou dissocier des licences existantes en bloc ou entre abonnements | [ManageESUAssignments.ps1](docs/Français/windows/ManageESUAssignments.md) | [Modèle d'attributions](samples/ManageESUAssignments.csv) |
| Supprimer une licence | [DeleteESULicense.ps1](docs/Français/windows/DeleteESULicense.md) | Consultez l'avertissement relatif à la suppression et à la facturation dans le guide |

Exemple de commande d'inventaire en lecture seule :

```powershell
./Scripts/windows/CheckESUStatus.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -serverResourceGroupName "rg-exemple-arc" -ARCServerName "serveur-01"
```

Exemple de prévisualisation en bloc :

```powershell
./Scripts/windows/ManageESULicenses.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -licenseResourceGroupName "rg-exemple-esu" -location "EastUS" -state "Deactivated" -edition "Standard" -csvFilePath ".\samples\ManageESULicenses.csv" -DryRun
```

<a id="esu-sql-server"></a>
## ESU SQL Server

### Périmètre et exclusions

Cette procédure prend en charge les instances SQL Server 2014 et SQL Server 2016 sur des machines Windows déjà connectées à Azure Arc, sous réserve de la limitation décrite dans la section [Prise en charge des environnements Azure](#prise-en-charge-des-environnements-azure). Elle utilise l'extension Azure pour SQL Server et les paramètres d'abonnement ESU au niveau de l'hôte.

Elle ne permet pas de :

- Installer, mettre à niveau ou réparer l'agent Connected Machine.
- Gérer les machines virtuelles Azure natives ou les machines Linux.
- Gérer les ressources mutualisées `sqlServerEsuLicenses` par cœurs physiques ou la virtualisation illimitée.
- Déterminer l'éligibilité de licence du client.
- Déployer automatiquement les correctifs ESU.

Exécutez l'évaluation des prérequis avant d'installer l'extension ou de modifier un abonnement. Elle distingue les éléments d'éligibilité, la disponibilité de l'extension, l'actualité de l'inventaire, la prise en charge régionale et les conditions bloquantes de la machine.

### Autorisations requises

Utilisez les rôles de moindre privilège fournis aux étendues suivantes :

| Rôle | Étendue | Objectif |
| --- | --- | --- |
| [SQL Server Arc ESU Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) | Abonnement | Lecture des fournisseurs, machines, extensions et inventaires SQL |
| [SQL Server Arc ESU Operator](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) | Groupe de ressources cible | Installation de l'extension SQL et mise à jour de ses paramètres publics |

Les opérations de prérequis et d'état en lecture seule exigent uniquement le rôle Reader. L'installation de l'extension et les modifications de l'abonnement ESU exigent le rôle Reader sur l'abonnement et le rôle Operator sur le groupe de ressources cible.

### Procédure recommandée

1. Exécutez `TestSQLServerArcESUPrerequisites.ps1` pour évaluer la machine, l'extension, l'inventaire, la région et les éléments relatifs aux instances SQL.
2. Exécutez `InstallSQLServerArcExtension.ps1` uniquement lorsque l'extension attendue est absente et que les prérequis externes sont confirmés.
3. Exécutez `CheckSQLServerESUStatus.ps1` pour relever l'état actuel de l'hôte et des instances.
4. Exécutez `SetSQLServerESUSubscription.ps1 -DryRun` et examinez l'activation ou l'annulation proposée.
5. Exécutez la modification approuvée, puis vérifiez de nouveau l'état.

Le script de cycle de vie préserve les autres paramètres publics de l'extension au moyen d'une mise à jour GET-fusion-PUT. Sa voie `Disable` reste disponible lorsque les éléments d'inventaire sont dégradés afin de permettre l'annulation des frais futurs, tout en exigeant l'identité attendue de l'extension et des paramètres lisibles.

### Catalogue des scripts et guides

| Objectif | Guide | Modèle CSV | Rôle minimal |
| --- | --- | --- | --- |
| Évaluer les prérequis et les éléments d'éligibilité | [TestSQLServerArcESUPrerequisites.ps1](docs/Français/sql/TestSQLServerArcESUPrerequisites.md) | [Modèle d'état](samples/CheckSQLServerESUStatus.csv) | Reader |
| Installer l'extension Azure pour SQL Server lorsqu'elle est absente | [InstallSQLServerArcExtension.ps1](docs/Français/sql/InstallSQLServerArcExtension.md) | [Modèle d'installation](samples/InstallSQLServerArcExtension.csv) | Reader + Operator |
| Vérifier sans modification les ESU, l'inventaire et les éléments de mesure | [CheckSQLServerESUStatus.ps1](docs/Français/sql/CheckSQLServerESUStatus.md) | [Modèle d'état](samples/CheckSQLServerESUStatus.csv) | Reader |
| Activer ou annuler un abonnement ESU au niveau de l'hôte | [SetSQLServerESUSubscription.ps1](docs/Français/sql/SetSQLServerESUSubscription.md) | [Modèle de cycle de vie](samples/SetSQLServerESUSubscription.csv) | Reader + Operator |

Exemple d'évaluation des prérequis en lecture seule :

```powershell
./Scripts/sql/TestSQLServerArcESUPrerequisites.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -serverResourceGroupName "rg-exemple-arc" -ARCServerName "serveur-sql-01"
```

Exemple de prévisualisation du cycle de vie :

```powershell
./Scripts/sql/SetSQLServerESUSubscription.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -serverResourceGroupName "rg-exemple-arc" -ARCServerName "serveur-sql-01" -Action Enable -LicenseType Paid -Environment Production -AcceptBackBilling -ConfirmExternalPrerequisites -DryRun
```

<a id="exemples-et-documentation-detaillee"></a>
## Exemples et documentation détaillée

Utilisez les guides maintenus pour consulter les définitions complètes des paramètres, les schémas CSV, les règles de validation, les champs de sortie, le comportement inter-abonnements et les exemples :

| Produit | Guides en anglais | Guides en français | Scripts | Exemples |
| --- | --- | --- | --- | --- |
| ESU Windows Server | [Documentation Windows en anglais](docs/English/windows/) | [Documentation Windows en français](docs/Français/windows/) | [Scripts Windows](Scripts/windows/) | [Fichiers d'exemple](samples/) |
| ESU SQL Server | [Documentation SQL en anglais](docs/English/sql/) | [Documentation SQL en français](docs/Français/sql/) | [Scripts SQL](Scripts/sql/) | [Fichiers d'exemple](samples/) |

<a id="contribution"></a>
## Contribution

Consultez [CONTRIBUTING.md](CONTRIBUTING.md) pour les exigences de développement, les commandes de validation et les instructions de contribution.

<a id="licence"></a>
## Licence

Ce projet est distribué sous licence MIT. Consultez le fichier [LICENSE](LICENSE).