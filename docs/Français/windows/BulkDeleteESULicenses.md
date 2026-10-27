# BulkDeleteESULicenses.ps1

Ce script met hors service en bloc des ressources de licences ESU Windows Server (`Microsoft.HybridCompute/licenses`). Pour chaque licence sélectionnée, il dissocie chaque serveur avec Azure Arc auquel la licence est attribuée, confirme que chaque dissociation a pris effet, puis supprime la licence. Une licence est supprimée uniquement lorsque tous les serveurs découverts ont été dissociés avec succès.

Utilisez-le à la fin d'une période ESU. Par exemple, la période ESU de Windows Server 2012 et Windows Server 2012 R2 a pris fin le 13 octobre 2026, et Azure Arc a désactivé ces licences à minuit UTC le 14 octobre 2026. Les licences désactivées restent consultables jusqu'à leur suppression. Consultez [Déployer et gérer par programmation les licences Extended Security Updates activées par Azure Arc](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/api-extended-security-updates).

> **La suppression ou la désactivation d'une licence peut rester facturée pendant un maximum de cinq jours. Si vous supprimez puis recréez une licence ESU, la rétrofacturation continue de s'appliquer à la période correspondante; la suppression ne vous exonère pas de ces frais. Vérifiez l'incidence actuelle dans les [informations officielles sur la facturation ESU](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/billing-extended-security-updates#billing-associated-with-modifications-to-an-azure-arc-esu-license) avant de continuer.**

## Fonctionnement

1. **Sélection des licences.** Choisissez le mode CSV ou le mode découverte (voir ci-dessous). Seules les licences dont la `target` figure dans `-target` sont traitées. Par défaut, il s'agit de `Windows Server 2012` et `Windows Server 2012 R2`. Les licences Windows Server 2016 restent inchangées, sauf si `-target` inclut explicitement `Windows Server 2016`.
2. **Découverte des serveurs attribués.** Une requête Azure Resource Graph recherche les ressources `microsoft.hybridcompute/machines/licenseprofiles` dont `properties.esuProfile.assignedLicense` désigne une licence sélectionnée. La requête porte **uniquement sur l'abonnement qui contient la licence**.
3. **Export d'un inventaire.** Avant toute modification, le script écrit un fichier CSV qui répertorie chaque licence sélectionnée avec ses propriétés et ses serveurs attribués. Conservez ce fichier à des fins d'audit ou pour recréer une licence.
4. **Dissociation de chaque serveur.** Le script lit le profil de licence du serveur, puis envoie la [requête de dissociation documentée](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/api-extended-security-updates#unlink-a-license) : un `PUT` sur `licenseProfiles/default` avec l'emplacement et un `esuProfile` vide. Les étiquettes existantes du profil de licence sont conservées.
5. **Vérification.** Le script relit le profil de licence jusqu'à ce que la licence ne soit plus attribuée.
6. **Suppression.** La licence est supprimée uniquement si tous les serveurs découverts ont été dissociés et vérifiés. Sinon, l'erreur est journalisée, la licence est conservée et le script passe à la licence suivante.

### Serveurs ignorés

Chaque serveur Azure Arc possède un profil de licence (`licenseProfiles/default`). En plus de l'attribution ESU (`esuProfile`), il peut contenir deux autres paramètres qui ont une incidence sur les licences et la facturation :

| Paramètre | Description | Pourquoi un serveur ESU Windows Server 2012/R2 pourrait l'avoir |
| --- | --- | --- |
| `softwareAssurance.softwareAssuranceCustomer` | Attestation que le serveur est couvert par Software Assurance ou par une licence d'abonnement. Elle inscrit le serveur à [Windows Server Management activé par Azure Arc](https://learn.microsoft.com/fr-fr/azure/azure-arc/servers/windows-server-management-overview), de sorte que des services comme Azure Update Manager, Azure Change Tracking and Inventory et Azure Machine Configuration sont fournis sans frais supplémentaires. | Les serveurs inscrits aux ESU activées par Azure Arc bénéficient de certains de ces services sans frais supplémentaires tant qu'ils sont inscrits. Un client avec Software Assurance peut faire l'attestation pour que ces services restent gratuits après la période ESU. L'attestation peut être appliquée à grande échelle à de nombreux serveurs Arc, y compris des serveurs Windows Server 2012. |
| `productProfile` | Le [paiement à l'utilisation de Windows Server](https://learn.microsoft.com/fr-fr/windows-server/get-started/windows-server-pay-as-you-go) (`productType` = `WindowsServer`), qui facture la licence du système d'exploitation par cœur au moyen d'Azure, et des fonctionnalités de produit comme `Hotpatch`. Le produit et chaque fonctionnalité ont un `subscriptionStatus`. | Le paiement à l'utilisation et Hotpatch exigent Windows Server 2025; un serveur qui exécute encore Windows Server 2012 ne devrait donc pas les avoir actifs. Ils peuvent apparaître lorsqu'un serveur a été mis à niveau sur place en conservant la même ressource Arc et la même attribution ESU, ou sous forme de résidus inactifs (un statut `Disabled` ou d'anciennes dates d'inscription) d'une inscription antérieure. |

La requête de dissociation documentée n'inclut pas ces paramètres, et Microsoft ne précise pas si leur omission les conserve ou les réinitialise. S'ils étaient réinitialisés, le serveur pourrait perdre ses services de gestion sans frais ou sa licence de système d'exploitation en paiement à l'utilisation. Pour éviter une modification involontaire, le script ignore un serveur lorsque son profil de licence contient un paramètre **actif** :

| Valeur dans le profil de licence | Résultat |
| --- | --- |
| `softwareAssuranceCustomer` vaut `true`, ou toute valeur autre que `false` | Ignoré |
| `productProfile.subscriptionStatus`, ou le `subscriptionStatus` d'un élément de `productFeatures`, a une valeur autre que `Disabled` : `Enabled`, `Enabling`, `Disabling`, `Failed`, `Unknown` ou une valeur non reconnue | Ignoré |
| Un `productType` ou un `name` de fonctionnalité sans `subscriptionStatus` | Ignoré, car l'état est inconnu |
| Tout autre champ non vide de `productProfile` ou d'une fonctionnalité que Microsoft ne documente pas | Ignoré |
| `softwareAssuranceCustomer` vaut `false` ou est absent | Dissocié |
| `subscriptionStatus` vaut `Disabled` | Dissocié. Microsoft indique que la facturation du paiement à l'utilisation s'arrête après sa désactivation. |
| Champs d'historique en lecture seule : `enrollmentDate`, `disenrollmentDate`, `billingStartDate`, `billingEndDate` et `error` | Non pris en compte |

Lorsqu'un serveur est ignoré, son attribution ESU est conservée, la licence n'est pas supprimée et elle est signalée comme ayant échoué. Le message indique les paramètres actifs, par exemple `softwareAssurance.softwareAssuranceCustomer=True` ou `productProfile.productFeatures[Hotpatch].subscriptionStatus=Enabled`. Exécutez le script avec `-DryRun` pour voir quels serveurs seraient ignorés avant toute modification.

Pour traiter un serveur ignoré, examinez ses paramètres dans le portail Azure et dissociez manuellement la licence ESU. Vérifiez ensuite que son attestation Software Assurance et ses paramètres de paiement à l'utilisation et Hotpatch sont inchangés, puis exécutez de nouveau le script.

Un serveur déjà dissocié, ou désormais attribué à une autre licence, reste inchangé et ne bloque pas la suppression.

### Limites de la découverte des attributions

- La découverte porte uniquement sur l'abonnement qui contient chaque licence. Si un serveur d'un autre abonnement utilise la licence, il n'est pas détecté, son attribution est conservée et la licence est tout de même supprimée. Le script affiche un avertissement à ce sujet à chaque exécution.
- Azure Resource Graph retourne uniquement les ressources que l'identité peut lire, et ses données peuvent refléter les modifications récentes avec un léger délai. Examinez l'inventaire et utilisez [CheckESUStatus.ps1](CheckESUStatus.md) pour les serveurs dont vous n'êtes pas certain.
- La valeur `assignedLicenses` de la licence est consignée dans l'inventaire à titre d'information seulement. Microsoft la décrit comme « le nombre de licences attribuées » et non comme un nombre de serveurs; le script ne l'utilise donc pour aucune décision.

## Authentification

Utilisez soit les informations d'identification d'un principal de service, soit un jeton Microsoft Entra fourni par l'utilisateur. Si les deux sont fournis, `-userToken` est utilisé.

### Principal de service

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "votre_valeur_secrète_application" -licenseResourceGroupName "rg-ARC-ESULicenses" -DryRun
```

### Jeton utilisateur

```powershell
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -userToken $authToken -DryRun
```

## Sélection des licences

### Mode découverte

Fournissez `-licenseSubscriptionId` sans `-csvFilePath`. Chaque licence ESU de l'abonnement, ou uniquement de `-licenseResourceGroupName` lorsque vous le fournissez, est évaluée par rapport à `-target`.

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -userToken $authToken
```

### Mode CSV

Fournissez `-csvFilePath`. Partez du [modèle CSV BulkDeleteESULicenses](../../../samples/BulkDeleteESULicenses.csv). Tous les noms et ID d'abonnement inclus sont fictifs et doivent être remplacés.

| Colonne | Obligatoire | Description |
| --- | --- | --- |
| LicenseName | Oui | Nom de la ressource de licence ESU. |
| LicenseResourceGroupName | Oui | Groupe de ressources qui contient la licence. |
| LicenseSubscriptionId | Non | Abonnement qui contient la licence de cette ligne. Remplace `-licenseSubscriptionId`. |

Une ligne sans `LicenseSubscriptionId` utilise `-licenseSubscriptionId`; si aucune des deux valeurs n'est fournie, la validation de la ligne échoue. Les lignes en double sont ignorées. Une licence listée dont la cible n'est pas sélectionnée par `-target` est signalée comme exclue et reste inchangée.

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 -licenseSubscriptionId "00000000-0000-0000-0000-000000000001" -csvFilePath "C:\Temp\LicencesESUASupprimer.csv" -userToken $authToken
```

## Paramètres

| Paramètre | Description | Obligatoire |
| --- | --- | --- |
| licenseSubscriptionId | Abonnement qui contient les licences. Obligatoire en mode découverte; en mode CSV, valeur par défaut des lignes sans `LicenseSubscriptionId`. Alias : `licenseSub`, `subscriptionId`. | Découverte : Oui / CSV : Non |
| licenseResourceGroupName | Mode découverte uniquement. Limite la découverte à un groupe de ressources. Alias : `lrg`. | Non |
| csvFilePath | Mode CSV. Chemin du fichier CSV qui répertorie les licences. Alias : `csv`. | CSV : Oui |
| target | Cibles de licence pouvant être supprimées : `Windows Server 2012`, `Windows Server 2012 R2`, `Windows Server 2016`. Valeur par défaut : `Windows Server 2012`, `Windows Server 2012 R2`. | Non |
| location | Région de repli pour la requête de dissociation, utilisée uniquement lorsqu'un profil de licence ne retourne pas son emplacement. Alias : `l`. | Non |
| tenantId | ID du locataire Microsoft Entra utilisé pour l'authentification par principal de service. | Non\* |
| appID | ID d'application utilisé pour l'authentification par principal de service. | Non\* |
| clientSecret | Secret client utilisé pour l'authentification par principal de service. Alias : `s`, `secret`, `sec`. | Non\* |
| userToken | Objet de jeton retourné par `Get-AzAccessToken`. Alias : `token`. | Non\* |
| inventoryFilePath | Chemin du fichier CSV d'inventaire avant modification. Valeur par défaut : `ESULicenseDeletionInventory-<horodatage>.csv` dans le répertoire courant. Alias : `inventory`. | Non |
| logFileName | Chemin facultatif du journal de transcription. Alias : `log`. | Non |
| DryRun | Valide tout sans envoyer de requête `PUT` ou `DELETE`. Alias : `Preview`. | Non |

\* Fournissez soit `tenantId`, `appID` et `clientSecret`, soit `userToken`.

## Aperçu, confirmation et automatisation

Commencez toujours par un aperçu. Les deux modes d'aperçu n'envoient que des requêtes de lecture (requêtes `GET` et `POST` de la requête Resource Graph), lisent chaque profil de licence pour indiquer quels serveurs seraient dissociés ou ignorés, et écrivent le fichier d'inventaire.

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 <paramètres> -DryRun
./Scripts/windows/BulkDeleteESULicenses.ps1 <paramètres> -WhatIf
```

Une exécution réelle demande une confirmation **pour chaque licence**, par exemple *Unlink 3 Arc server(s), then delete ESU license*. Répondez oui, oui pour tout, non ou non pour tout. Une licence refusée et ses attributions restent inchangées. Pour une exécution sans surveillance déjà examinée, ajoutez `-Confirm:$false`.

```powershell
./Scripts/windows/BulkDeleteESULicenses.ps1 <paramètres> -Confirm:$false
```

## Inventaire avant modification

L'inventaire contient une ligne par licence et serveur attribué, et une ligne pour chaque licence sans attribution découverte. Les colonnes comprennent le nom de la licence, le groupe de ressources, l'ID d'abonnement, l'ID de ressource, l'emplacement, la cible, l'état, l'édition, le type de cœur, le nombre de processeurs, `assignedLicenses`, l'ID immuable, l'objet `licenseDetails` complet et les étiquettes au format JSON, ainsi que le nom, le groupe de ressources, l'ID d'abonnement, l'emplacement et l'ID du profil de licence de chaque serveur. Le fichier contient des ID d'abonnement et de ressource; stockez-le conformément aux règles de traitement des données de votre organisation.

L'inventaire est écrit dans tous les modes, y compris `-DryRun` et `-WhatIf`. S'il ne peut pas être écrit, le script s'arrête avant toute modification.

## Autorisations requises

L'identité a besoin des actions suivantes sur l'étendue des licences et sur l'étendue de chaque serveur Arc attribué :

- `Microsoft.HybridCompute/licenses/read`
- `Microsoft.HybridCompute/licenses/delete`
- `Microsoft.HybridCompute/machines/licenseProfiles/read`
- `Microsoft.HybridCompute/machines/licenseProfiles/write`
- `Microsoft.ResourceGraph/resources/read`, pour soumettre la requête Azure Resource Graph. Resource Graph retourne uniquement les ressources que l'identité peut lire.

Le rôle personnalisé [ARC ESU License Administrator](../../../Custom%20Roles/ARC%20ESU%20License%20Administrator.json) inclut ces actions.

## Codes de sortie

| Code | Signification |
| --- | --- |
| `0` | Chaque licence traitée a réussi, ou rien n'était à traiter. Les licences exclues ou refusées ne sont pas des échecs. |
| `1` | Erreur fatale : authentification, fichier CSV, découverte des licences ou export de l'inventaire. Aucune licence n'a été modifiée. |
| `2` | Échec partiel : au moins une licence n'a pas pu être trouvée, dissociée, vérifiée ou supprimée. Les licences réussies ont tout de même été traitées. |

## Résolution des problèmes

| Message ou symptôme | Vérification recommandée |
| --- | --- |
| Jeton d'authentification absent ou expiré | Fournissez les trois paramètres du principal de service ou obtenez un nouvel objet de jeton avec `Get-AzAccessToken`. |
| `The license profile also has active settings: ...` | Le serveur a été ignoré volontairement. Examinez les paramètres Software Assurance et de profil de produit indiqués, dissociez la licence manuellement, puis exécutez de nouveau le script. Consultez [Serveurs ignorés](#serveurs-ignorés). |
| `Target '...' is not selected by -target` | La licence a été exclue. Ajoutez sa cible à `-target` uniquement si vous souhaitez la supprimer. |
| `The license was not found` | Vérifiez le nom, le groupe de ressources et l'abonnement de la ligne CSV. |
| `Assigned servers could not be discovered` | Vérifiez que l'identité peut soumettre des requêtes Resource Graph et lire les profils de licence dans l'abonnement des licences. |
| `still assigned after ... verification attempt(s)` | Azure a accepté la dissociation, mais ne l'a pas appliquée à temps. Vérifiez le serveur avec [CheckESUStatus.ps1](CheckESUStatus.md), puis exécutez de nouveau le script. |
| Réponse `401` ou `403` | Vérifiez les autorisations ci-dessus sur l'étendue des licences et sur celle des serveurs. Les ID figurant dans les messages d'erreur Azure sont affichés sous la forme `<redacted-id>`; les noms des groupes de ressources et des ressources restent visibles. |
| Le script retourne le code `2` | Examinez le tableau récapitulatif, corrigez chaque licence en échec, puis prévisualisez de nouveau avec `-DryRun` ou `-WhatIf`. |
