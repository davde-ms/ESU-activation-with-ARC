# DeleteESULicense.ps1

Ce script supprime une licence ESU. La suppression rompt son association avec le serveur Azure Arc et arrête la facturation liée à cette licence.

> **La suppression puis la recréation d'une licence activée est fortement déconseillée, car elle peut avoir des conséquences de facturation. Vérifiez les exigences ESU applicables avant toute suppression.**

## Authentification par principal de service

    ./DeleteESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores"

## Authentification par jeton utilisateur

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./DeleteESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -userToken $authToken

## Paramètres

| Paramètre | Description | Obligatoire |
| --- | --- | --- |
| subscriptionId | ID de l'abonnement Azure à utiliser. | Oui |
| tenantId | ID du locataire Microsoft Entra ID. | Non* |
| appID | ID d'application du principal de service. | Non* |
| clientSecret | Secret du principal de service. | Non* |
| licenseResourceGroupName | Groupe de ressources contenant la licence ESU à supprimer. | Oui |
| licenseName | Nom de la licence ESU à supprimer. | Oui |
| userToken | Objet de jeton Microsoft Entra ID valide, utilisé à la place du principal de service. | Non* |

* Fournissez soit `tenantId`, `appID` et `clientSecret`, soit `userToken`. Si les deux méthodes sont fournies, le jeton utilisateur est utilisé.

