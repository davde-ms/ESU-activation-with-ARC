# SQL Server ESUs enabled by Azure Arc

> [!IMPORTANT]
> **Check `LicenseType` before you try to enable ESUs.** Onboarding can leave the extension's `LicenseType` empty (`Configuration needed`), and an empty value blocks ESU enrollment. No ESU script in this repository fills it in for you. See [How LicenseType gets populated](#how-licensetype-gets-populated) and, after a licensing decision, use [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md).

## Start with the object model

SQL Server ESUs do not normally use the Windows Server ESU license creation and assignment model. The scripts in this repository implement a subscription per Arc machine/operating system environment (OSE). They update the `WindowsAgent.SqlServer` extension and create no separate SQL ESU license resource.

```text
Resource group containing the Arc machine
└── Microsoft.HybridCompute/machines/{machine}
    └── extensions/WindowsAgent.SqlServer
        └── settings.enableExtendedSecurityUpdates = true
```

If the Arc machine represents a VM, the OSE is that guest VM and Azure meters its visible vCores. It does not meter all cores of the physical hypervisor. If SQL Server is installed directly on a physical Arc-enabled server without VMs, Azure meters the physical cores visible to that OSE.

## Choose the SQL ESU model

| Deployment | Microsoft billing model | Repository support |
| --- | --- | --- |
| SQL Server in an Arc-connected VM | Per-VM virtual cores visible to the guest OSE; documented minimum of four cores | Supported |
| SQL Server directly on an Arc-connected physical server without VMs | Physical cores visible to that OSE; documented minimum of four cores | Supported |
| SQL Server in VMs covered through physical-core unlimited virtualization | Separate scoped `Microsoft.AzureArcData/sqlServerEsuLicenses` resource; documented minimum of 16 physical cores | Not implemented |

For the first two models, there is no `LicenseName`, license resource group, core type, or customer-entered core count. Azure Extension for SQL Server discovers the host type, cores, SQL versions, and editions. Multiple eligible instances of the same SQL version on one OSE share one meter based on the highest edition. SQL Server 2014 and SQL Server 2016 on the same OSE can produce separate meters.

<a id="sql-license-type"></a>
## LicenseType describes the SQL Server software license

`LicenseType` does not indicate whether ESU charges are already paid. It describes how the underlying SQL Server software is licensed and determines whether that installation is eligible for an Arc-enabled ESU subscription.

| Extension value | Underlying SQL Server software licensing | Effect on Arc-enabled ESUs |
| --- | --- | --- |
| `Paid` | Bring your own Standard or Enterprise license with active Software Assurance, or use an active SQL Server subscription. SQL software usage is reported through a free hourly meter. | Eligible to enable ESUs. `Paid` does not include or prepay ESU charges; enabling ESUs starts separate ESU metering. |
| `PAYG` | Subscribe to the Standard or Enterprise SQL Server software license through Azure and pay for that software on an hourly meter. | Eligible to enable ESUs. ESU usage is metered separately from the SQL software PAYG meter. |
| `LicenseOnly` | Use a perpetual Standard or Enterprise license without Software Assurance, a free Developer/Evaluation/Express edition, or an applicable provider license such as SPLA. | Not eligible for an Arc-enabled ESU subscription. A qualifying license with Software Assurance/SQL subscription or SQL software `PAYG` is required. |

Two independent extension settings are involved:

```text
LicenseType                       How the underlying SQL Server software is licensed
enableExtendedSecurityUpdates    Whether the separate SQL ESU subscription is enabled
```

Changing `LicenseType` can change SQL Server software billing and use rights. Changing `enableExtendedSecurityUpdates` controls the ESU subscription. Review and approve each change independently; never interpret `Paid` as "ESUs paid." In this repository:

