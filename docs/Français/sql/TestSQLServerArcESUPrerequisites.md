# TestSQLServerArcESUPrerequisites.ps1

## Objectif et périmètre

`TestSQLServerArcESUPrerequisites.ps1` effectue une évaluation Azure Resource Manager en lecture seule avant l'installation de l'extension Azure pour SQL Server ou l'inscription aux ESU SQL Server. Il vérifie la machine Arc, l'inscription des fournisseurs, `WindowsAgent.SqlServer`, l'inventaire SQL Arc corrélé, les éléments d'éligibilité SQL Server 2014/2016 et l'actualisation de l'inventaire. Il n'inscrit aucun fournisseur et ne crée, ne met à jour ni ne supprime aucune ressource.

Cette procédure concerne uniquement les machines Windows déjà connectées à Azure Arc dans Azure commercial. L'installation, la mise à niveau et la réparation de l'agent Connected Machine sont hors périmètre. Les machines virtuelles Azure natives, Linux, Azure Government et les autres clouds, les versions SQL autres que 2014/2016, les licences ESU mutualisées par cœurs physiques, la virtualisation illimitée et le déploiement automatique des correctifs sont hors périmètre.

## Prérequis et limites

- PowerShell 7.x sous Windows et accès réseau aux points de terminaison Azure commercial.
- Une machine Arc existante indiquant `Connected`, le mode d'agent `Full`, Windows, une région prise en charge pour `Microsoft.AzureArcData/sqlServerInstances` et un fournisseur cloud autre qu'Azure.
- Les fournisseurs `Microsoft.HybridCompute` et `Microsoft.AzureArcData` inscrits. Le script signale une inscription manquante, mais ne l'effectue pas.
- Pour que l'activation des ESU soit prête : extension `WindowsAgent.SqlServer` saine et prise en charge, `SqlManagement.IsEnabled=true`, `LicenseType` égal à `Paid` ou `PAYG`, et au moins une instance SQL Server 2014/2016 Standard ou Enterprise.
- Confirmez séparément la connectivité sortante, les autorisations Windows et SQL locales, les droits et la couverture des années précédentes, l'éligibilité Developer hors production et la conformité HA/DR. L'inventaire ARM ne peut pas les prouver.

Le paramètre ESU s'applique à l'hôte et concerne les instances et services associés éligibles de l'environnement du système d'exploitation. Plusieurs versions éligibles sur un hôte peuvent produire des compteurs distincts. L'évaluation n'inscrit pas l'hôte et ne déploie aucun correctif.

## Rôle de moindre privilège

Créez [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) dans chaque abonnement cible, puis attribuez-le à l'identité au niveau de l'abonnement. Ce niveau est requis, car l'état des fournisseurs et l'inventaire SQL Arc sont des ressources de niveau abonnement. Le rôle accorde uniquement la lecture de la machine, de l'extension, des instances SQL Arc et de l'état des fournisseurs. Remplacez l'abonnement fictif du modèle avant de créer le rôle.

## Authentification

Utilisez une méthode :

- Jeton utilisateur : transmettez à `-userToken` (alias `-token`) un objet non expiré renvoyé par `Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'`. Il doit contenir `Token` et une valeur `ExpiresOn` future.
- Principal de service : transmettez ensemble `-tenantId`, `-appID` et `-clientSecret`.

Lorsque `-userToken` est fourni, ce script l'utilise. Ne placez jamais de jeton ou secret dans un CSV, une sortie ou le contrôle de code source.

## Paramètres

| Paramètre | Obligatoire | Description |
| --- | --- | --- |
| `subscriptionId` | Oui | Abonnement par défaut et abonnement de la cible unique. Doit être un GUID. |
| `serverResourceGroupName` | Mode unique | Groupe de ressources, 1 à 90 caractères pris en charge, sans point final. |
| `ARCServerName` | Mode unique | Nom de machine Arc, 1 à 54 caractères pris en charge, sans point final. |
| `csvFilePath` | Mode CSV | Fichier `.csv` existant; incompatible avec les paramètres de machine unique. |
| `tenantId`, `appID`, `clientSecret` | Selon l'authentification | Ensemble complet du principal de service; les ID sont des GUID. |
| `userToken` | Selon l'authentification | Objet renvoyé par `Get-AzAccessToken`. |
| `exportCsvPath` | Non | Exporte les résultats aplatis au format CSV. |

## Exemple avec une machine

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/TestSQLServerArcESUPrerequisites.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-exemple-arc' `
    -ARCServerName 'hote-sql-01' `
    -userToken $authenticationToken
```

