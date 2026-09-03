# CreateESULicense.ps1

Ce script crée ou met à jour une licence ESU.

## Authentification par principal de service

    ./CreateESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8

## Authentification par jeton utilisateur

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./CreateESULicense -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8 -userToken $authToken

## Paramètres

| Paramètre | Description | Obligatoire |
| --- | --- | --- |
| subscriptionId | ID de l'abonnement Azure à utiliser. | Oui |
| tenantId | ID du locataire Microsoft Entra ID. | Non* |
| appID | ID d'application du principal de service. | Non* |
| clientSecret | Secret du principal de service. | Non* |
| licenseResourceGroupName | Groupe de ressources qui contiendra la licence ESU. | Oui |
| licenseName | Nom de la licence ESU à créer. | Oui |
| location | Région Azure de la licence ESU. | Oui |
| state | État d'activation : `Activated` ou `Deactivated`. | Oui |
| edition | Édition : `Standard` ou `Datacenter`. | Oui |
| coreType | Type de cœurs : `vCore` ou `pCore`. | Oui |
| coreCount | Nombre de cœurs de la licence ESU. | Oui |
| userToken | Objet de jeton Microsoft Entra ID valide, utilisé à la place du principal de service. | Non* |

* Fournissez soit `tenantId`, `appID` et `clientSecret`, soit `userToken`. Si les deux méthodes sont fournies, le jeton utilisateur est utilisé.

Le script applique automatiquement les exigences minimales et paires relatives au nombre de cœurs.

Le script peut être réexécuté avec les mêmes paramètres de base pour modifier `state` ou `coreCount`. Les autres propriétés sont immuables après la création.

## Aperçu et confirmation

Ajoutez `-WhatIf` pour prévisualiser la cible et l'opération normalisée sans envoyer la mise à jour REST Azure. Après vérification, exécutez sans `-WhatIf`. Ajoutez `-Confirm` pour demander une confirmation PowerShell avant la création ou la modification.

```powershell
./CreateESULicense.ps1 <paramètres> -WhatIf
./CreateESULicense.ps1 <paramètres> -Confirm
```

## Résolution des problèmes

| Message ou symptôme | Vérification recommandée |
| --- | --- |
| Jeton d'authentification absent ou expiré | Fournissez les trois paramètres du principal de service ou obtenez un nouvel objet de jeton avec `Get-AzAccessToken`. |
| Réponse `401` ou `403` | Vérifiez que l'identité peut créer ou modifier les licences ESU dans le groupe de ressources cible. |
| Réponse `404` | Vérifiez l'abonnement et le groupe de ressources de la licence. |
| Conflit ou propriété immuable | Conservez l'édition, le type de cœurs et la région de la licence existante; seules les propriétés prises en charge peuvent être modifiées. |
| Échec de validation du nombre de cœurs | Utilisez un entier positif dans les limites acceptées par ce script et une combinaison édition/type de cœurs prise en charge. |
| Le script retourne le code `1` | Lisez le dernier message d'échec, corrigez l'entrée ou l'autorisation, puis relancez avec `-WhatIf`. |