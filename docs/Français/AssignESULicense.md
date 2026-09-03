# AssignESULicense.ps1

Ce script affecte une licence ESU à un serveur Azure Arc spécifique.

## Authentification par principal de service

    ./AssignESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012" -location "EastUS"

## Authentification par jeton utilisateur

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./AssignESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012" -location "EastUS" -userToken $authToken

## Paramètres

| Paramètre | Description | Obligatoire |
| --- | --- | --- |
| subscriptionId | ID de l'abonnement Azure à utiliser. | Oui |
| tenantId | ID du locataire Microsoft Entra ID. | Non* |
| appID | ID d'application du principal de service. | Non* |
| clientSecret | Secret du principal de service. | Non* |
| licenseResourceGroupName | Groupe de ressources contenant la licence ESU. | Oui |
| licenseName | Nom de la licence ESU à affecter. | Oui |
| serverResourceGroupName | Groupe de ressources contenant le serveur Azure Arc. | Oui |
| ARCServerName | Nom du serveur Azure Arc. | Oui |
| location | Région Azure des objets Azure Arc. | Oui |
| userToken | Objet de jeton Microsoft Entra ID valide, utilisé à la place du principal de service. | Non* |
| unassign | Dissocie la licence au lieu de l'attribuer. `-u` est un alias. | Non |

* Fournissez soit `tenantId`, `appID` et `clientSecret`, soit `userToken`. Si les deux méthodes sont fournies, le jeton utilisateur est utilisé.

Ajoutez `-u` pour délier une licence existante. Sans `-u`, le script affecte la licence au serveur.

## Aperçu et confirmation

Ajoutez `-WhatIf` pour prévisualiser l'affectation ou la dissociation sans envoyer la mise à jour REST Azure. Après avoir vérifié la cible et l'action affichées, exécutez la commande sans `-WhatIf`. Ajoutez `-Confirm` pour demander une confirmation PowerShell avant la mise à jour.

```powershell
./AssignESULicense.ps1 <paramètres> -WhatIf
./AssignESULicense.ps1 <paramètres> -Confirm
```

## Résolution des problèmes

| Message ou symptôme | Vérification recommandée |
| --- | --- |
| Jeton d'authentification absent ou expiré | Fournissez les trois paramètres du principal de service ou obtenez un nouvel objet de jeton avec `Get-AzAccessToken`. |
| Réponse `401` ou `403` | Vérifiez que l'identité a accès au serveur Arc et aux ressources de licence ESU. |
| Réponse `404` | Vérifiez l'abonnement, les groupes de ressources, le nom du serveur et le nom de la licence. |
| Réponse de conflit | Vérifiez si une autre opération est en cours ou si l'affectation demandée existe déjà. |
| Le script retourne le code `1` | Lisez le dernier message d'échec, corrigez la ressource ou l'autorisation indiquée, puis relancez avec `-WhatIf`. |

