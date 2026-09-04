# CreateESULicense.ps1

Ce script crée ou met à jour une licence ESU Azure Arc pour Windows Server 2012, Windows Server 2012 R2 ou Windows Server 2016.

## Authentification par principal de service

    ./Scripts/windows/CreateESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "WS2016-Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8 -target "Windows Server 2016"

## Authentification par jeton utilisateur

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./Scripts/windows/CreateESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8 -userToken $authToken

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
| coreCount | Nombre pair de cœurs : 8 à 128 pour `vCore` ou 16 à 256 pour `pCore`. | Oui |
| target | Cible exacte de la licence : `Windows Server 2012`, `Windows Server 2012 R2` ou `Windows Server 2016`. La valeur par défaut est `Windows Server 2012` lorsque le paramètre est omis. | Non |
| userToken | Objet de jeton Microsoft Entra ID valide, utilisé à la place du principal de service. | Non* |

* Fournissez soit `tenantId`, `appID` et `clientSecret`, soit `userToken`. Si les deux méthodes sont fournies, le jeton utilisateur est utilisé.

Le script rejette les nombres de cœurs impairs ou hors limites; il ne calcule ni ne normalise la valeur.

Le script peut être réexécuté avec les mêmes paramètres de base pour modifier `state` ou `coreCount`. Les autres propriétés sont immuables après la création.

## Prérequis et éligibilité selon la cible

- Windows Server 2012/2012 R2 nécessite l'agent Azure Connected Machine version 1.34 ou ultérieure. Windows Server 2016 nécessite la version 1.62 ou ultérieure.
- Les ESU Windows Server 2016 prennent en charge les éditions Standard et Datacenter. L'éligibilité générale exige une Software Assurance (SA) éligible ou un abonnement serveur équivalent. Pour les charges de travail Windows Server 2016 exécutées localement, la SA est obligatoire. L'offre Windows Server 2016 n'est pas disponible avec SPLA, ne prend pas en charge la transition depuis les licences en volume et ne comporte aucun avantage documenté pour le développement/test Visual Studio.
- Les valeurs réservées `WS2012 VISUAL STUDIO DEV TEST`, `WS2012 DISASTER RECOVERY` et `WS2012 MULTIPURPOSE` s'appliquent uniquement au processus d'exception Windows Server 2012/R2 documenté par Microsoft. Ne les réutilisez pas pour Windows Server 2016 et ne considérez aucune étiquette comme un droit ou un mécanisme de contrôle de la facturation.
- Les serveurs avec Azure Arc utilisés pour ces ESU Windows Server ne sont actuellement pas disponibles dans Azure géré par 21Vianet.
- Pour Windows Server 2016, suivez les [instructions de préparation](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/prepare-extended-security-updates) Microsoft actuelles concernant le package de licences et la mise à jour de la pile de maintenance (SSU) applicables. Microsoft n'indique actuellement aucun article KB Windows Server 2016 sur cette page; ne remplacez pas cette référence par l'article KB de Windows Server 2012.

## Mesures de protection relatives à la facturation

La fin du support de Windows Server 2016 intervient le 12 janvier 2027 et la facturation des ESU Azure Arc commence le 13 janvier 2027. Une licence activée déclenche la facturation même si elle n'est attribuée à aucun serveur. L'inscription tardive ainsi que les licences ou les cœurs ajoutés après la fin du support sont rétrofacturés à partir de la date de fin du support applicable. La réactivation, la recréation, le changement de région et le changement de locataire sont également soumis à la rétrofacturation. La diminution du nombre de cœurs, la désactivation ou la suppression d'une licence peuvent continuer à entraîner des frais pendant un maximum de cinq jours calendaires. Consultez les [informations de facturation](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/billing-extended-security-updates) Microsoft actuelles avant toute activation ou modification.

## Aperçu et confirmation

Ajoutez `-WhatIf` pour prévisualiser la cible et l'opération sans envoyer la mise à jour REST Azure. Après vérification, exécutez sans `-WhatIf`. Ajoutez `-Confirm` pour demander une confirmation PowerShell avant la création ou la modification.

```powershell
./Scripts/windows/CreateESULicense.ps1 <paramètres> -WhatIf
./Scripts/windows/CreateESULicense.ps1 <paramètres> -Confirm
```

## Résolution des problèmes

| Message ou symptôme | Vérification recommandée |
| --- | --- |
| Jeton d'authentification absent ou expiré | Fournissez les trois paramètres du principal de service ou obtenez un nouvel objet de jeton avec `Get-AzAccessToken`. |
| Réponse `401` ou `403` | Vérifiez que l'identité peut créer ou modifier les licences ESU dans le groupe de ressources cible. |
| Réponse `404` | Vérifiez l'abonnement et le groupe de ressources de la licence. |
| Conflit ou propriété immuable | Conservez l'édition, le type de cœurs et la région de la licence existante; seules les propriétés prises en charge peuvent être modifiées. |
| Échec de validation du nombre de cœurs | Utilisez une valeur paire comprise entre 8 et 128 pour `vCore`, ou entre 16 et 256 pour `pCore`, avec une combinaison édition/type de cœurs prise en charge. |
| Le script retourne le code `1` | Lisez le dernier message d'échec, corrigez l'entrée ou l'autorisation, puis relancez avec `-WhatIf`. |