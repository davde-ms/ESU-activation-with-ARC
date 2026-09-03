# CheckESUStatus.ps1

Ce script vérifie l'état des licences ESU des serveurs avec Azure Arc. Il utilise des requêtes REST Azure en lecture seule et fournit des informations détaillées sur les attributions de licences ESU.

> **Remarque :** Ce script est en lecture seule. Il ne modifie ni les licences ESU ni les serveurs.

## Vérification d'un serveur avec un principal de service

```powershell
./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server"
```

## Vérification d'un serveur avec un jeton utilisateur

```powershell
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server" -userToken $authToken
```

## Vérification en bloc avec un fichier CSV

```powershell
./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -csvFilePath "C:\Temp\ARC Servers to Check.csv"
```

## Paramètres

| Paramètre | Description | Obligatoire |
| --- | --- | --- |
| subscriptionId | ID de l'abonnement contenant les serveurs avec Azure Arc. | Oui |
| tenantId | ID du locataire Microsoft Entra. | Non* |
| appID | ID d'application du principal de service. | Non* |
| clientSecret | Clé secrète du principal de service. | Non* |
| serverResourceGroupName | Groupe de ressources du serveur. Requis pour une vérification individuelle. | Non** |
| ARCServerName | Nom du serveur à vérifier. Requis pour une vérification individuelle. | Non** |
| location | Conservé pour assurer la compatibilité des lignes de commande existantes. La requête d'état en lecture seule ne l'utilise pas. | Non |
| csvFilePath | Chemin du fichier CSV. Requis pour le traitement en bloc. | Non*** |
| logFileName | Chemin facultatif du journal de transcription. | Non |
| userToken | Objet de jeton Microsoft Entra valide, utilisé à la place du principal de service. | Non* |
| exportCsvPath | Chemin facultatif du fichier CSV contenant les résultats. | Non |

- \* Fournissez soit `tenantId`, `appID` et `clientSecret`, soit `userToken`.
- \** Requis pour une vérification individuelle sans fichier CSV.
- \*** Requis pour un traitement en bloc.

Si les deux méthodes d'authentification sont fournies, `userToken` est utilisé.

> **Note de compatibilité :** Les lignes de commande existantes peuvent continuer à fournir `-location`, mais les nouvelles commandes peuvent l'omettre.

## Format du fichier CSV

Le fichier CSV utilisé avec `-csvFilePath` doit contenir les colonnes suivantes.

### Colonnes obligatoires

- **Name** ou **ARCServerName** : nom du serveur avec Azure Arc.
- **ServerResourceGroupName** : groupe de ressources contenant le serveur.

### Colonne facultative

- **SubscriptionId** : abonnement à utiliser pour cette ligne s'il diffère du paramètre du script.

| Name | ServerResourceGroupName | SubscriptionId |
| --- | --- | --- |
| WIN-2K12R2-01 | rg-arcservers | 00000000-0000-0000-0000-000000000001 |
| WIN-2K12R2-02 | rg-arcservers-prod | |
| SRV-DATABASE-01 | rg-database-servers | 00000000-0000-0000-0000-000000000004 |

Lorsque `SubscriptionId` n'est pas renseigné, le script utilise le paramètre `subscriptionId`.

## Informations de sortie

Le script peut renvoyer les états suivants :

- **Licensed** : le profil de licence du serveur contient l'ID de ressource d'une licence ESU attribuée. Cet état confirme uniquement l'attribution ; il ne vérifie pas indépendamment l'activation ou l'état d'approvisionnement de la licence référencée.
- **No License Assigned** : le profil ESU existe, mais aucune licence n'est attribuée.
- **No ESU Profile** : aucun profil ESU n'est configuré.
- **Error** : une erreur s'est produite pendant la vérification.

Pour chaque serveur, le script affiche le nom, le groupe de ressources et l'état. Lorsqu'une licence est attribuée, il affiche également le nom de la licence, son groupe de ressources et son URI Azure Resource Manager complète.

Le résumé indique le nombre total de serveurs vérifiés, le nombre de serveurs avec ou sans ID de ressource de licence attribuée et le nombre d'erreurs.

## Export des résultats

Utilisez `-exportCsvPath` pour exporter les résultats détaillés :

```powershell
./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -csvFilePath "C:\servers.csv" -exportCsvPath "C:\Results\ESU-Status-Report.csv"
```

Le fichier exporté contient les détails des serveurs et des licences, l'état, l'horodatage et les messages d'erreur. Une erreur d'export entraîne un code de sortie différent de zéro.

## Journalisation

Utilisez `-logFileName` pour créer un journal de transcription :

```powershell
./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server" -logFileName "C:\Logs\ESU-Check.log"
```

## Exemple de sortie

```text
==============================================
Starting ESU License Status Check
==============================================

[INFO] Total servers checked: 1
[SUCCESS] Servers with assigned ESU license resource IDs: 1
[INFO] Servers without ESU licenses: 0
[INFO] Servers with errors: 0
```

## Prérequis

1. PowerShell 7.x ou une version ultérieure.
2. Des serveurs intégrés à Azure Arc et visibles dans Azure.
3. Des informations d'authentification pour un principal de service ou un jeton obtenu avec Azure PowerShell.
4. Les droits permettant de lire les ressources de serveur et leurs profils de licence.

## Cas d'utilisation

- Audit des serveurs qui référencent un ID de ressource de licence ESU attribué.
- Gestion et dépannage des attributions de licences.
- Production de rapports sur les attributions de licences ESU.
- Planification à partir des attributions de licences actuelles.

## Gestion des erreurs

Le script gère notamment les cas suivants :

- Ressource ou profil de licence introuvable (`404`).
- Accès refusé (`403`).
- Échec de l'authentification ou jeton expiré.
- Fichier CSV absent, invalide ou contenant des lignes non valides.
- Échec de la requête réseau ou de l'export CSV.
