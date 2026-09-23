# ESU SQL Server activées par Azure Arc

## Commencer par le modèle d'objets

Les ESU SQL Server n'utilisent normalement pas le modèle de création et d'attribution de licences ESU Windows Server. Les scripts de ce dépôt implémentent un abonnement par machine Arc/environnement de système d'exploitation (OSE). Ils mettent à jour l'extension `WindowsAgent.SqlServer` et ne créent aucune ressource de licence ESU SQL distincte.

```text
Groupe de ressources contenant la machine Arc
└── Microsoft.HybridCompute/machines/{machine}
    └── extensions/WindowsAgent.SqlServer
        └── settings.enableExtendedSecurityUpdates = true
```

Si la machine Arc représente une machine virtuelle, l'OSE est cette machine virtuelle invitée et Azure mesure les vCœurs qu'elle voit. Azure ne mesure pas tous les cœurs de l'hyperviseur physique. Si SQL Server est installé directement sur un serveur physique avec Azure Arc sans machines virtuelles, Azure mesure les cœurs physiques visibles par cet OSE.

## Choisir le modèle ESU SQL

| Déploiement | Modèle de facturation Microsoft | Prise en charge par le dépôt |
| --- | --- | --- |
| SQL Server dans une machine virtuelle connectée à Arc | Cœurs virtuels visibles par l'OSE invité de chaque machine virtuelle; minimum documenté de quatre cœurs | Pris en charge |
| SQL Server directement sur un serveur physique connecté à Arc sans machines virtuelles | Cœurs physiques visibles par cet OSE; minimum documenté de quatre cœurs | Pris en charge |
| SQL Server dans des machines virtuelles couvertes par la virtualisation illimitée par cœurs physiques | Ressource étendue `Microsoft.AzureArcData/sqlServerEsuLicenses` distincte; minimum documenté de 16 cœurs physiques | Non implémenté |

Pour les deux premiers modèles, il n'existe aucun `LicenseName`, groupe de ressources de licence, type de cœur ou nombre de cœurs saisi par le client. L'extension Azure pour SQL Server détecte le type d'hôte, les cœurs, les versions SQL et les éditions. Plusieurs instances éligibles de la même version SQL sur un OSE partagent un compteur fondé sur l'édition la plus élevée. SQL Server 2014 et SQL Server 2016 sur le même OSE peuvent produire des compteurs distincts.

<a id="sql-license-type"></a>
## LicenseType décrit la licence du logiciel SQL Server

`LicenseType` n'indique pas si les frais ESU sont déjà payés. Il décrit le mode de licence du logiciel SQL Server sous-jacent et détermine si cette installation est éligible à un abonnement ESU activé par Azure Arc.

| Valeur de l'extension | Mode de licence du logiciel SQL Server sous-jacent | Effet sur les ESU activées par Azure Arc |
| --- | --- | --- |
| `Paid` | Apportez votre propre licence Standard ou Enterprise avec Software Assurance active, ou utilisez un abonnement SQL Server actif. L'utilisation du logiciel SQL est déclarée au moyen d'un compteur horaire gratuit. | Éligible à l'activation des ESU. `Paid` n'inclut ni ne prépaie les frais ESU; l'activation des ESU démarre une mesure ESU distincte. |
| `PAYG` | Abonnez-vous à la licence du logiciel SQL Server Standard ou Enterprise par l'intermédiaire d'Azure et payez ce logiciel sur un compteur horaire. | Éligible à l'activation des ESU. L'utilisation ESU est mesurée séparément du compteur PAYG du logiciel SQL. |
| `LicenseOnly` | Utilisez une licence perpétuelle Standard ou Enterprise sans Software Assurance, une édition gratuite Developer/Evaluation/Express ou une licence de fournisseur applicable telle que SPLA. | Non éligible à un abonnement ESU activé par Azure Arc. Une licence éligible avec Software Assurance/abonnement SQL ou le mode `PAYG` pour le logiciel SQL est nécessaire. |

Deux paramètres indépendants de l'extension interviennent :

```text
LicenseType                       Mode de licence du logiciel SQL Server sous-jacent
enableExtendedSecurityUpdates    Activation ou non de l'abonnement ESU SQL distinct
```

La modification de `LicenseType` peut modifier la facturation du logiciel SQL Server et les droits d'utilisation. La modification de `enableExtendedSecurityUpdates` contrôle l'abonnement ESU. Examinez et approuvez chaque modification indépendamment; n'interprétez jamais `Paid` comme « ESU payées ». Dans ce dépôt, [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) ne définit ni ne modifie jamais `LicenseType`; il modifie uniquement `enableExtendedSecurityUpdates` et exige que l'hôte soit déjà `Paid` ou `PAYG`. [InstallSQLServerArcExtension.ps1](InstallSQLServerArcExtension.md) définit `LicenseType` uniquement lorsqu'il installe une extension absente, et seulement à `Paid` ou `LicenseOnly`. Aucun script de ce dépôt ne sélectionne `PAYG`; effectuez tout changement de type de licence séparément, après une décision de licence.

