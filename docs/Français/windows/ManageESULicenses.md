# ManageESULicenses.ps1

`ManageESULicenses.ps1` valide un fichier CSV, crée ou met à jour des licences ESU Azure Arc en bloc et peut, de manière facultative, attribuer ou dissocier ces licences de serveurs avec Azure Arc.

La cible, l'édition, le type et le nombre de cœurs, l'état d'activation, l'année du programme et l'ID de facture ont une incidence sur les licences et la facturation. Confirmez les choix appropriés pour votre organisation avant d'exécuter le script en mode actif. Les règles de ce guide reposent sur les [instructions Microsoft de provisionnement des licences ESU](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/license-extended-security-updates), les [instructions Microsoft relatives à l'API ESU](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/api-extended-security-updates) et les [informations de facturation](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/billing-extended-security-updates).

## Procédure sécurisée

1. Exécutez `CheckESUStatus.ps1` pour inventorier les attributions actuelles. Ce script est en lecture seule.
2. Copiez le [modèle CSV ManageESULicenses](../../../samples/ManageESULicenses.csv) et remplacez ses valeurs fictives.
3. Exécutez `ManageESULicenses.ps1 -DryRun` avec les paramètres prévus.
4. Vérifiez chaque ligne du plan d'opérations validé, en particulier `LicenseName`, `CoreType`, la valeur `CoreCount` normalisée, `CreationAction` et `AssignmentAction`.
5. Vérifiez le nombre de licences existantes et nouvelles ainsi que le récapitulatif des opérations.
6. Exécutez la même commande sans `-DryRun` uniquement lorsque le plan est correct. Utilisez `-WhatIf` pour prévisualiser les opérations PowerShell ou `-Confirm` pour obtenir une invite interactive pour chaque opération.

## Colonnes CSV

PowerShell ne respecte pas la casse des noms de colonnes et des valeurs littérales, mais utilisez les orthographes ci-dessous par souci de cohérence.

| Colonne | Obligatoire | Description |
| --- | --- | --- |
| `Name` | Oui | Nom de base utilisé pour la licence ESU et, lorsqu'une attribution est demandée, nom du serveur avec Azure Arc. Le nom final est `licenseNamePrefix` + `Name` + `licenseNameSuffix`. Chaque nom final doit être unique dans le CSV. |
| `Cores` | Oui | Nombre entier positif de cœurs avant normalisation. |
| `IsVirtual` | Oui | `Virtual` crée un plan `vCore`; `Physical` crée un plan `pCore`. |
| `AgentVersion` | Oui | Version de l'agent Azure Connected Machine. Minimum `1.34` pour Windows Server 2012/2012 R2 et `1.62` pour Windows Server 2016. Une version antérieure fait échouer toute la validation préalable. |
| `ServerResourceGroupName` | Pour les actions d'attribution seulement | Groupe de ressources contenant le serveur. Obligatoire lorsque `AssignESULicense` vaut `True` ou `False`. |
| `AssignESULicense` | Non | `True` attribue la licence créée ou mise à jour, `False` la dissocie et une valeur vide n'effectue aucune action d'attribution. |
| `ESUException` | Non | Texte copié dans l'étiquette `ESU Usage` de la ressource de licence. Il n'établit pas l'éligibilité et ne modifie pas la facturation. |
| `Target` | Non | Cible exacte de cette ligne : `Windows Server 2012`, `Windows Server 2012 R2` ou `Windows Server 2016`. Une cellule non vide remplace `-target`; une cellule vide utilise le paramètre, dont la valeur par défaut est `Windows Server 2012`. |
| `InvoiceId` | Non | ID de facture de transition depuis les licences en volume pour cette ligne. Une cellule non vide remplace `-invoiceId`. Pris en charge uniquement pour Windows Server 2012/2012 R2. |
| `ProgramYear` | Non | Année de transition de cette ligne : `Year 1`, `Year 2` ou `Year 3`. Une cellule non vide remplace `-programYear`. Elle nécessite un ID de facture effectif et n'est pas prise en charge pour Windows Server 2016. |

Les colonnes supplémentaires exportées à des fins d'inventaire ou de filtrage sont autorisées et ignorées par le script.

```csv
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException,Target,InvoiceId,ProgramYear
ws2012r2-app-01,8,Virtual,1.34,rg-arc-servers,,,Windows Server 2012 R2,INV-FICTITIOUS-001,Year 3
ws2016-db-01,16,Physical,1.62,rg-arc-database,,,Windows Server 2016,,
```

Le modèle contient uniquement des noms fictifs. Remplacez toutes les valeurs et vérifiez le résultat avant utilisation.

### Priorité de la cible et de la transition

Le CSV peut mélanger les trois cibles. Pour chaque ligne, le script résout indépendamment `Target`, `InvoiceId` et `ProgramYear` : une valeur de ligne non vide est prioritaire sur le paramètre de ligne de commande correspondant. Une valeur `Target` vide utilise `-target`, dont la valeur par défaut est `Windows Server 2012`. Une valeur `InvoiceId` vide utilise `-invoiceId` uniquement si ce paramètre a été fourni explicitement. Une valeur `ProgramYear` vide utilise un paramètre `-programYear` fourni explicitement; sinon, une facture effective attribue par défaut `Year 1` à la ligne. Une année de programme sans facture effective n'est pas valide.

Les données de transition depuis les licences en volume sont prises en charge uniquement pour Windows Server 2012/2012 R2. Pour Windows Server 2016, `volumeLicenseDetails` est omis et toute valeur `InvoiceId` effective ou `ProgramYear` fournie explicitement entraîne le rejet de l'ensemble du fichier. Pour limiter la transition à certaines lignes 2012/R2 d'un fichier mixte, ne liez pas les paramètres de transition du lot et renseignez `InvoiceId` et `ProgramYear` uniquement sur ces lignes.

## Normalisation des cœurs et de l'édition

Le script convertit chaque ligne CSV en plan avant l'authentification ou toute opération Azure :

| Entrée | Licence planifiée | Normalisation |
| --- | --- | --- |
| `IsVirtual=Virtual` avec `edition=Standard` | `Standard` + `vCore` | Arrondi au nombre pair supérieur, avec un minimum de 8 cœurs. |
| `IsVirtual=Physical` avec `edition=Standard` | `Standard` + `pCore` | Arrondi au nombre pair supérieur, avec un minimum de 16 cœurs. |
| `IsVirtual=Physical` avec `edition=Datacenter` | `Datacenter` + `pCore` | Arrondi au nombre pair supérieur, avec un minimum de 16 cœurs. |
| `IsVirtual=Virtual` avec `edition=Datacenter` | Non valide | La validation préalable échoue. Une licence Datacenter fondée sur des cœurs virtuels n'est pas une combinaison valide. |

Exemples : 4 cœurs virtuels sont normalisés à 8 `vCore`; 15 cœurs physiques sont normalisés à 16 `pCore`; 17 cœurs sont normalisés à 18. Une licence normalisée ne peut pas dépasser 10 000 cœurs. Microsoft limite également un groupe de ressources à 800 ressources de licence; avant de poursuivre, le script compte les licences existantes et uniquement les noms planifiés qui sont nouveaux.

Une licence fondée sur des cœurs virtuels ne peut pas être utilisée pour des serveurs physiques. Utilisez toujours `Standard` pour les licences `vCore`, même lorsque le système d'exploitation invité est Datacenter. Dans cette procédure, `Datacenter` est pris en charge uniquement avec `pCore`.

## Éligibilité et prérequis selon la cible

Établissez séparément l'éligibilité à tout scénario sans frais ou d'évaluation selon les conditions de licence Microsoft applicables. `ESUException` ajoute uniquement une étiquette `ESU Usage` à la ressource Azure.

Les étiquettes n'ont aucun effet sur la facturation. Microsoft indique que la facturation dépend des cœurs associés à une licence activée, quelles que soient les étiquettes, et que les cœurs utilisés pour les scénarios d'évaluation ou sans frais ne doivent pas être provisionnés dans la licence ESU Azure Arc. Ne considérez aucune valeur `ESUException` comme une approbation, un droit ou une exemption de facturation.

Les ESU Windows Server 2016 prennent en charge les éditions Standard et Datacenter. L'éligibilité générale exige une Software Assurance (SA) éligible ou un abonnement serveur équivalent. Pour les charges de travail Windows Server 2016 exécutées localement, la SA est obligatoire. Les ESU Windows Server 2016 ne sont pas disponibles avec SPLA, ne prennent pas en charge la transition depuis les licences en volume et ne comportent aucun avantage documenté pour le développement/test Visual Studio. Les valeurs réservées `WS2012 VISUAL STUDIO DEV TEST`, `WS2012 DISASTER RECOVERY` et `WS2012 MULTIPURPOSE` sont rejetées sur les lignes 2016, car elles appartiennent uniquement au processus d'exception Windows Server 2012/R2 documenté par Microsoft. Tout autre texte reste informatif et n'établit aucun droit pour 2016.

Les serveurs avec Azure Arc utilisés pour les ESU Windows Server 2012/R2 ou 2016 ne sont actuellement pas disponibles dans Azure géré par 21Vianet. Pour Windows Server 2016, suivez les [instructions de préparation](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prepare-extended-security-updates) Microsoft actuelles concernant le package de licences et la mise à jour de la pile de maintenance (SSU) applicables. Cette page n'indique actuellement aucun article KB Windows Server 2016; ne remplacez pas cette référence par l'article KB de Windows Server 2012.

## Validation préalable

Le script valide l'ensemble du CSV avant l'authentification. Aucune ligne n'est traitée si la validation préalable signale une erreur. Le script rejette :

- Un CSV vide ou l'absence des colonnes `Name`, `Cores`, `IsVirtual` ou `AgentVersion`.
- Les noms vides, les nombres de cœurs non positifs ou non entiers, les versions d'agent non valides et les valeurs `IsVirtual` autres que `Virtual` ou `Physical`.
- Les valeurs `AssignESULicense` autres que `True`, `False` ou vide.
- Les lignes d'attribution ou de dissociation sans `ServerResourceGroupName`.
- Les noms de licence générés contenant des caractères autres que des lettres, chiffres, traits d'union, traits de soulignement ou points.
- Les lignes d'attribution ou de dissociation dont le champ `Name` du serveur Azure Arc dépasse 54 caractères ou contient d'autres caractères.
- Les noms de licence finaux en double après application du préfixe et du suffixe.
- Les lignes Datacenter avec des cœurs virtuels et les tailles de licence normalisées supérieures à 10 000 cœurs.
- Les cibles non prises en charge, les versions d'agent inférieures au minimum 1.34 ou 1.62 de la cible, une année de programme sans facture et toute donnée de transition Windows Server 2016.
- Les valeurs d'exception Windows Server 2012 réservées exactes sur une ligne Windows Server 2016.

Après la validation du CSV et l'authentification, le script envoie des requêtes `GET` paginées en lecture seule afin de compter les ressources de licence existantes et de déterminer combien de noms planifiés sont nouveaux. Il s'arrête si le total dépasse 800 licences dans le groupe de ressources cible.

## Contrôles de prévisualisation et de confirmation

| Contrôle | Comportement |
| --- | --- |
| `-DryRun` | Valide l'ensemble du CSV, s'authentifie, exécute les requêtes `GET` en lecture seule qui comptent les licences, affiche le plan normalisé et le récapitulatif, et n'effectue aucune modification. Il ne crée, ne modifie, n'attribue, ne dissocie et ne supprime aucune ressource. `-Preview` est un alias. |
| `-WhatIf` | Utilise `ShouldProcess` de PowerShell pour prévisualiser chaque opération de création ou de modification et chaque attribution. La validation du CSV et le comptage des licences en lecture seule sont toujours exécutés. Aucune requête de modification n'est envoyée. |
| `-Confirm` | Affiche une invite avant chaque création ou modification puis, une fois la licence prête, avant son attribution ou sa dissociation. La validation du CSV et le comptage des licences précèdent les invites. |

`-DryRun` constitue le premier passage le plus clair, car il affiche un plan normalisé complet sans entrer dans la boucle de traitement actif.

## Priorité d'authentification

Utilisez l'une des méthodes suivantes :

- `-userToken` : objet de jeton non expiré renvoyé par `Get-AzAccessToken -ResourceUrl https://management.azure.com/`.
- Principal de service : fournissez ensemble `-tenantId`, `-appID` et `-clientSecret`.

Si les deux méthodes sont fournies, `-userToken` est prioritaire. L'identité doit être autorisée sur le groupe de ressources de licences cible et sur les profils de licence des serveurs lorsque des actions d'attribution sont demandées. Ne placez jamais d'informations d'identification ni de jetons dans un fichier CSV.

```powershell
$authenticationToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/

./Scripts/windows/ManageESULicenses.ps1 `
    -subscriptionId "11111111-1111-1111-1111-111111111111" `
    -licenseResourceGroupName "rg-arc-esu-licenses" `
    -location "EastUS" `
    -state "Deactivated" `
    -edition "Standard" `
    -csvFilePath ".\samples\ManageESULicenses.csv" `
    -licenseNamePrefix "ESU-" `
    -userToken $authenticationToken `
    -DryRun
```

Tous les ID et noms de cet exemple sont fictifs.

## Paramètres

| Paramètre | Obligatoire | Description |
| --- | --- | --- |
| `subscriptionId` | Oui | Abonnement dans lequel les licences sont créées et les attributions facultatives aux serveurs sont effectuées. |
| `licenseResourceGroupName` | Oui | Groupe de ressources contenant les licences. |
| `location` | Oui | Région Azure pour les requêtes de licence et de profil de licence. |
| `state` | Oui | `Activated` ou `Deactivated`. L'état d'activation a une incidence sur la facturation; vérifiez l'état prévu. |
| `edition` | Oui | `Standard` ou `Datacenter`. Une même valeur s'applique à toutes les lignes CSV. |
| `target` | Non | Cible du lot : `Windows Server 2012`, `Windows Server 2012 R2` ou `Windows Server 2016`; la valeur par défaut est `Windows Server 2012`. Une valeur `Target` de ligne non vide la remplace. |
| `csvFilePath` | Oui | Chemin du CSV d'entrée. |
| `tenantId`, `appID`, `clientSecret` | Selon l'authentification | Les trois sont obligatoires pour l'authentification par principal de service lorsque `userToken` n'est pas fourni. |
| `userToken` | Selon l'authentification | Objet de jeton utilisateur; prioritaire sur les informations d'identification du principal de service. `token` est un alias. |
| `licenseNamePrefix` | Non | Texte ajouté avant chaque valeur `Name`; 20 caractères au maximum selon la validation du script. |
| `licenseNameSuffix` | Non | Texte ajouté après chaque valeur `Name`; 20 caractères au maximum selon la validation du script. |
| `invoiceId` | Non | Facture de lot pour une transition applicable de Windows Server 2012/R2 depuis les licences en volume. Une valeur `InvoiceId` de ligne non vide la remplace. Ne liez pas ce paramètre pour un fichier mixte contenant des lignes 2016. |
| `programYear` | Non | Valeur de lot `Year 1`, `Year 2` ou `Year 3` pour les lignes de transition. Une valeur `ProgramYear` de ligne non vide la remplace; sinon, une facture sans année explicite utilise `Year 1`. Ce paramètre n'est pas valide sans facture et n'est pas pris en charge pour 2016. |
| `logFileName` | Non | Chemin du journal de transcription. `log` est un alias. |
| `DryRun` | Non | Prévisualisation complète sans modification décrite ci-dessus. |

L'API provisionne ou modifie les ressources de licence et les attribue ou les dissocie au moyen des profils de licence des serveurs. Microsoft documente ces actions comme des opérations d'écriture Azure Resource Manager. N'exécutez aucune commande en mode actif avant l'approbation de la prévisualisation.

La fin du support de Windows Server 2016 intervient le 12 janvier 2027 et la facturation des ESU Azure Arc commence le 13 janvier 2027. Une licence activée est facturée même si elle n'est pas attribuée. L'inscription tardive ainsi que les licences ou les cœurs ajoutés après la fin du support sont rétrofacturés à partir de la date de fin du support applicable. La réactivation, la recréation, le changement de région et le changement de locataire sont également soumis à la rétrofacturation. La diminution du nombre de cœurs, la désactivation ou la suppression peuvent continuer à entraîner des frais pendant un maximum de cinq jours calendaires.

## Plan et récapitulatif

Avant tout traitement actif des lignes, le script affiche un `Validated operation plan` contenant :

- Le numéro de ligne CSV et le nom du serveur.
- Le nom final de la licence.
- Le type de cœurs et le nombre de cœurs normalisé.
- La cible, le mode de transition, la version minimale requise de l'agent, la version fournie de l'agent et l'action de création.
- L'action d'attribution.

Le récapitulatif final `ESU License Operation Summary` indique le nombre total de lignes validées, les licences créées ou modifiées, les attributions terminées, les dissociations terminées, les opérations prévisualisées ou refusées et les échecs. Toute erreur de validation préalable empêche l'authentification et tous les appels REST Azure; tout échec enregistré ultérieurement produit un code de sortie différent de zéro.

## Exécution en mode actif

Après avoir vérifié une simulation réussie, supprimez `-DryRun` sans modifier le CSV ni les paramètres de licence vérifiés. Ajoutez `-Confirm` pour prendre une décision interactive pour chaque opération :

```powershell
./Scripts/windows/ManageESULicenses.ps1 `
    -subscriptionId "11111111-1111-1111-1111-111111111111" `
    -licenseResourceGroupName "rg-arc-esu-licenses" `
    -location "EastUS" `
    -state "Deactivated" `
    -edition "Standard" `
    -csvFilePath ".\samples\ManageESULicenses.csv" `
    -licenseNamePrefix "ESU-" `
    -userToken $authenticationToken `
    -Confirm
```

## Résolution des problèmes

| Symptôme | Vérification |
| --- | --- |
| Colonne manquante ou ligne non valide | Utilisez les en-têtes obligatoires exacts, supprimez les valeurs obligatoires vides et vérifiez `Cores`, `IsVirtual`, `AgentVersion` et `AssignESULicense`. La validation préalable répertorie ensemble toutes les erreurs détectées. |
| Nom de licence final en double | Rendez les valeurs `Name` uniques ou modifiez le préfixe ou suffixe afin que chaque nom généré soit unique. |
| Erreur Datacenter avec des cœurs virtuels | Utilisez `-edition Standard` pour un lot CSV virtuel, ou placez les lignes Datacenter physiques dans un CSV distinct et exécutez-le séparément. |
| Nombre normalisé supérieur à la valeur CSV | Ce comportement est normal pour les nombres impairs et les valeurs inférieures au minimum de 8 vCore ou 16 pCore. Vérifiez le plan affiché avant de poursuivre. |
| Plus de 10 000 cœurs normalisés | Répartissez les cœurs requis entre plusieurs licences et valeurs `Name` uniques. |
| Le nombre du groupe de ressources dépasse 800 | Utilisez un autre groupe de ressources ou réduisez le nombre de nouvelles ressources de licence du lot. Les noms existants sont traités comme des mises à jour et non comme de nouvelles licences. |
| Version de l'agent inférieure au minimum de la cible | Mettez à niveau l'agent Azure Connected Machine vers au moins 1.34 pour Windows Server 2012/R2 ou 1.62 pour Windows Server 2016. L'ensemble du fichier est rejeté avant l'authentification. |
| Erreur de transition Windows Server 2016 | Supprimez les valeurs `InvoiceId` effectives et `ProgramYear` fournies explicitement de chaque ligne 2016. Ne liez pas les paramètres de transition du lot lorsque seules certaines lignes 2012/R2 effectuent une transition. |
| Erreur d'exception WS2012 réservée sur une ligne 2016 | Supprimez `WS2012 VISUAL STUDIO DEV TEST`, `WS2012 DISASTER RECOVERY` ou `WS2012 MULTIPURPOSE`; ces valeurs exactes ne constituent pas un droit pour 2016. |
| Échec de l'authentification | Actualisez `userToken` ou fournissez les trois paramètres du principal de service. Vérifiez que l'identité a accès à toutes les ressources concernées. |
| Échec de l'attribution après la création de la licence | Vérifiez le nom du serveur, `ServerResourceGroupName`, la région, les autorisations et l'état actuel du profil de licence. Utilisez `CheckESUStatus.ps1` pour vérifier à nouveau l'attribution. |
| Doute sur l'absence de frais d'un scénario | Arrêtez-vous avant l'activation. Confirmez l'éligibilité selon les conditions Microsoft actuelles; ne vous fiez pas à `ESUException` ni aux étiquettes des ressources Azure. |

Pour attribuer en bloc des licences déjà existantes, utilisez [ManageESUAssignments.ps1](ManageESUAssignments.md) et son [modèle CSV](../../../samples/ManageESUAssignments.csv).
