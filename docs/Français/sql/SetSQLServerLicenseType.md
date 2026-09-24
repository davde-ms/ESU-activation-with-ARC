# SetSQLServerLicenseType.ps1

> [!WARNING]
> `LicenseType` est une **attestation de licence** (`Paid`) ou une **décision de facturation Azure pour la licence du logiciel SQL Server** (`PAYG`). Il s'applique à **toutes les instances SQL Server de l'hôte**, pas seulement à SQL Server 2014 ou 2016. Seul le propriétaire des licences doit choisir la valeur. Une valeur `Paid` incorrecte constitue un problème de conformité des licences; `PAYG` démarre des frais Azure horaires pour la licence du logiciel SQL Server. Ce script ne peut pas vérifier vos droits.

## Objectif et périmètre

`SetSQLServerLicenseType.ps1` définit `LicenseType` sur l'extension `WindowsAgent.SqlServer` existante d'une machine Windows activée par Arc, **uniquement lorsque la valeur actuelle est vide ou absente** (la requête Resource Graph de Microsoft affiche une valeur vide comme `Configuration needed`; une valeur absente est répertoriée comme non définie). Il permet aux hôtes laissés sans type de licence par l'intégration de passer à l'inscription aux ESU, une fois que le propriétaire des licences a pris sa décision.

Il est conçu pour :

- **Ne jamais écraser une valeur existante.** Un hôte qui a déjà la valeur demandée est signalé comme `AlreadyCompliant`. Un hôte qui a une autre valeur échoue à la validation préalable et n'est pas modifié. Pour modifier une valeur existante, utilisez le portail Azure ou l'exemple Microsoft [modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type) après une décision de licence.
- **Ne jamais activer ni annuler les ESU.** Il ne modifie pas `enableExtendedSecurityUpdates`. Exécutez ensuite [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) séparément.
- **Préserver tous les autres paramètres publics de l'extension**, les étiquettes et les propriétés de l'extension au moyen d'un GET-fusion-PUT vérifié. Les paramètres protégés ne sont jamais copiés.

Il n'installe pas l'extension (consultez [InstallSQLServerArcExtension.ps1](InstallSQLServerArcExtension.md)), ne gère ni les machines virtuelles Azure natives ni Linux, ne modifie pas les étiquettes Azure et ne gère pas les licences mutualisées par cœurs physiques. Il prend en charge uniquement les points de terminaison Azure globaux.