## Comparaison avec les ESU Windows Server

```text
ESU Windows Server
Groupe de ressources de licence                  Groupe de ressources de machine Arc
└── Microsoft.HybridCompute/licenses ───────────> machine/licenseProfile

ESU SQL Server implémentées ici
Groupe de ressources de machine Arc
└── machine/extension/WindowsAgent.SqlServer ───> paramètre d'abonnement ESU
```

Les scripts Windows Server créent et attribuent des ressources `Microsoft.HybridCompute/licenses` explicites. Ces licences et les machines Arc peuvent se trouver dans des groupes de ressources différents; les procédures prises en charge par le dépôt conservent aussi des ID d'abonnement explicites pour les attributions inter-abonnements.

La procédure SQL implémentée n'a aucune relation d'attribution ni aucun groupe de ressources de licence. Activer les ESU SQL signifie modifier un paramètre de l'extension enfant de la machine Arc.

## Groupes de ressources et autorisations

`ServerResourceGroupName` désigne toujours le groupe de ressources contenant la ressource `Microsoft.HybridCompute/machines` cible.

- Attribuez **SQL Server Arc ESU Reader** au niveau de l'abonnement, car l'état des fournisseurs et l'inventaire SQL sont des lectures au niveau de l'abonnement.
- Attribuez **SQL Server Arc ESU Operator** à chaque groupe de ressources contenant des machines Arc que l'identité modifiera. Le rôle écrit uniquement dans `Microsoft.HybridCompute/machines/extensions`.
- N'attribuez pas ces rôles à un groupe de ressources de licence SQL distinct pour cette procédure; aucun groupe de ce type n'est utilisé.
- Si les machines Arc cibles sont réparties dans plusieurs groupes de ressources, attribuez Operator à chaque groupe de machines ou choisissez délibérément une étendue commune plus large après avoir examiné l'augmentation des autorisations.

Les rôles fournis n'accordent aucune autorisation de gestion de `sqlServerEsuLicenses`.

## La virtualisation illimitée constitue une procédure distincte

Microsoft documente une option de virtualisation illimitée par cœurs physiques qui crée une ressource `Microsoft.AzureArcData/sqlServerEsuLicenses`. Son `scopeType` peut être `ResourceGroup`, `Subscription` ou `Tenant`. Une licence étendue à un abonnement ou à un locataire peut donc couvrir des machines virtuelles Arc éligibles dans des groupes de ressources différents de celui contenant la ressource de licence, à condition que chaque machine virtuelle appartienne à l'étendue et respecte les autres exigences Microsoft.

Cette ressource ne remplace pas la configuration des machines virtuelles : les machines virtuelles prévues doivent toujours être connectées à Arc, abonnées aux ESU et configurées pour utiliser la licence par cœurs physiques. Ce dépôt ne crée, ne met à jour, ne résilie, ne supprime et n'applique pas cette ressource.

## Procédure implémentée par ce dépôt

1. Générez ou préparez le CSV cible avec [CheckSQLServerESUStatus.kql](../../../samples/CheckSQLServerESUStatus.kql) ou le modèle applicable.
2. Exécutez [TestSQLServerArcESUPrerequisites.ps1](TestSQLServerArcESUPrerequisites.md).
3. Si nécessaire, exécutez [InstallSQLServerArcExtension.ps1](InstallSQLServerArcExtension.md).
4. Exécutez [CheckSQLServerESUStatus.ps1](CheckSQLServerESUStatus.md).
5. Prévisualisez puis exécutez [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md). Il conserve le `LicenseType` actuel sans modification.
6. Exécutez de nouveau la vérification d'état.

Utilisez `Enable` et `Disable` pour le cycle de vie de l'abonnement SQL. Réservez les termes créer, attribuer, dissocier et supprimer aux ressources de licence Windows Server ou à la ressource SQL mutualisée par cœurs physiques distincte.

## Documentation Microsoft officielle

- [Extended Security Updates SQL Server activées par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates)
- [S'abonner aux ESU SQL Server par cœurs virtuels](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-virtual-cores)
- [S'abonner par cœurs physiques sans machines virtuelles](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-physical-cores-without-using-vms)
- [S'abonner par cœurs physiques avec virtualisation illimitée](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-physical-cores-with-unlimited-virtualization)
- [Types de licences pour SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing#license-types)
- [Configurer SQL Server activé par Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration)