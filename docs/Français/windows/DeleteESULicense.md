# DeleteESULicense.ps1

Ce script supprime une licence ESU. La suppression rompt son association avec le serveur Azure Arc et arrête la facturation liée à cette licence.

> **La suppression ou la désactivation d'une licence peut rester facturée pendant un maximum de cinq jours calendaires. Si vous supprimez puis recréez une licence ESU, la rétrofacturation continue de s'appliquer à la période correspondante; la suppression ne vous exonère pas de ces frais. Vérifiez l'incidence actuelle dans les [informations officielles sur la facturation ESU](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates#billing-associated-with-modifications-to-an-azure-arc-esu-license) avant de continuer.**

## Compatibilité avec Windows Server 2016

La suppression est indépendante de la cible et prend en charge les ressources de licences ESU Windows Server 2012, Windows Server 2012 R2 et Windows Server 2016. Ce script ne comporte aucun paramètre de cible et n'inspecte ni ne valide le système d'exploitation local d'un serveur précédemment associé. Confirmez l'ID de ressource de la licence, son état d'attribution et l'incidence sur la facturation avant la suppression.

## Authentification par principal de service

    ./Scripts/windows/DeleteESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores"

## Authentification par jeton utilisateur

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./Scripts/windows/DeleteESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -userToken $authToken

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

## Aperçu et confirmation

Commencez toujours par `-WhatIf`. La commande affiche la licence qui serait supprimée sans envoyer la suppression REST Azure. Exécutez sans `-WhatIf` uniquement après avoir vérifié la cible; ajoutez `-Confirm` pour une confirmation PowerShell interactive.

```powershell
./Scripts/windows/DeleteESULicense.ps1 <paramètres> -WhatIf
./Scripts/windows/DeleteESULicense.ps1 <paramètres> -Confirm
```

## Résolution des problèmes

| Message ou symptôme | Vérification recommandée |
| --- | --- |
| Jeton d'authentification absent ou expiré | Fournissez les trois paramètres du principal de service ou obtenez un nouvel objet de jeton avec `Get-AzAccessToken`. |
| Réponse `401` ou `403` | Vérifiez que l'identité peut supprimer les licences ESU dans le groupe de ressources cible. |
| Réponse `404` | Vérifiez l'abonnement, le groupe de ressources et le nom de la licence; confirmez que la licence existe toujours. |
| Réponse de conflit | Vérifiez si la licence est encore affectée ou si une autre opération est en cours. |
| Le script retourne le code `1` | Lisez le dernier message d'échec et corrigez-le avant de réessayer; prévisualisez la commande corrigée avec `-WhatIf`. |
