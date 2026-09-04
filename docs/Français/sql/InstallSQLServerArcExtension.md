# InstallSQLServerArcExtension.ps1

## Objectif et périmètre

`InstallSQLServerArcExtension.ps1` installe `Microsoft.AzureData/WindowsAgent.SqlServer` sur une machine Windows Arc existante uniquement lorsque l'extension est absente. Il active la gestion SQL et les mises à niveau automatiques de l'extension, et définit `LicenseType` à `Paid`, `PAYG` ou `LicenseOnly`. Il ne met pas à jour, ne met pas à niveau, ne répare ni ne remplace une extension existante, n'active pas les ESU et ne déploie aucun correctif.

Cette procédure prend uniquement en charge Azure commercial et Windows sur des machines déjà connectées à Azure Arc. L'installation, la mise à niveau et la réparation de l'agent Connected Machine, les machines virtuelles Azure natives, Linux, les autres clouds, les versions autres que SQL Server 2014/2016 pour cette procédure ESU, les licences mutualisées par cœurs physiques, la virtualisation illimitée et le déploiement automatique des correctifs sont hors périmètre.

## Prérequis et limites

- PowerShell 7.x sous Windows; une machine Arc existante indiquant `Connected`, le mode `Full`, Windows et une région SQL Arc prise en charge.
- Les fournisseurs `Microsoft.HybridCompute` et `Microsoft.AzureArcData` inscrits. Le script ne les inscrit pas.
- Confirmation client des prérequis externes au moyen de `-ConfirmExternalPrerequisites` ou de la valeur CSV `TRUE`.
- Un `LicenseType` vérifié. `Paid` représente une licence admissible avec Software Assurance/abonnement, `PAYG` utilise la facturation à l'utilisation du logiciel SQL et `LicenseOnly` n'est pas admissible aux ESU SQL Server activées par Arc.

L'extension est une ressource d'hôte; ses paramètres s'appliquent aux instances SQL découvertes sur cet hôte. L'installation crée seulement : si l'extension attendue existe, le script renvoie `AlreadyInstalled` sans modifier les paramètres. Les modifications ultérieures utilisent [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md), qui lit les paramètres, fusionne uniquement les modifications ESU approuvées et réécrit les paramètres préservés.

## Rôle de moindre privilège

Créez les deux rôles personnalisés dans chaque abonnement cible. Attribuez [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) au niveau de l'abonnement pour lire les fournisseurs, l'inventaire, la machine et l'extension. Attribuez [SQL Server Arc ESU Operator](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) uniquement à chaque groupe de ressources de machines cible; il accorde seulement `Microsoft.HybridCompute/machines/extensions/write`. Cette séparation évite l'écriture des extensions dans tout l'abonnement. Aucun rôle n'accorde l'écriture/suppression de machine, l'inscription de fournisseur ni l'autorisation `sqlServerEsuLicenses`. Remplacez l'abonnement fictif avant de créer chaque rôle.

## Authentification

Utilisez exactement une méthode :

- `-userToken` : objet non expiré de `Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'`.
- Principal de service : `-tenantId`, `-appID` et `-clientSecret` ensemble.

Deux méthodes simultanées ou une méthode incomplète entraînent un échec. Ne stockez jamais d'informations d'identification dans le CSV.

## Paramètres

| Paramètre | Obligatoire | Description |
| --- | --- | --- |
| `subscriptionId` | Mode unique; valeur de secours facultative en CSV | Abonnement de la machine Arc. |
| `serverResourceGroupName`, `ARCServerName` | Mode unique | Cible existante. |
| `LicenseType` | Mode unique | Valeur exacte `Paid`, `PAYG` ou `LicenseOnly`. |
| `ConfirmExternalPrerequisites` | Mode unique | Doit être présent après confirmation des contrôles externes. |
| `csvFilePath` | Mode CSV | CSV existant avec le schéma exact ci-dessous. |
| `tenantId`, `appID`, `clientSecret` | Selon l'authentification | Méthode complète du principal de service. |
| `userToken` | Selon l'authentification | Méthode par jeton utilisateur. |
| `DryRun` | Non | Validation préalable complète en lecture seule; aucun PUT. Alias `Preview`. |
| `WhatIf`, `Confirm` | Non | Prévisualisation `ShouldProcess` ou confirmation à impact élevé. |

## Exemple avec une machine

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/InstallSQLServerArcExtension.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-exemple-arc' `
    -ARCServerName 'hote-sql-01' `
    -LicenseType Paid `
    -ConfirmExternalPrerequisites `
    -userToken $authenticationToken `
    -DryRun
```

Après vérification, retirez `-DryRun` et utilisez `-Confirm` pour l'installation active.

## Entrée CSV

Commencez par [InstallSQLServerArcExtension.csv](../../../samples/InstallSQLServerArcExtension.csv).

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,ConfirmExternalPrerequisites
11111111-1111-1111-1111-111111111111,rg-exemple-arc,hote-sql-01,Paid,TRUE
```

```powershell
./Scripts/sql/InstallSQLServerArcExtension.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\InstallSQLServerArcExtension.csv' `
    -userToken $authenticationToken `
    -DryRun
```

Les colonnes exactes obligatoires sont `SubscriptionId`, `ServerResourceGroupName`, `ARCServerName`, `LicenseType` et `ConfirmExternalPrerequisites`. Un abonnement vide utilise `-subscriptionId`. Les noms doivent respecter les caractères Azure pris en charge; le nom de machine comporte 1 à 54 caractères. `LicenseType` doit être `Paid`, `PAYG` ou `LicenseOnly`; la confirmation doit être `TRUE`. Les doublons sans distinction de casse sont rejetés. Un fichier absent/non CSV/sans données, une colonne manquante ou une ligne non valide rejette tout le plan avant l'authentification. Les colonnes inconnues sont signalées puis ignorées.

## Prévisualisation et sécurité d'exécution

`-DryRun` effectue toute la validation préalable de la machine, des fournisseurs, de la région et de l'extension, puis renvoie `Previewed` sans PUT. `-WhatIf` effectue la même validation et appelle `ShouldProcess` sans PUT. `-Confirm` demande une confirmation. Toutes les cibles sont contrôlées avant la première modification; un échec rend les autres lignes `NotStarted`. Une extension attendue existante n'est jamais modifiée.

Le PUT actif crée un objet de paramètres avec la gestion SQL et les mises à niveau automatiques activées, le type de licence vérifié et une liste d'exclusion vide. Il omet volontairement le paramètre ESU. Le script suit les opérations acceptées, puis relit et vérifie l'extension finale.

## Sortie et codes de sortie

Chaque résultat contient `RowNumber`, `SubscriptionId`, `ServerResourceGroupName`, `ARCServerName`, `LicenseType`, `Status`, `ProvisioningState` et `Message`.

Les états sont `Succeeded`, `AlreadyInstalled`, `Previewed`, `Declined`, `Failed` ou `NotStarted`. Le code `0` signifie que chaque ligne a réussi, était déjà installée ou a été prévisualisée. Le code `1` signale un échec de validation/authentification ou au moins une ligne en échec, refusée ou non démarrée. Une erreur active n'empêche pas le traitement des lignes indépendantes suivantes.

## Facturation et sécurité

L'installation de l'extension n'inscrit pas l'hôte aux ESU et ne déploie aucun correctif. Toutefois, `LicenseType` représente aussi la configuration de licence du logiciel SQL Server; faites vérifier `Paid`, `PAYG` ou `LicenseOnly` par le responsable des licences. L'inscription ESU est une opération distincte avec incidence sur la facturation. L'extension détecte le type d'hôte et les cœurs; ce script n'établit aucune couverture mutualisée ou de virtualisation illimitée.

## Résolution des problèmes

| Symptôme | Vérification |
| --- | --- |
| Échec de la confirmation | Définissez la confirmation à `TRUE` uniquement après les contrôles externes. |
| Échec de fournisseur/capacité | Inscrivez les fournisseurs séparément et vérifiez la prise en charge régionale de l'inventaire SQL Arc. |
| `AlreadyInstalled` | Succès idempotent; utilisez les outils pris en charge pour mettre à niveau ou réparer l'extension. |
| Conflit d'identité | Vérifiez le publisher/type existant; le script refuse de l'écraser. |
| Échec de vérification finale | Vérifiez le provisionnement, la mise à niveau automatique, la gestion SQL, la licence et que les ESU ne sont pas activées. |
| Code `1` en lot | Examinez `Failed`, `Declined` et `NotStarted`; distinguez l'échec de validation préalable de l'échec actif d'une ligne. |

## Références

- [ESU SQL Server activées par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configurer SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [API REST Hybrid Compute](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Rôles personnalisés Azure](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)
