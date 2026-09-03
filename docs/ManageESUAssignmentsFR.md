# ManageESUAssignments.ps1

Ce script attribue ou dissocie en bloc des licences ESU existantes à partir d'un fichier CSV. Il permet d'attribuer une même licence à plusieurs serveurs avec Azure Arc et prend en charge les licences stockées dans un abonnement différent de celui des serveurs.

## Authentification

Utilisez soit les informations d'identification d'un principal de service, soit un jeton Microsoft Entra fourni par l'utilisateur.

### Principal de service

```powershell
./ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"
```

### Jeton utilisateur

```powershell
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv" -userToken $authToken
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
| DryRun | Valide les entrées et l'accès aux ressources sans envoyer de requête de modification. |

## Attributions inter-abonnements

Utilisez `-licenseSubscriptionId` lorsque toutes les licences se trouvent dans un autre abonnement :

```powershell
./ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseSubscriptionId "00000000-0000-0000-0000-000000000004" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"
```

L'abonnement de la licence est sélectionné dans l'ordre suivant :

1. La valeur `LicenseSubscriptionId` de la ligne CSV.
2. Le paramètre `-licenseSubscriptionId`.
3. L'abonnement du serveur Azure Arc fourni avec `-arcServerSubscriptionId`.

L'identité doit disposer des droits requis dans les deux abonnements lorsqu'ils sont différents.

## Format du fichier CSV

Le fichier CSV doit être créé manuellement.

| Colonne | Obligatoire | Description |
| --- | --- | --- |
| Name ou ARCServerName | Oui | Nom du serveur avec Azure Arc. |
| ServerResourceGroupName | Oui | Groupe de ressources contenant le serveur. |
| LicenseName | Oui | Nom de la licence ESU existante. |
| LicenseResourceGroupName | Oui | Groupe de ressources contenant la licence ESU. |
| AssignESULicense | Oui | `True` attribue la licence; `False` la dissocie. |
| LicenseSubscriptionId | Non | Abonnement contenant la licence de cette ligne. Remplace la valeur de la ligne de commande. |

![Exemple de fichier CSV](../media/ManageESUAssignments_CSV_example.jpg)

## Mode de simulation

Ajoutez `-DryRun` pour valider les données CSV, l'authentification et l'accès aux ressources avant d'appliquer les attributions :

```powershell
./ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv" -DryRun
```

Le mode de simulation peut envoyer des requêtes `GET` en lecture seule afin de valider l'accès et l'existence des ressources. Il n'envoie aucune requête `PUT`, `PATCH` ou `DELETE`.
