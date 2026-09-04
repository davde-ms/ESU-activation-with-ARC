# CheckSQLServerESUStatus.ps1

## Objectif et périmètre

`CheckSQLServerESUStatus.ps1` signale la configuration de l'hôte, l'inventaire SQL Server 2014/2016, les éléments d'éligibilité et de mesure ainsi que l'état ESU SQL Server d'une ou plusieurs machines Windows activées par Azure Arc. Il utilise uniquement des requêtes GET Azure Resource Manager et n'inscrit, ne crée, ne met à jour ni ne supprime aucune ressource.

Il prend uniquement en charge les machines Windows déjà connectées à Azure Arc au moyen des points de terminaison Azure global. Dans son état actuel, le script n'est pas compatible avec les points de terminaison Azure Government. L'installation, la mise à niveau ou la réparation de l'agent Connected Machine, les machines virtuelles Azure natives, Linux, les autres clouds, les licences mutualisées par cœurs physiques et la virtualisation illimitée, ainsi que le déploiement automatique des correctifs sont hors périmètre. Le rapport d'état n'inscrit aucun hôte et n'installe aucune mise à jour.

## Prérequis et limites

- PowerShell 7.x sous Windows et une ressource de machine Arc existante.
- Accès en lecture à la machine, l'extension, l'inscription des fournisseurs et l'inventaire des instances SQL Arc à l'échelle de l'abonnement.
- Des fournisseurs inscrits et un inventaire récent améliorent la classification; le script signale les problèmes sans modifier Azure.

Le paramètre ESU s'applique à l'hôte : toutes les instances et tous les services associés éligibles de l'OSE sont concernés. Les instances d'une même version partagent un compteur hôte/version; SQL Server 2014 et 2016 peuvent produire chacun un compteur. La sortie est un élément de preuve, pas une décision de droit. `AutomaticPatchStatus` est distinct; l'inscription ne signifie pas que ce script a déployé des correctifs.

## Rôle de moindre privilège

Créez [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) dans chaque abonnement cible, puis attribuez-le à l'identité au niveau de l'abonnement. Ce niveau est requis, car l'état des fournisseurs et l'inventaire SQL Arc sont des ressources de niveau abonnement. Ses actions se limitent aux lectures de machine, extension, instance SQL Arc et état des fournisseurs.

## Authentification

Utilisez exactement une méthode : un objet `Get-AzAccessToken` non expiré avec `-userToken`, ou l'ensemble `-tenantId`, `-appID`, `-clientSecret`. Les deux méthodes simultanées sont rejetées. Les informations d'identification ne sont jamais des champs CSV.

## Paramètres

| Paramètre | Obligatoire | Description |
| --- | --- | --- |
| `subscriptionId` | Mode unique; valeur de secours facultative en CSV | Abonnement de la machine et de l'inventaire. |
| `serverResourceGroupName`, `ARCServerName` | Mode unique | Cible Arc existante. |
| `csvFilePath` | Mode CSV | CSV existant avec les trois colonnes exactes. |
| `tenantId`, `appID`, `clientSecret` | Selon l'authentification | Méthode complète du principal de service. |
| `userToken` | Selon l'authentification | Objet de jeton utilisateur. |
| `exportCsvPath` | Non | Exporte les résultats aplatis. |

## Exemple avec une machine

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/CheckSQLServerESUStatus.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-exemple-arc' `
    -ARCServerName 'hote-sql-01' `
    -userToken $authenticationToken
```

## Entrée CSV

Commencez par [CheckSQLServerESUStatus.csv](../../../samples/CheckSQLServerESUStatus.csv).

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName
11111111-1111-1111-1111-111111111111,rg-exemple-arc,hote-sql-01
```

```powershell
./Scripts/sql/CheckSQLServerESUStatus.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\CheckSQLServerESUStatus.csv' `
    -userToken $authenticationToken `
    -exportCsvPath '.\etat-esu-sql.csv'
```