`SetSQLServerESUSubscription.ps1` ne modifiera  jamais `LicenseType`. Les raisons figurent dans [Pourquoi LicenseType n'est jamais modifié](SetSQLServerESUSubscription.md#why-licensetype-is-never-changed); ce script distinct fait de la décision de licence une étape séparée et explicitement confirmée.

<a id="when-licensetype-is-empty"></a>

## Lorsque LicenseType est vide

Consultez [Comment LicenseType est renseigné](README.md#how-licensetype-gets-populated) pour l'explication complète. En résumé, Microsoft documente que :

- L'intégration automatique lit l'étiquette `ArcSQLServerExtensionDeployment` (`Paid`, `PAYG`, `PAYG-Recurring` ou `LicenseOnly`) sur l'abonnement, le groupe de ressources ou le serveur Arc. Microsoft indique que le type de licence est défini si la valeur de l'étiquette `ArcSQLServerExtensionDeployment` est définie.
- Si aucune étiquette n'est définie et que vous disposez de licences Software Assurance ou d'abonnement SQL Server disponibles, Microsoft définit automatiquement le type de licence à **Paid** pour les instances nouvellement intégrées.
- Sinon, la valeur reste vide : `Configuration needed` signifie que le processus d'intégration n'avait pas assez d'informations pour configurer automatiquement le type de licence.

Une valeur vide bloque l'inscription aux ESU, car Microsoft exige `Paid` ou `PAYG` pour un abonnement ESU SQL Server activé par Arc.

<a id="choose-the-value-impact-of-each-licensetype"></a>

## Choisir la valeur : incidence de chaque LicenseType

| Valeur | À utiliser uniquement lorsque | Incidence | Confirmation requise |
| --- | --- | --- | --- |
| `Paid` | Chaque instance SQL Server de l'hôte est couverte par des licences Standard ou Enterprise **par cœur** avec Software Assurance active, ou par un abonnement SQL Server actif. | Vous attestez disposer de licences Enterprise ou Standard avec Software Assurance active ou d'un abonnement SQL Server actif, et que l'appareil respecte les restrictions d'externalisation des Conditions des produits. Éligible aux ESU. | `AttestSoftwareAssurance`. Également `ConfirmCoreBasedEnterpriseLicense` lorsqu'une instance Enterprise est signalée ou qu'aucun inventaire n'est disponible. |
| `PAYG` | Le propriétaire des licences a approuvé le paiement de la licence du logiciel SQL Server par l'intermédiaire d'Azure. | **Démarre une facturation Azure horaire** pour la licence du logiciel SQL Server de l'hôte, en plus des éventuels frais ESU. Une connectivité intermittente n'arrête pas la facturation PAYG. Éligible aux ESU. | `AcceptPaygBilling`. Microsoft exige `ConsentToRecurringPAYG` pour les abonnements gérés par un CSP; il n'est pas disponible pour les autres offres. |
| `LicenseOnly` | Server+CAL, licence perpétuelle sans Software Assurance, ou éditions gratuites Developer, Evaluation ou Express. | **Non éligible** à un abonnement ESU activé par Arc. | Aucune. |

Règles Microsoft essentielles :

- **Server+CAL doit être `LicenseOnly`.** Microsoft indique que si votre instance utilise cette licence, vous devez définir le type de licence à `LicenseOnly`, même avec une Software Assurance active. Microsoft précise aussi que l'installation de l'édition Enterprise indique le modèle de licence Server+CAL. La valeur `edition` de l'inventaire Azure ne distingue pas Enterprise d'Enterprise Core; `Paid` sur un hôte avec une instance Enterprise exige donc `ConfirmCoreBasedEnterpriseLicense`.
- **Sans Software Assurance, pas de `Paid`.** Microsoft indique que pour s'abonner aux ESU, vous devez disposer d'une Software Assurance active ou activer la facturation à l'utilisation du logiciel SQL Server.
- **Les ESU exigent `Paid` ou `PAYG`.** Un hôte `LicenseOnly` ne peut pas s'inscrire aux ESU activées par Arc.

### Consentement PAYG récurrent (CSP uniquement)

`ConsentToRecurringPAYG` écrit `ConsentToRecurringPAYG` avec `Consented=true` et l'heure UTC actuelle dans `ConsentTimestamp`, au format documenté par Microsoft dans [Consentement à la facturation récurrente](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-pay-as-you-go-transition?view=sql-server-ver17#recurring-billing-consent). Utilisez-le uniquement pour les abonnements gérés par un CSP :

- Microsoft indique que la facturation récurrente à l'utilisation est activée et exigée dans les abonnements gérés par un CSP, et qu'elle n'est pas disponible avec les autres offres d'abonnement ([FAQ](https://learn.microsoft.com/sql/sql-server/azure-arc/faq?view=sql-server-ver17)). La section sur le consentement à la facturation récurrente ajoute que les nouveaux abonnements à l'utilisation ne sont pas autorisés sans ce consentement.
- Une fois enregistrée, la propriété de consentement ne peut pas être modifiée sans réinstaller l'extension.
- Après l'heure du consentement, une déconnexion de plus de 30 jours active la facturation PAYG récurrente, y compris des frais rétroactifs.

Un consentement existant n'est jamais réécrit. Sans le commutateur, le script avertit que les abonnements gérés par un CSP l'exigent.

## Ordre requis

1. Exécutez [CheckSQLServerESUStatus.ps1](CheckSQLServerESUStatus.md) ou [SetSQLServerLicenseType.kql](../../../samples/SetSQLServerLicenseType.kql) pour trouver les hôtes dont le `LicenseType` est vide.
2. Le propriétaire des licences choisit la valeur pour chaque hôte entier à l'aide du tableau ci-dessus.
3. Exécutez ce script avec `-DryRun` et examinez chaque avertissement.
4. Exécutez-le réellement. Il définit la valeur et vérifie que rien d'autre n'a changé.
5. Confirmez la valeur avec le script d'état.
6. Ensuite seulement, exécutez [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) avec `-DryRun`, puis réellement, pour activer les ESU.

## Protections

- Toute la validation des paramètres et du CSV, y compris les règles de confirmation, a lieu avant l'authentification. Toute ligne non valide rejette le fichier entier.
- Chaque confirmation appartient à une seule valeur : par exemple, `AcceptPaygBilling` est rejeté avec `Paid` et `AttestSoftwareAssurance` est rejeté avec `PAYG`. `LicenseOnly` n'en accepte aucune.
- La validation préalable en lecture seule se termine pour toutes les cibles avant tout PUT. Elle vérifie les fournisseurs inscrits, une machine Arc Windows connectée en mode de configuration `full` qui n'est pas une machine virtuelle Azure, l'identité exacte de l'extension, l'état de provisionnement `Succeeded`, des paramètres lisibles et l'inventaire SQL.
- Le script refuse `LicenseOnly` lorsque les ESU sont activées, car Microsoft indique que vous ne pouvez pas passer la valeur à License only tant que l'abonnement ESU n'est pas annulé.
- La requête est refusée si un paramètre autre que `LicenseType` (et le consentement demandé) devait changer. Après le PUT, le script vérifie le résultat.
- Juste avant chaque PUT, le script relit l'extension. Si `LicenseType` a été défini entre-temps sur la valeur demandée, l'hôte est signalé comme `AlreadyCompliant` ; si quoi que ce soit d'autre a changé depuis la validation préalable, l'hôte échoue et n'est pas modifié. Les paramètres existants sont renvoyés avec leurs chaînes JSON (y compris les dates) inchangées.
- Il n'existe pas de `-Force`, et aucun paramètre ni aucune colonne CSV n'écrase une valeur existante.

## Rôle de moindre privilège

Utilisez les mêmes rôles que pour les autres scripts SQL. Attribuez [SQL Server Arc ESU Reader](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) au niveau de l'abonnement et [SQL Server Arc ESU Operator](../../../Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) sur chaque groupe de ressources de machines cibles.

## Authentification

Utilisez exactement une méthode : `-userToken` avec un objet `Get-AzAccessToken` non expiré, ou l'ensemble complet `-tenantId`, `-appID`, `-clientSecret` d'un principal de service. Conservez les secrets hors des fichiers CSV et des journaux.

## Paramètres

| Paramètre | Obligatoire | Description |
| --- | --- | --- |
| `subscriptionId` | Mode unique; valeur de secours facultative en mode CSV | Abonnement contenant la machine Arc. |
| `serverResourceGroupName`, `ARCServerName` | Mode unique | Hôte cible existant. |
| `LicenseType` | Mode unique | `Paid`, `PAYG` ou `LicenseOnly`. Écrit uniquement lorsque la valeur actuelle est vide. |
| `AttestSoftwareAssurance` | Obligatoire pour `Paid` | Attestation Software Assurance ou abonnement SQL pour tout l'hôte. |
| `AcceptPaygBilling` | Obligatoire pour `PAYG` | Accepte la facturation Azure horaire de la licence du logiciel SQL Server. |
| `ConsentToRecurringPAYG` | `PAYG` uniquement; exigé pour les abonnements gérés par un CSP | Enregistre le consentement PAYG récurrent. Microsoft l'exige pour les abonnements gérés par un CSP; ne l'utilisez pas pour les autres offres. Irréversible sans réinstaller l'extension. |
| `ConfirmCoreBasedEnterpriseLicense` | `Paid` uniquement, lorsque requis | Confirme que chaque instance Enterprise de l'hôte est sous licence par cœur, et non Server+CAL. |
| `csvFilePath` | Mode CSV | Schéma exact ci-dessous. |
| `tenantId`, `appID`, `clientSecret`; `userToken` | Selon l'authentification | Choisissez une seule méthode d'authentification. |
| `DryRun` | Non | Validation préalable complète en lecture seule et avertissements; aucun PUT. Alias `Preview`. |
| `WhatIf`, `Confirm` | Non | Contrôles `ShouldProcess` standard à impact élevé. |

Alias : `sub` (`subscriptionId`), `srg` (`serverResourceGroupName`), `server` (`ARCServerName`), `csv` (`csvFilePath`), `s`, `secret`, `sec` (`clientSecret`), `token` (`userToken`) et `Preview` (`DryRun`).

## Exemples

Prévisualiser `Paid` avec un jeton utilisateur :

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'

./Scripts/sql/SetSQLServerLicenseType.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-01' `
    -LicenseType Paid `
    -AttestSoftwareAssurance `
    -userToken $authenticationToken `
    -DryRun
```

Prévisualiser `PAYG` avec un principal de service :

```powershell
./Scripts/sql/SetSQLServerLicenseType.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -serverResourceGroupName 'rg-example-arc' `
    -ARCServerName 'sql-host-02' `
    -LicenseType PAYG `
    -AcceptPaygBilling `
    -tenantId '00000000-0000-0000-0000-000000000002' `
    -appID '00000000-0000-0000-0000-000000000003' `
    -clientSecret $clientSecret `
    -DryRun
```

## Entrée CSV

Commencez avec [SetSQLServerLicenseType.csv](../../../samples/SetSQLServerLicenseType.csv). Pour créer le fichier à partir de l'inventaire Azure, définissez les valeurs au début de [SetSQLServerLicenseType.kql](../../../samples/SetSQLServerLicenseType.kql), exécutez la requête dans Azure Resource Graph Explorer et téléchargez le résultat au format CSV. La requête renvoie uniquement les hôtes dont le `LicenseType` est vide, et aucune ligne tant que la valeur choisie et sa confirmation correspondante ne sont pas définies.

```csv
SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,AttestSoftwareAssurance,AcceptPaygBilling,ConsentToRecurringPAYG,ConfirmCoreBasedEnterpriseLicense
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-01,Paid,TRUE,FALSE,FALSE,FALSE
11111111-1111-1111-1111-111111111111,rg-example-arc,sql-host-02,LicenseOnly,FALSE,FALSE,FALSE,FALSE
```

```powershell
./Scripts/sql/SetSQLServerLicenseType.ps1 `
    -subscriptionId '11111111-1111-1111-1111-111111111111' `
    -csvFilePath '.\samples\SetSQLServerLicenseType.csv' `
    -userToken $authenticationToken `
    -DryRun
```

Les huit colonnes sont obligatoires. Un abonnement vide utilise la valeur de secours de la commande. Les colonnes de confirmation acceptent uniquement `TRUE`, `FALSE` (sans distinction de casse) ou une valeur vide. Les hôtes en double sont rejetés. Les colonnes inconnues qui ressemblent à un champ de licence ou de facturation sont rejetées; les autres colonnes inconnues sont signalées puis ignorées.

## Prévisualisation et sécurité d'exécution

`-DryRun` effectue la validation préalable, affiche chaque avertissement (portée à l'échelle de l'hôte, attestation, facturation, consentement ou éligibilité) avec les instances, le type d'hôte et les cœurs détectés, et n'envoie aucun PUT. `-WhatIf` prévisualise au moyen de `ShouldProcess`; `-Confirm` demande une confirmation pour chaque hôte. Un échec de validation préalable sur une cible place les autres lignes à `NotStarted`. Les opérations réelles réessaient les réponses transitoires, acceptent uniquement des URL d'interrogation asynchrone approuvées et vérifient les paramètres finaux.

## Sortie et codes de sortie

Chaque résultat contient `RowNumber`, `SubscriptionId`, `ResourceGroupName`, `MachineName`, `MachineResourceId`, `PreviousLicenseType`, `RequestedLicenseType`, `EffectiveLicenseType`, `ConsentToRecurringPAYGRecorded`, `EsuEnabled`, `HostType`, `DetectedCores`, `InstanceNames`, `Editions`, `OperationStatus`, `VerificationSucceeded` et `Message`.

`OperationStatus` vaut `Succeeded`, `AlreadyCompliant`, `Previewed`, `Declined`, `Failed` ou `NotStarted`. Le code `0` signifie que chaque ligne a réussi, était déjà conforme ou a été prévisualisée. Le code `1` signifie que la validation ou l'authentification a échoué, ou qu'une ligne a échoué, a été refusée ou n'a pas démarré.

## Dépannage

| Symptôme | Vérification |
| --- | --- |
| Erreur de confirmation | Fournissez uniquement la confirmation correspondant à la valeur choisie, et seulement après la décision du propriétaire des licences. |
| « never overwrites an existing value » | L'hôte a déjà un `LicenseType`. Modifiez-le uniquement dans le portail Azure ou avec l'exemple Microsoft après une décision de licence. |
| Instance Enterprise ou inventaire manquant bloquant `Paid` | Si Enterprise est signalé, confirmez que chaque instance Enterprise de l'hôte est sous licence par cœur avant d'ajouter `ConfirmCoreBasedEnterpriseLicense`; un hôte Enterprise Server+CAL doit être `LicenseOnly`. Si l'inventaire est manquant, actualisez-le et réexécutez, ou ajoutez `ConfirmCoreBasedEnterpriseLicense` uniquement après avoir vérifié les licences de l'hôte de façon indépendante. |
| `LicenseOnly` refusé lorsque les ESU sont activées | Annulez d'abord l'abonnement ESU avec [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) `-Action Disable`. |
| Avertissement d'abonnement CSP avec `PAYG` | Arrêtez, puis réexécutez avec `ConsentToRecurringPAYG` uniquement si l'abonnement est géré par un CSP. |

## Références

- [Gérer la connexion automatique : spécifier le type de licence](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy?view=sql-server-ver17#specify-license-type)
- [Gérer la connexion automatique : vérifier et corriger la configuration du type de licence](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy?view=sql-server-ver17#verify-and-correct-the-license-type-configuration)
- [Gérer les licences et la facturation de SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing?view=sql-server-ver17)
- [Configurer SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17)
- [Gérer la transition vers le paiement à l'utilisation : consentement à la facturation récurrente](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-pay-as-you-go-transition?view=sql-server-ver17#recurring-billing-consent)
- [FAQ SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/faq?view=sql-server-ver17)
- [Extended Security Updates SQL Server activées par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates?view=sql-server-ver17)
- [Exemple Microsoft : modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type)

Versions d'API utilisées par ce script : machines et extensions `Microsoft.HybridCompute` `2026-07-15`, `Microsoft.AzureArcData/sqlServerInstances` `2026-01-01` et inscription des fournisseurs `2021-04-01`.
