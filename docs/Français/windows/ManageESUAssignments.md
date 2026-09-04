# ManageESUAssignmentsFR.ps1

Ce script attribue ou dissocie en bloc des licences ESU existantes à partir d'un fichier CSV. Il permet d'attribuer une même licence à plusieurs serveurs avec Azure Arc et prend en charge les licences stockées dans un abonnement différent de celui des serveurs.

## Compatibilité avec Windows Server 2016

Les opérations d'attribution et de dissociation en bloc sont indépendantes de la cible et prennent en charge les ID de ressources de licences ESU Windows Server 2012, Windows Server 2012 R2 et Windows Server 2016 existantes. Le script ne comporte aucun paramètre de cible, son CSV ne comporte aucune colonne de cible et il n'inspecte ni ne valide le système d'exploitation local de chaque serveur. Sélectionnez une licence éligible pour chaque génération de serveur; Azure peut rejeter une association incompatible. Consultez les [instructions Microsoft actuelles de préparation et d'éligibilité aux ESU Windows Server](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prepare-extended-security-updates) avant l'attribution.

## Authentification

Utilisez soit les informations d'identification d'un principal de service, soit un jeton Microsoft Entra fourni par l'utilisateur.

### Principal de service

```powershell
./Scripts/windows/ManageESUAssignmentsFR.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"
```

### Jeton utilisateur

```powershell
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./Scripts/windows/ManageESUAssignmentsFR.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv" -userToken $authToken
```

Si les deux méthodes d'authentification sont fournies, `-userToken` est utilisé.

## Paramètres

| Paramètre | Description |
| --- | --- |
| arcServerSubscriptionId | Abonnement contenant les serveurs avec Azure Arc. `-subscriptionId` reste disponible comme alias pour la compatibilité descendante. |
| licenseSubscriptionId | Abonnement facultatif contenant les licences ESU. Utilisé lorsqu'une ligne CSV ne fournit pas `LicenseSubscriptionId`. |
| tenantId | ID du locataire Microsoft Entra utilisé pour l'authentification par principal de service. |
| appID | ID d'application utilisé pour l'authentification par principal de service. |
| clientSecret | Clé secrète utilisée pour l'authentification par principal de service. |
| location | Région Azure utilisée par la requête d'attribution. |
| csvFilePath | Chemin du fichier CSV d'attribution. |
| logFileName | Chemin facultatif du journal de transcription. |
| userToken | Objet de jeton renvoyé par `Get-AzAccessToken`. |
| DryRun | Valide les entrées et l'accès aux ressources sans envoyer de requête de modification. `-Preview` est un alias. |

## Attributions inter-abonnements

Utilisez `-licenseSubscriptionId` lorsque toutes les licences se trouvent dans un autre abonnement :

```powershell
./Scripts/windows/ManageESUAssignmentsFR.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseSubscriptionId "00000000-0000-0000-0000-000000000004" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"
```

L'abonnement de la licence est sélectionné dans l'ordre suivant :

1. La valeur `LicenseSubscriptionId` de la ligne CSV.
2. Le paramètre `-licenseSubscriptionId`.
3. L'abonnement du serveur Azure Arc fourni avec `-arcServerSubscriptionId`.

L'identité doit disposer des droits requis dans les deux abonnements lorsqu'ils sont différents.

## Format du fichier CSV

Le fichier CSV doit être créé manuellement.

Commencez avec le [modèle CSV ManageESUAssignments](../../../samples/ManageESUAssignments.csv) prêt à copier. Tous les noms et ID d'abonnement fournis sont fictifs et doivent être remplacés.

| Colonne | Obligatoire | Description |
| --- | --- | --- |
| Name ou ARCServerName | Oui | Nom du serveur avec Azure Arc. |
| ServerResourceGroupName | Oui | Groupe de ressources contenant le serveur. |
| LicenseName | Oui | Nom de la licence ESU existante. |
| LicenseResourceGroupName | Oui | Groupe de ressources contenant la licence ESU. |
| AssignESULicense | Oui | `True` attribue la licence; `False` la dissocie. |
| LicenseSubscriptionId | Non | Abonnement contenant la licence de cette ligne. Remplace la valeur de la ligne de commande. |

![Exemple CSV de gestion des attributions ESU](../../../media/ManageESUAssignments_CSV_example.jpg)

## Mode de simulation

Ajoutez `-DryRun` pour valider les données CSV, l'authentification et l'accès aux ressources avant d'appliquer les attributions :

```powershell
./Scripts/windows/ManageESUAssignmentsFR.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv" -DryRun
```

Le mode de simulation peut envoyer des requêtes `GET` en lecture seule afin de valider l'accès et l'existence des ressources. Il n'envoie aucune requête `PUT`, `PATCH` ou `DELETE`.

## WhatIf et confirmation

Utilisez `-WhatIf` pour l'aperçu PowerShell standard. Il effectue la même validation des ressources en lecture seule que `-DryRun`, affiche chaque attribution ou dissociation proposée et n'envoie aucune requête de modification. Utilisez `-Confirm` pour approuver chaque opération pendant une exécution réelle.

```powershell
./Scripts/windows/ManageESUAssignmentsFR.ps1 <paramètres> -WhatIf
./Scripts/windows/ManageESUAssignmentsFR.ps1 <paramètres> -Confirm
```

## Résolution des problèmes

| Message ou symptôme | Vérification recommandée |
| --- | --- |
| Échec de validation du CSV | Repartez du modèle et vérifiez les en-têtes obligatoires, les noms de serveur, les groupes de ressources, les noms de licence et les valeurs d'action `True`/`False`. |
| Jeton d'authentification absent ou expiré | Fournissez les trois paramètres du principal de service ou obtenez un nouvel objet de jeton avec `Get-AzAccessToken`. |
| Échec de validation de l'accès aux ressources | Vérifiez que l'identité peut lire le profil de licence Arc et, pour une attribution, la licence ESU dans l'abonnement résolu. |
| Réponse `401` ou `403` | Vérifiez les autorisations dans les abonnements du serveur et de la licence. |
| Réponse `404` | Vérifiez les groupes de ressources, les noms et le champ facultatif `LicenseSubscriptionId` de chaque ligne. |
| Le récapitulatif signale des échecs | Corrigez chaque ligne en échec, puis relancez tout le CSV avec `-DryRun` ou `-WhatIf` avant une exécution réelle. |