Les colonnes exactes obligatoires sont `SubscriptionId`, `ServerResourceGroupName` et `ARCServerName`. Un abonnement vide utilise celui de la commande. Toutes les lignes sont validées avant l'authentification; un fichier absent/non CSV/vide, une colonne manquante, un GUID ou nom non valide, ou une cible en double entraîne le rejet. Les colonnes sans rapport sont signalées puis ignorées.

## Comportement en lecture seule

Il n'existe ni `-DryRun` ni `-WhatIf`, car tous les appels Azure sont des GET. Le script valide la pagination ARM, la limite à 100 pages, réessaie les lectures transitoires, met en cache les lectures par abonnement et corrèle les instances par `containerResourceId` normalisé.

## Sortie et codes de sortie

Les champs sont : `SubscriptionId`, `ResourceGroupName`, `MachineName`, `MachineResourceId`, `Evaluated`, `MachineExists`, `ConnectionStatus`, `AgentMode`, `OperatingSystem`, `NativeAzureExcluded`, `Location`, `HybridComputeRegistered`, `AzureArcDataRegistered`, `ExtensionInstalled`, `ExtensionPublisher`, `ExtensionType`, `ExtensionProvisioningState`, `ExtensionVersion`, `ExtensionVersionSupport`, `AutomaticUpgradeEnabled`, `LicenseType`, `SqlManagementEnabled`, `ESUEnabled`, `ESURawValue`, `ESULastUpdatedTimestamp`, `Instances`, `EligibleInstances`, `IneligibleInstances`, `UncertainInstances`, `EligibleVersions`, `Editions`, `Environments`, `MixedEligibleVersions`, `HostType`, `HostTypes`, `HostTypeEvidenceStatus`, `DetectedCores`, `DetectedCoreValues`, `DetectedCoresEvidenceStatus`, `MeteringEvidenceStatus`, `InventoryFreshness`, `UsageFreshness`, `AutomaticPatchStatus`, `PassiveDRState`, `Classification`, `Reasons` et `Warnings`.

`Classification` vaut `Healthy`, `Warning`, `NotEnabled`, `Unknown` ou `Error`. `Healthy` indique que les données observées satisfont les contrôles, sans prouver le droit de licence ni l'installation des correctifs. Le code `0` signifie que toutes les cibles ont été évaluées, y compris avec avertissement ou désactivation. Le code `1` signale un échec d'entrée/authentification/exportation ou une cible avec `Evaluated=False`. Les autres cibles valides continuent après un échec.

## Facturation et sécurité

Le script ne modifie rien. Vérifiez `HostTypes`, les cœurs, la version, l'édition, l'environnement, l'état passif/DR et l'actualisation avant toute décision de facturation. Les règles Microsoft actuelles peuvent appliquer un minimum de quatre cœurs, des compteurs distincts pour 2014 et 2016 et une rétrofacturation annuelle. Les éléments absents ou contradictoires restent volontairement incertains. Les licences mutualisées par cœurs physiques sont hors périmètre.

## Résolution des problèmes

| Symptôme | Vérification |
| --- | --- |
| `NotEnabled` | Vérifiez l'existence de l'extension et une valeur vraie reconnue pour `enableExtendedSecurityUpdates`. |
| `Warning` | Examinez les avertissements de fournisseur, connexion, version, licence, actualisation et mesure. |
| `Unknown` | Vérifiez l'inventaire éligible et les valeurs ESU/inventaire absentes ou non reconnues. |
| `Error` | Vérifiez le système d'exploitation, Azure natif, l'identité/état de l'extension et les requêtes. |
| Mesure incertaine | Comparez tous les `HostTypes` et `DetectedCoreValues`; n'utilisez pas une valeur inférée pour facturer. |
| ESU activées sans correctifs | L'inscription et le déploiement sont distincts. Vérifiez les mises à jour automatiques ou le téléchargement manuel documenté. |

## Références

- [ESU SQL Server activées par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configurer SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [API REST Hybrid Compute](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Rôles personnalisés Azure](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)
