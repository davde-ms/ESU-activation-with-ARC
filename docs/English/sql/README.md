# SQL Server ESUs enabled by Azure Arc

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

Changing `LicenseType` can change SQL Server software billing and use rights. Changing `enableExtendedSecurityUpdates` controls the ESU subscription. Review and approve each change independently; never interpret `Paid` as "ESUs paid." In this repository, [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md) never sets or changes `LicenseType`; it only toggles `enableExtendedSecurityUpdates` and requires the host to already be `Paid` or `PAYG`. [InstallSQLServerArcExtension.ps1](InstallSQLServerArcExtension.md) sets `LicenseType` only when it installs a missing extension, and only to `Paid` or `LicenseOnly`. No script here selects `PAYG`; make any license type change separately after a licensing decision.

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
4. Run [CheckSQLServerESUStatus.ps1](CheckSQLServerESUStatus.md).
5. Preview and then run [SetSQLServerESUSubscription.ps1](SetSQLServerESUSubscription.md). It keeps the current `LicenseType` unchanged.
6. Run the status check again.

Use `Enable` and `Disable` for the SQL subscription lifecycle. Reserve create, assign, unassign, and delete terminology for Windows Server license resources or the separate pooled SQL physical-core resource.

## Official Microsoft documentation

- [SQL Server Extended Security Updates enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates)
- [Subscribe to SQL Server ESUs by virtual cores](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-virtual-cores)
- [Subscribe by physical cores without using VMs](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-physical-cores-without-using-vms)
- [Subscribe by physical cores with unlimited virtualization](https://learn.microsoft.com/sql/sql-server/azure-arc/extended-security-updates#subscribe-to-sql-server-esus-by-physical-cores-with-unlimited-virtualization)
- [License types for SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing#license-types)
- [Configure SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-configuration)