Pour un principal de service, remplacez `-userToken` par des valeurs fictives ou fournies de manière sécurisée pour `-tenantId`, `-appID` et `-clientSecret`.

## Entrée CSV

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName
11111111-1111-1111-1111-111111111111,rg-exemple-arc,hote-sql-01
```

```powershell
./Scripts/sql/TestSQLServerArcESUPrerequisites.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\CheckSQLServerESUStatus.csv' `
    -userToken $authenticationToken `
    -exportCsvPath '.\resultats-prerequis.csv'
```

Les colonnes exactes obligatoires sont `SubscriptionId`, `ServerResourceGroupName` et `ARCServerName`. Un abonnement de ligne vide utilise celui de la commande. Toutes les lignes sont validées avant l'authentification; les GUID ou noms non valides, colonnes manquantes, fichiers sans données et cibles en double sans distinction de casse entraînent le rejet de tout le fichier. Utilisez la même structure que le [modèle d'état](../../../samples/CheckSQLServerESUStatus.csv).

## Comportement en lecture seule

Le script ne propose ni `-DryRun` ni `-WhatIf`, car ses opérations Azure sont déjà exclusivement des requêtes GET. Il valide toute l'entrée avant l'authentification, suit uniquement les liens de pagination approuvés sur `https://management.azure.com` et corrèle les instances SQL par `containerResourceId`.

## Sortie et codes de sortie

Chaque résultat contient : `SubscriptionId`, `ResourceGroupName`, `MachineName`, `MachineResourceId`, `MachineExists`, `ConnectionStatus`, `AgentMode`, `OperatingSystem`, `Location`, `HybridComputeRegistered`, `AzureArcDataRegistered`, `RegionSupported`, `ExtensionState`, `ExtensionVersion`, `ExtensionSupported`, `AutomaticUpgradeEnabled`, `LicenseType`, `SqlManagementEnabled`, `ESUEnabled`, `ESULastUpdatedTimestamp`, `EligibleInstances`, `IneligibleInstances`, `MixedEligibleVersions`, `HostType`, `DetectedCores`, `InventoryFreshness`, `UsageFreshness`, `BlockingIssues`, `Warnings`, `ExternalChecks`, `ReadyForExtensionInstall` et `ReadyForESUEnablement`.

`ReadyForExtensionInstall` vaut vrai seulement si les contrôles de base réussissent et si l'extension est absente. `ReadyForESUEnablement` exige aussi l'extension prise en charge et un inventaire éligible. Des horodatages anciens ou absents constituent des avertissements et ne bloquent pas à eux seuls l'état prêt.

Le code `0` signifie que l'entrée et l'authentification ont abouti et qu'aucune cible n'était absente ou en échec d'évaluation. Le code `1` indique un échec d'entrée, d'authentification, d'exportation, une machine absente ou une requête d'évaluation en échec. Des obstacles d'éligibilité peuvent être renvoyés avec le code `0`; examinez les champs d'état prêt et les problèmes.

## Facturation et sécurité

Cette évaluation ne crée aucun abonnement ni frais. Les résultats sont des éléments de preuve, pas une preuve de droit de licence. Selon les conditions Microsoft actuelles, l'inscription ESU SQL Server est facturée par hôte/OSE et par version, avec un minimum de quatre cœurs et une rétrofacturation possible pour l'année en cours. Vérifiez le type d'hôte, les cœurs, l'édition, la version, l'état passif et la couverture antérieure avant l'activation. Les licences mutualisées par cœurs physiques et la virtualisation illimitée ne sont pas gérées ici.

## Résolution des problèmes

| Symptôme | Vérification |
| --- | --- |
| `ReadyForExtensionInstall=False` | Vérifiez les fournisseurs, la connexion, le mode Full, Windows, l'exclusion Azure native, la région et la présence de l'extension. |
| `ReadyForESUEnablement=False` | Vérifiez `BlockingIssues`, l'identité/version/état de l'extension, la gestion SQL, le type de licence et l'inventaire éligible. |
| Actualisation `Stale` ou `Unknown` | Actualisez l'inventaire SQL et examinez la connectivité de l'extension; l'avertissement rend les éléments incertains. |
| Édition Developer incertaine | Confirmez la couverture hors production admissible en dehors d'ARM. |
| Code de sortie `1` | Vérifiez d'abord l'entrée et l'authentification, puis les détails de machine absente ou `Assessment failed` et l'accès au chemin d'exportation. |

## Références

- [ESU SQL Server activées par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configurer SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [API REST Hybrid Compute](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Rôles personnalisés Azure](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)
