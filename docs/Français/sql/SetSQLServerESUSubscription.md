# SetSQLServerESUSubscription.ps1

## Objectif et périmètre

`SetSQLServerESUSubscription.ps1` active ou désactive le paramètre ESU SQL Server par machine Arc/OSE sur une extension `WindowsAgent.SqlServer` existante. Il prend en charge les points de terminaison Azure global et les machines Windows déjà connectées à Azure Arc; dans son état actuel, il n'est pas compatible avec les points de terminaison Azure Government. Il n'installe, ne met à niveau ni ne répare l'agent Connected Machine ou l'extension SQL; ne gère pas les machines virtuelles Azure natives ou Linux; ne déploie aucun correctif; ne configure pas l'application automatique des correctifs; n'accepte pas de nombre de cœurs saisi par le client; et ne gère pas les licences ESU mutualisées par cœurs physiques ou la virtualisation illimitée.

Consultez la [présentation du modèle d'objets ESU SQL Server](README.md) pour la mesure des vCœurs des machines virtuelles et la comparaison avec l'attribution de licences Windows Server. `ServerResourceGroupName` désigne le groupe de ressources contenant la machine Arc; aucun objet ni groupe de ressources de licence SQL distinct n'est créé.

Seuls SQL Server 2014 et 2016 sont pris en charge. L'activation exige un inventaire éligible et des confirmations explicites de facturation. `Enable` est refusé pour tout l'hôte si l'une des instances découvertes est une autre version de SQL Server (par exemple SQL Server 2017 ou ultérieure), une édition autre que Standard, Enterprise ou Developer (par exemple Express, Web, Evaluation ou Business Intelligence), ou Developer avec `Production`. Ce contrôle restrictif est une protection de ce script, pas une règle d'éligibilité de Microsoft; examinez ces hôtes manuellement. La désactivation reste possible lorsque les éléments d'inventaire/fournisseur/machine sont dégradés afin que le client puisse annuler les frais futurs; elle exige toujours une extension lisible avec l'identité exacte et des paramètres publics.

## Prérequis et limites

- PowerShell 7.x sous Windows; fournisseurs inscrits; machine Arc existante connectée dont `agentConfiguration.configMode` vaut `full`, et extension `WindowsAgent.SqlServer` saine en version `1.1.3518.465` ou ultérieure (la version en cours d'exécution de `instanceView` est utilisée lorsqu'elle est signalée) pour l'activation. Ce minimum est défini par ce dépôt : les notes de publication de Microsoft indiquent cette version comme cible actuelle de la mise à niveau automatique, mais Microsoft n'indique pas de version minimale de l'extension pour les ESU.
- `SqlManagement.IsEnabled=true` (vérification de ce dépôt, pas un prérequis ESU documenté par Microsoft), `LicenseType` effectif `Paid` ou `PAYG` et inventaire SQL Server 2014/2016. Standard/Enterprise sont des éditions de production; Developer exige une couverture hors production admissible confirmée.
- Les droits, la couverture antérieure, les autorisations locales, la connectivité et la conformité HA/DR doivent être confirmés hors ARM.

`LicenseType` décrit la licence du logiciel SQL Server sous-jacent; il n'indique pas que les ESU sont payées. `Paid` désigne des droits éligibles avec Software Assurance/abonnement SQL, tandis que `PAYG` signifie qu'Azure facture la licence du logiciel SQL à l'heure. Le paramètre distinct `enableExtendedSecurityUpdates` démarre ou arrête l'abonnement ESU et sa mesure. Ce script ne modifie jamais `LicenseType` : il ne peut donc pas faire passer un hôte en `PAYG` ni changer un autre modèle de paiement SQL; les hôtes `LicenseOnly` ou sans valeur sont bloqués, jamais convertis. Pour renseigner une valeur vide après une décision de licence, utilisez le script distinct [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md). Consultez [Pourquoi LicenseType n'est jamais modifié](#why-licensetype-is-never-changed) et [LicenseType décrit la licence du logiciel SQL Server](README.md#sql-license-type).

Le paramètre concerne tout l'hôte/OSE, pas une instance nommée. Toutes les instances et tous les services associés éligibles peuvent être affectés, et 2014/2016 peuvent être mesurés séparément. Le script effectue un GET-fusion-PUT préservant les paramètres : il lit l'extension, copie profondément les paramètres publics, modifie uniquement `enableExtendedSecurityUpdates` et `esuLastUpdatedTimestamp`, refuse d'envoyer toute requête qui modifierait `LicenseType`, puis écrit et vérifie la préservation sémantique, y compris un `LicenseType` inchangé. Les propriétés protégées ou de réponse ne sont jamais copiées.

Le PUT est construit à partir de l'extension lue lors de la validation préalable; l'extension n'est pas relue juste avant l'écriture. En mode CSV, la validation préalable de tous les hôtes se termine avant le premier PUT. Une modification apportée à la même extension par un autre processus pendant cet intervalle pourrait être annulée; ne modifiez donc pas ces extensions par d'autres moyens pendant l'exécution du script.

Pour `Disable`, le script lit volontairement uniquement l'extension attendue et ignore les contrôles de machine, fournisseur et inventaire SQL. Cette voie d'annulation reste disponible lorsque la découverte ou l'état de santé sont dégradés, car exiger une découverte saine pourrait empêcher l'arrêt des frais ESU futurs. Une mauvaise identité d'extension ou des paramètres publics illisibles bloque toujours la modification.

<a id="why-licensetype-is-never-changed"></a>

## Pourquoi LicenseType n'est jamais modifié

Ce script active ou désactive uniquement l'abonnement ESU. Il **ne définit, ne modifie et n'efface jamais `LicenseType`**. Aucun commutateur, paramètre ou colonne CSV ne lui permet de le faire, même sur option explicite, et ce choix est délibéré. L'ajout d'une option « définir le type de licence avant d'activer les ESU » a été évalué, puis rejeté pour les raisons suivantes.

1. **Il protège le modèle de paiement SQL du client.** L'activation des ESU ne doit jamais changer la façon dont le logiciel SQL Server est payé. Tout chemin de code du script ESU capable d'écrire `LicenseType` peut être déclenché par erreur, même derrière un commutateur : ligne CSV copiée, export Resource Graph ou valeur par défaut d'un pipeline. À grande échelle, cela pourrait faire passer de nombreux hôtes en `PAYG` et démarrer une facturation Azure du logiciel SQL Server que le client possède déjà. Renseigner un `LicenseType` vide constitue donc une étape distincte, explicitement confirmée, dans [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md), qui n'écrase jamais une valeur existante.
2. **`Paid` est une attestation juridique qu'un script ne peut pas vérifier.** Microsoft indique qu'en sélectionnant une licence avec Software Assurance, vous attestez disposer de licences Enterprise ou Standard avec Software Assurance active ou d'un abonnement SQL Server actif, et que l'appareil respecte les restrictions d'externalisation des Conditions des produits. Seul le propriétaire des licences peut faire cette déclaration. Un opérateur ESU ou une tâche automatisée ne doit pas la faire à sa place.
3. **`PAYG` est une décision de facturation Azure pour la licence du logiciel SQL Server.** La licence du logiciel SQL est alors facturée à l'heure par Azure, en plus des frais ESU. Pour les abonnements gérés par un fournisseur de solutions cloud (CSP), l'activation du paiement à l'utilisation exige aussi un consentement à la facturation récurrente.
4. **Un client sans Software Assurance ne peut pas légitimement passer à `Paid`.** Microsoft indique que pour s'abonner aux ESU, vous devez disposer d'une Software Assurance active ou activer la facturation à l'utilisation du logiciel SQL Server. Une licence sans Software Assurance n'est pas admissible. Un hôte `LicenseOnly` faute de Software Assurance n'a donc qu'une seule voie ESU Arc : `PAYG`. C'est exactement le changement de facturation que ce dépôt refuse de faire au nom du client.
5. **Les hôtes Server+CAL doivent rester `LicenseOnly`.** Microsoft indique que si votre instance utilise cette licence, vous devez définir le type de licence à `LicenseOnly`, même si vous disposez d'une Software Assurance active pour celle-ci. Microsoft précise aussi que l'abonnement ESU Arc n'est pas disponible pour le modèle Server+CAL; sa seule voie Arc consiste à passer en `PAYG`. Une installation Enterprise (non Core) indique un modèle Server+CAL. Faire passer automatiquement un tel hôte à `Paid` créerait une non-conformité de licence.
6. **`LicenseType` s'applique à tout l'hôte, pas seulement à l'instance hors support.** C'est un paramètre de l'unique extension `WindowsAgent.SqlServer` de la machine Arc. Il s'applique donc à toutes les instances SQL Server de cet OSE, y compris les instances SQL Server 2017 ou ultérieures prises en charge qui n'ont pas besoin des ESU. Le modifier pour activer les ESU de SQL Server 2014/2016 réattesterait ou refacturerait aussi ces autres instances.
7. **Des changements distincts gardent la facturation vérifiable et réversible.**
   - Lorsque les ESU sont activées, la facturation Azure commence au début de l'année ESU en cours (rétrofacturation). Combiner un changement de type de licence et l'activation des ESU dans une même écriture mélange deux événements de facturation, ce qui complique la vérification des frais, l'audit et l'analyse des causes.
   - Les deux changements ne peuvent pas non plus toujours être annulés indépendamment. Le script de type de licence de Microsoft refuse lui-même de passer un hôte en `LicenseOnly` tant que les ESU sont activées.

<a id="what-to-do-when-a-host-is-licenseonly-or-undefined"></a>

### Que faire lorsqu'un hôte est LicenseOnly ou sans valeur

L'action `Enable` échoue à la validation préalable pour cet hôte et aucune modification n'est effectuée. Ensuite :

1. **Le propriétaire des licences décide** du `LicenseType` correct pour tout l'hôte, selon les droits :
   - Software Assurance active ou abonnement SQL Server pour les licences par cœur de l'hôte : `Paid`.
   - Décision approuvée de payer la licence du logiciel SQL Server par l'intermédiaire d'Azure : `PAYG`.
   - Server+CAL, ou licence perpétuelle sans Software Assurance : `LicenseOnly`. Cet hôte n'est pas admissible aux ESU au moyen de ce script.
2. **Définissez-le hors de ce script :**
   - **`LicenseType` sans valeur (vide) :** utilisez [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md). Il renseigne uniquement une valeur vide, n'écrase jamais une valeur existante, affiche l'incidence de la valeur choisie et exige la confirmation correspondante. Consultez [Comment LicenseType est renseigné](README.md#how-licensetype-gets-populated) pour comprendre pourquoi un hôte peut être sans valeur.
   - **`LicenseOnly` ou toute autre valeur existante :** aucun script de ce dépôt ne la modifie. Si le propriétaire des licences décide qu'un changement est légitime, utilisez le portail Azure ou l'exemple officiel Microsoft [modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type), référencé dans [Configurer SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17#modify-sql-server-configuration).
   - Lorsque vous utilisez l'exemple, gardez les deux changements distincts : exécutez-le avec `-LicenseType` seulement, sans `-EnableESU`.
   - Limitez l'exemple aux machines voulues, par exemple avec `-MachineName` et un fichier CSV. Sans `-MachineName`, il cible tous les serveurs SQL Server activés par Arc de l'abonnement ou du groupe de ressources indiqué, ou de tous les abonnements si aucun n'est indiqué. Exécutez-le d'abord avec `-ReportOnly` pour lister ce qui serait modifié.
   - Sans `-Force`, l'exemple définit `-LicenseType` uniquement sur les extensions où il n'a pas de valeur. Avec `-Force`, il remplace la valeur existante sur toutes les extensions de la portée, y compris les hôtes déjà `Paid` ou `PAYG`.
   - Ne sélectionnez `PAYG` avec aucun outil, sauf si la facturation Azure de la licence du logiciel SQL Server est la décision voulue et approuvée.
3. **Vérifiez, puis activez :** confirmez la nouvelle valeur avec [CheckSQLServerESUStatus.ps1](CheckSQLServerESUStatus.md) ou [TestSQLServerArcESUPrerequisites.ps1](TestSQLServerArcESUPrerequisites.md). Exécutez ensuite ce script avec `-DryRun`, puis l'action `Enable` réelle.

## Rôle de moindre privilège

Créez les deux rôles personnalisés dans chaque abonnement cible. Attribuez [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) au niveau de l'abonnement pour lire les fournisseurs, l'inventaire, la machine et l'extension. Attribuez [SQL Server Arc ESU Operator](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) uniquement à chaque groupe de ressources de machines cible; il accorde seulement l'écriture d'extension ainsi que les actions en lecture seule `locations/operationstatus` et `locations/operationresults` utilisées pour suivre les mises à jour asynchrones. `Disable` lit uniquement l'extension; les lectures de fournisseur, de machine et d'inventaire du rôle Reader ne sont donc pas utilisées dans ce cas. Cette séparation évite l'écriture des extensions dans tout l'abonnement. Aucun rôle n'accorde l'écriture/suppression de machine, l'inscription de fournisseur ni l'autorisation `sqlServerEsuLicenses`.

## Authentification

Utilisez exactement une méthode : `-userToken` avec un objet `Get-AzAccessToken` non expiré, ou l'ensemble complet `-tenantId`, `-appID`, `-clientSecret`. Les deux méthodes ou un ensemble incomplet échouent. Conservez les secrets hors des CSV et journaux.

## Paramètres

| Paramètre | Obligatoire | Description |
| --- | --- | --- |
| `subscriptionId` | Mode unique; secours CSV facultatif | Abonnement de la machine Arc. |
| `serverResourceGroupName`, `ARCServerName` | Mode unique | Hôte cible existant. |
| `Action` | Mode unique | `Enable` ou `Disable`. |
| `LicenseType` | Activation uniquement, facultatif | Confirmation de la valeur actuelle (`Paid` ou `PAYG`). Le script ne modifie jamais `LicenseType`; une différence fait échouer la validation préalable. |
| `Environment` | Activation uniquement | `Production` ou `NonProduction`. |
| `AcceptBackBilling` | Activation uniquement | Confirmation obligatoire. |
| `AcceptLicenseTypeChange` | Doit être vide ou FALSE | Conservé pour compatibilité; TRUE est rejeté, car les changements de type de licence ne sont pas pris en charge. |
| `ConfirmNonProductionCoverage` | Activation uniquement lorsque nécessaire | Obligatoire pour Developer en `NonProduction`. |
| `ConfirmExternalPrerequisites` | Activation uniquement | Confirmation des contrôles externes. |
| `csvFilePath` | Mode CSV | Schéma exact ci-dessous. |
| `tenantId`, `appID`, `clientSecret`; `userToken` | Selon l'authentification | Choisissez une méthode. |
| `DryRun` | Non | Validation et aperçu de facturation en lecture seule; aucun PUT. Alias `Preview`. |
| `WhatIf`, `Confirm` | Non | Contrôles `ShouldProcess` à impact élevé. |

Alias : `sub` (`subscriptionId`), `srg` (`serverResourceGroupName`), `server` (`ARCServerName`), `csv` (`csvFilePath`), `s`, `secret`, `sec` (`clientSecret`), `token` (`userToken`) et `Preview` (`DryRun`).

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
Pour générer le fichier à partir de l'inventaire Azure actuel, vérifiez chaque constante au début de [SetSQLServerESUSubscription.kql](../../../samples/SetSQLServerESUSubscription.kql), exécutez la requête dans Azure Resource Graph Explorer, puis téléchargez le résultat au format CSV. La requête renvoie une ligne par hôte et ne renvoie volontairement aucune ligne `Enable` tant que les confirmations obligatoires de facturation et de prérequis ne valent pas `TRUE`.

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

Les dix colonnes affichées sont obligatoires. Un abonnement vide utilise celui de la commande. Les contrôles booléens acceptent uniquement `TRUE`, `FALSE` (sans distinction de casse) ou vide lorsque cela est permis. `Enable` exige un environnement valide, `AcceptBackBilling=TRUE` et `ConfirmExternalPrerequisites=TRUE`; un `LicenseType` non vide doit correspondre à la valeur actuelle de l'hôte et `AcceptLicenseTypeChange` doit être vide ou `FALSE`; Developer hors production exige `ConfirmNonProductionCoverage=TRUE`. `Disable` exige que tous les champs d'activation soient vides. Les hôtes en double/contradictoires sont rejetés. Une colonne inconnue ressemblant à un contrôle de facturation est rejetée; une colonne sans rapport est signalée puis ignorée. Toute erreur locale rejette tout le fichier avant l'authentification.

## Prévisualisation et sécurité d'exécution

`-DryRun` effectue la validation préalable, affiche les éléments exacts d'hôte/type de licence/version/cœurs/facturation et n'envoie aucun PUT. `-WhatIf` ajoute la prévisualisation `ShouldProcess`; `-Confirm` demande une confirmation. Tous les contrôles Azure se terminent avant la première modification. Un échec rend les lignes valides `NotStarted`; après le début des modifications, les lignes indépendantes continuent malgré un échec actif.

Un état déjà conforme renvoie `AlreadyCompliant` sans PUT ni modification d'horodatage. Les opérations actives réessaient les réponses transitoires, n'acceptent que les URL de suivi approuvées et relisent jusqu'à vérifier l'état, l'horodatage, le type de licence et les paramètres non liés.

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
| `LicenseType` différent ou `AcceptLicenseTypeChange` rejeté | Ce script ne modifie jamais `LicenseType`. Videz `LicenseType` ou indiquez la valeur actuelle de l'hôte, et laissez `AcceptLicenseTypeChange` vide ou à `FALSE`. Effectuez tout changement de licence séparément, uniquement après une décision de licence. |
| `LicenseType` actuel `LicenseOnly` ou sans valeur | Blocage prévu, aucune modification. Suivez [Que faire lorsqu'un hôte est LicenseOnly ou sans valeur](#what-to-do-when-a-host-is-licenseonly-or-undefined); pour une valeur vide, utilisez [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md) après une décision de licence. Consultez [Pourquoi LicenseType n'est jamais modifié](#why-licensetype-is-never-changed). |
| Developer rejeté | Utilisez `NonProduction` avec une couverture admissible confirmée, ou arrêtez pour résoudre le droit. |
| « Unsupported SQL Server version detected » ou « Unsupported SQL Server edition detected » | L'hôte exécute aussi une autre version de SQL Server ou une édition non prise en charge. `Enable` est refusé pour tout l'hôte; examinez-le manuellement. |
| Avertissement d'inventaire ancien | Actualisez l'inventaire; l'ancienneté seule ne bloque pas, mais rend les éléments incertains. |
| Avertissement de désactivation dégradée | Comportement prévu : l'annulation se fonde sur les paramètres vérifiés de l'extension pour arrêter les frais futurs. |
| Délai de vérification dépassé | Vérifiez l'extension et les modifications concurrentes des paramètres ESU, de licence ou non liés. |
| Correctifs absents | L'inscription n'est pas un déploiement. Vérifiez la configuration automatique ou le processus manuel Microsoft. |

## Références

- [ESU SQL Server activées par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Configurer SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [Gérer les licences et la facturation de SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing?view=sql-server-ver17)
- [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md) (renseigne uniquement un `LicenseType` vide)
- [Exemple Microsoft : modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type)
- [API REST Hybrid Compute](https://learn.microsoft.com/rest/api/hybridcompute/)
- [Microsoft.AzureArcData/sqlServerInstances 2026-01-01](https://learn.microsoft.com/azure/templates/microsoft.azurearcdata/2026-01-01/sqlserverinstances)
- [Rôles personnalisés Azure](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)

Versions d'API utilisées par ce script : machines et extensions `Microsoft.HybridCompute` `2026-07-15`, `Microsoft.AzureArcData/sqlServerInstances` `2026-01-01` et inscription des fournisseurs `2021-04-01`.