- [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) never sets or changes `LicenseType`. It only toggles `enableExtendedSecurityUpdates` and requires the host to already be `Paid` or `PAYG`. For the reasons, see [Why LicenseType is never changed](SetSQLServerESUSubscription.md#why-licensetype-is-never-changed).
- [InstallSQLServerArcExtension.ps1](InstallSQLServerArcExtension.md) sets `LicenseType` only when it installs a missing extension, and only to `Paid` or `LicenseOnly`. It never selects `PAYG`.
- [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md) is the only script that can select `PAYG`. It sets `Paid`, `PAYG`, or `LicenseOnly` only on hosts whose `LicenseType` is empty, never overwrites an existing value, and requires an explicit acknowledgement for the chosen value.

<a id="how-licensetype-gets-populated"></a>
## How LicenseType gets populated

`LicenseType` isn't read from the SQL Server installation. It is a setting of the `WindowsAgent.SqlServer` extension that is chosen when the extension is installed or configured. Microsoft states: "The license type is a required parameter when you install the Azure Extension for SQL Server." How it is chosen depends on the onboarding path:

| Onboarding path | How `LicenseType` is set |
| --- | --- |
| Azure portal or a generated onboarding script | The person onboarding selects the license type. |
| SQL Server 2022 setup | The license type can be selected during setup. |
| Automatic onboarding (Microsoft installs the extension on Arc servers with SQL Server) | Microsoft reads the `ArcSQLServerExtensionDeployment` tag (`Paid`, `PAYG`, `PAYG-Recurring`, or `LicenseOnly`), checking "the subscription level first, then resource group level, then resource level." The installation step "Set the license type" happens only if that tag is set. |
| Automatic onboarding without a tag | "If no tag is set and you have Software Assurance or SQL Server subscription with available licenses, Microsoft automatically sets the license type to **Paid** for newly onboarded instances." Otherwise the value stays empty. |

Microsoft's own verification query reports an empty value as `Configuration needed`: "The value `Configuration needed` indicates that the onboarding process didn't have enough information to configure the license type automatically."

> [!WARNING]
> An `ArcSQLServerExtensionDeployment` tag with the value `PAYG` or `PAYG-Recurring` on a subscription or resource group makes automatic onboarding set newly onboarded hosts in that scope to `PAYG`. Review these tags if you don't intend to pay for SQL Server software through Azure.

**What Microsoft doesn't document:** how the automatic `Paid` detection determines that Software Assurance or SQL Server subscription licenses are available, and the precedence rules between tags, detection, and manual changes (the "License type setting precedence" heading on the automatic connection page currently has no content). Don't assume that a host will be set automatically; check it.

**What to do when it is empty:**

1. Find affected hosts with [CheckSQLServerESUStatus.ps1](CheckSQLServerESUStatus.md) or [SetSQLServerLicenseType.kql](../../../samples/SetSQLServerLicenseType.kql).
2. The license owner decides the correct value for each whole host. See [Choose the value](SetSQLServerLicenseType.md#choose-the-value-impact-of-each-licensetype).
3. Set it with [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md) (`-DryRun` first), the Azure portal, or Microsoft's [modify-arc-sql-license-type.ps1](https://github.com/microsoft/sql-server-samples/tree/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type) sample.
4. Then enable ESUs with [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md).

Sources: [Manage automatic connection](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy?view=sql-server-ver17#specify-license-type), [Manage licensing and billing](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing?view=sql-server-ver17), and [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration?view=sql-server-ver17).

## Contrast with Windows Server ESUs

```text
Windows Server ESU
License resource group                         Arc machine resource group
└── Microsoft.HybridCompute/licenses ────────> machine/licenseProfile

SQL Server ESU implemented here
Arc machine resource group
└── machine/extension/WindowsAgent.SqlServer ─> ESU subscription setting
```

Windows Server scripts create and assign explicit `Microsoft.HybridCompute/licenses` resources. Those licenses and Arc machines can be in different resource groups, and supported repository workflows also retain explicit subscription IDs for cross-subscription assignment.

The implemented SQL workflow has no assignment relationship and no license resource group. Enabling SQL ESUs means changing a setting on the extension that is a child of the Arc machine.

## Resource groups and permissions

`ServerResourceGroupName` always means the resource group containing the target `Microsoft.HybridCompute/machines` resource.

- Assign **SQL Server Arc ESU Reader** at subscription scope because provider state and SQL inventory are subscription-level reads.
- Assign **SQL Server Arc ESU Operator** to every resource group containing Arc machines that the identity will modify. The role writes only `Microsoft.HybridCompute/machines/extensions`.
- Do not assign these roles to a separate SQL license resource group for this workflow; no such resource group is used.
- If target Arc machines span several resource groups, assign Operator to each machine resource group or deliberately choose a broader common scope after reviewing the increased permissions.

The supplied roles do not grant `sqlServerEsuLicenses` management permissions.

## Unlimited virtualization is a separate workflow

Microsoft documents a physical-core unlimited-virtualization option that creates a `Microsoft.AzureArcData/sqlServerEsuLicenses` resource. Its `scopeType` can be `ResourceGroup`, `Subscription`, or `Tenant`. A subscription- or tenant-scoped license can therefore cover qualifying Arc VMs in resource groups different from the resource group containing the license resource, provided every VM is in scope and meets the remaining Microsoft requirements.

That resource does not replace VM configuration: intended VMs must still be connected to Arc, subscribed to ESUs, and configured to use the physical-core license. This repository does not create, update, terminate, delete, or apply that resource.

## Workflow implemented by this repository

1. Generate or prepare the target CSV with [CheckSQLServerESUStatus.kql](../../../samples/CheckSQLServerESUStatus.kql) or the applicable sample.
2. Run [TestSQLServerArcESUPrerequisites.ps1](TestSQLServerArcESUPrerequisites.md).
3. If needed, run [InstallSQLServerArcExtension.ps1](InstallSQLServerArcExtension.md).
4. Run [CheckSQLServerESUStatus.ps1](CheckSQLServerESUStatus.md) and check `LicenseType`.
5. Only if `LicenseType` is empty, and after a licensing decision, preview and then run [SetSQLServerLicenseType.ps1](SetSQLServerLicenseType.md).
6. Preview and then run [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md). It keeps the current `LicenseType` unchanged.
7. Run the status check again.

Use `Enable` and `Disable` for the SQL subscription lifecycle. Reserve create, assign, unassign, and delete terminology for Windows Server license resources or the separate pooled SQL physical-core resource.

## Official Microsoft documentation

- [SQL Server Extended Security Updates enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates)
- [Subscribe to SQL Server ESUs by virtual cores](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-virtual-cores)
- [Subscribe by physical cores without using VMs](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-physical-cores-without-using-vms)
- [Subscribe by physical cores with unlimited virtualization](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-physical-cores-with-unlimited-virtualization)
- [License types for SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing#license-types)
- [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration)