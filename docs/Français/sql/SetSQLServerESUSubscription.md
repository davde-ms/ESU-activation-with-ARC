# SetSQLServerESUSubscription.ps1

## Objectif et périmètre

`SetSQLServerESUSubscription.ps1` active ou désactive le paramètre ESU SQL Server au niveau de l'hôte sur une extension `WindowsAgent.SqlServer` existante. Il prend en charge les points de terminaison Azure global et les machines Windows déjà connectées à Azure Arc; dans son état actuel, il n'est pas compatible avec les points de terminaison Azure Government. Il n'installe, ne met à niveau ni ne répare l'agent Connected Machine ou l'extension SQL; ne gère pas les machines virtuelles Azure natives ou Linux; ne déploie aucun correctif; ne configure pas l'application automatique des correctifs; n'accepte pas de nombre de cœurs saisi par le client; et ne gère pas les licences ESU mutualisées par cœurs physiques ou la virtualisation illimitée.

Seuls SQL Server 2014 et 2016 sont pris en charge. L'activation exige un inventaire éligible et des confirmations explicites de facturation. La désactivation reste possible lorsque les éléments d'inventaire/fournisseur/machine sont dégradés afin que le client puisse annuler les frais futurs; elle exige toujours une extension lisible avec l'identité exacte et des paramètres publics.

## Prérequis et limites

- PowerShell 7.x sous Windows; fournisseurs inscrits; machine Arc existante connectée en mode `Full` et extension `WindowsAgent.SqlServer` saine et prise en charge pour l'activation.
- `SqlManagement.IsEnabled=true`, `LicenseType` effectif `Paid` ou `PAYG` et inventaire SQL Server 2014/2016. Standard/Enterprise sont des éditions de production; Developer exige une couverture hors production admissible confirmée.
- Les droits, la couverture antérieure, les autorisations locales, la connectivité et la conformité HA/DR doivent être confirmés hors ARM.

Le paramètre concerne tout l'hôte/OSE, pas une instance nommée. Toutes les instances et tous les services associés éligibles peuvent être affectés, et 2014/2016 peuvent être mesurés séparément. Le script effectue un GET-fusion-PUT préservant les paramètres : il lit l'extension, copie profondément les paramètres publics, modifie uniquement `enableExtendedSecurityUpdates`, `esuLastUpdatedTimestamp` et un `LicenseType` explicitement approuvé lors de l'activation, puis écrit et vérifie la préservation sémantique. Les propriétés protégées ou de réponse ne sont jamais copiées.

Pour `Disable`, le script lit volontairement uniquement l'extension attendue et ignore les contrôles de machine, fournisseur et inventaire SQL. Cette voie d'annulation reste disponible lorsque la découverte ou l'état de santé sont dégradés, car exiger une découverte saine pourrait empêcher l'arrêt des frais ESU futurs. Une mauvaise identité d'extension ou des paramètres publics illisibles bloque toujours la modification.

## Rôle de moindre privilège

Créez les deux rôles personnalisés dans chaque abonnement cible. Attribuez [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) au niveau de l'abonnement pour lire les fournisseurs, l'inventaire, la machine et l'extension. Attribuez [SQL Server Arc ESU Operator](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) uniquement à chaque groupe de ressources de machines cible; il accorde seulement l'écriture d'extension. Cette séparation évite l'écriture des extensions dans tout l'abonnement. Aucun rôle n'accorde l'écriture/suppression de machine, l'inscription de fournisseur ni l'autorisation `sqlServerEsuLicenses`.

## Authentification

Utilisez exactement une méthode : `-userToken` avec un objet `Get-AzAccessToken` non expiré, ou l'ensemble complet `-tenantId`, `-appID`, `-clientSecret`. Les deux méthodes ou un ensemble incomplet échouent. Conservez les secrets hors des CSV et journaux.

## Paramètres

| Paramètre | Obligatoire | Description |
| --- | --- | --- |
| `subscriptionId` | Mode unique; secours CSV facultatif | Abonnement de la machine Arc. |
| `serverResourceGroupName`, `ARCServerName` | Mode unique | Hôte cible existant. |
| `Action` | Mode unique | `Enable` ou `Disable`. |
| `LicenseType` | Activation uniquement, facultatif | Vide conserve la valeur; sinon `Paid` ou `PAYG`. |
| `Environment` | Activation uniquement | `Production` ou `NonProduction`. |
| `AcceptBackBilling` | Activation uniquement | Confirmation obligatoire. |
| `AcceptLicenseTypeChange` | Si la licence change | Approuve explicitement la modification. |
| `ConfirmNonProductionCoverage` | Lorsque nécessaire | Obligatoire pour Developer en `NonProduction`. |
| `ConfirmExternalPrerequisites` | Activation uniquement | Confirmation des contrôles externes. |
| `csvFilePath` | Mode CSV | Schéma exact ci-dessous. |
| `tenantId`, `appID`, `clientSecret`; `userToken` | Selon l'authentification | Choisissez une méthode. |
| `DryRun` | Non | Validation et aperçu de facturation en lecture seule; aucun PUT. Alias `Preview`. |
| `WhatIf`, `Confirm` | Non | Contrôles `ShouldProcess` à impact élevé. |

## Exemple avec une machine

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/SetSQLServerESUSubscription.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-exemple-arc' `
    -ARCServerName 'hote-sql-01' `
    -Action Enable `
    -Environment Production `
    -AcceptBackBilling `
    -ConfirmExternalPrerequisites `
    -userToken $authenticationToken `
    -DryRun
```

L'annulation ne contient aucune valeur réservée à l'activation :

```powershell
./Scripts/sql/SetSQLServerESUSubscription.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-exemple-arc' `
    -ARCServerName 'hote-sql-01' `
    -Action Disable `
    -userToken $authenticationToken `
    -WhatIf
```

## Entrée CSV

Commencez par [SetSQLServerESUSubscription.csv](../../../samples/SetSQLServerESUSubscription.csv).

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName,Action,LicenseType,Environment,AcceptBackBilling,AcceptLicenseTypeChange,ConfirmNonProductionCoverage,ConfirmExternalPrerequisites
11111111-1111-1111-1111-111111111111,rg-exemple-arc,hote-sql-01,Enable,,Production,TRUE,FALSE,FALSE,TRUE
11111111-1111-1111-1111-111111111111,rg-exemple-arc,hote-sql-02,Disable,,,,,,
```

```powershell
./Scripts/sql/SetSQLServerESUSubscription.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\SetSQLServerESUSubscription.csv' `
    -userToken $authenticationToken `
    -DryRun
```

Les dix colonnes affichées sont obligatoires. Un abonnement vide utilise celui de la commande. Les contrôles booléens acceptent uniquement `TRUE`, `FALSE` ou vide lorsque cela est permis. `Enable` exige un environnement valide, `AcceptBackBilling=TRUE` et `ConfirmExternalPrerequisites=TRUE`; un changement de licence exige `AcceptLicenseTypeChange=TRUE`; Developer hors production exige `ConfirmNonProductionCoverage=TRUE`. `Disable` exige que tous les champs d'activation soient vides. Les hôtes en double/contradictoires sont rejetés. Une colonne inconnue ressemblant à un contrôle de facturation est rejetée; une colonne sans rapport est signalée puis ignorée. Toute erreur locale rejette tout le fichier avant l'authentification.

## Prévisualisation et sécurité d'exécution

`-DryRun` effectue la validation préalable, affiche les éléments exacts d'hôte/licence/version/cœurs/facturation et n'envoie aucun PUT. `-WhatIf` ajoute la prévisualisation `ShouldProcess`; `-Confirm` demande une confirmation. Tous les contrôles Azure se terminent avant la première modification. Un échec rend les lignes valides `NotStarted`; après le début des modifications, les lignes indépendantes continuent malgré un échec actif.

Un état déjà conforme renvoie `AlreadyCompliant` sans PUT ni modification d'horodatage. Les opérations actives réessaient les réponses transitoires, n'acceptent que les URL de suivi approuvées et relisent jusqu'à vérifier l'état, l'horodatage, la licence et les paramètres non liés.

## Sortie et codes de sortie

Chaque résultat contient `RowNumber`, `SubscriptionId`, `ResourceGroupName`, `MachineName`, `MachineResourceId`, `RequestedAction`, `PreviousState`, `DesiredState`, `EffectiveState`, `PreviousLicenseType`, `DesiredLicenseType`, `EffectiveLicenseType`, `HostType`, `DetectedCores`, `InstanceNames`, `ServiceTypes`, `EligibleVersions`, `InventoryFreshness`, `UsageFreshness`, `OperationStatus`, `VerificationSucceeded` et `Message`.

`OperationStatus` vaut `Succeeded`, `AlreadyCompliant`, `Previewed`, `Declined`, `Failed` ou `NotStarted`. Le code `0` signifie que chaque ligne a réussi, était déjà conforme ou a été prévisualisée. Le code `1` indique un échec de validation/authentification ou une ligne en échec, refusée ou non démarrée.

## Facturation et sécurité

L'activation peut entraîner une rétrofacturation pour l'année en cours : Microsoft indique le 10 juillet 2024 comme début de la première année ESU SQL Server 2014 et le 14 juillet 2026 pour SQL Server 2016. Une réactivation/reconnexion peut aussi être rétrofacturée. L'utilisation de l'hôte comporte un minimum de quatre cœurs et chaque version éligible peut avoir son propre compteur. `AcceptBackBilling` enregistre une confirmation; il n'établit aucun droit.

Selon les instructions Microsoft actuelles, l'annulation arrête les frais ESU futurs, mais supprime l'accès aux futures mises à jour; une réactivation ultérieure peut être rétrofacturée. Le script ne déploie aucun correctif ESU et n'active pas l'application automatique des correctifs. Les licences mutualisées par cœurs physiques et la virtualisation illimitée sont des modèles distincts et ne sont pas modifiés.

## Résolution des problèmes

| Symptôme | Vérification |
| --- | --- |
| Erreur de confirmation | Fournissez les valeurs `TRUE` uniquement après vérification des licences et prérequis externes. |
| Changement de licence rejeté | Ajoutez `AcceptLicenseTypeChange=TRUE` uniquement après approbation des valeurs affichées. |
| Developer rejeté | Utilisez `NonProduction` avec une couverture admissible confirmée, ou arrêtez pour résoudre le droit. |
| Avertissement d'inventaire ancien | Actualisez l'inventaire; l'ancienneté seule ne bloque pas, mais rend les éléments incertains. |
| Avertissement de désactivation dégradée | Comportement prévu : l'annulation se fonde sur les paramètres vérifiés de l'extension pour arrêter les frais futurs. |
| Délai de vérification dépassé | Vérifiez l'extension et les modifications concurrentes des paramètres ESU, de licence ou non liés. |
| Correctifs absents | L'inscription n'est pas un déploiement. Vérifiez la configuration automatique ou le processus manuel Microsoft. |

## Références

- [ESU SQL Server activées par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configurer SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [API REST Hybrid Compute](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Rôles personnalisés Azure](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)