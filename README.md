# ESU activation with Azure Arc

> Pour consulter les instructions en français, ouvrez le [fichier LISEZMOI.md](LISEZMOI.md).

<a id="table-of-contents"></a>
## Table of contents

- [Overview](#overview)
- [Choose an ESU workflow](#choose-an-esu-workflow)
- [Before you begin](#before-you-begin)
- [Windows Server ESU](#windows-server-esu)
- [SQL Server ESU](#sql-server-esu)
- [Samples and detailed documentation](#samples-and-detailed-documentation)
- [Contributing](#contributing)
- [License](#license)

<a id="overview"></a>
## Overview

This repository provides two separate PowerShell 7 workflows for Extended Security Updates (ESUs) enabled by Azure Arc:

- Azure Arc ESU license resources for Windows Server 2012, Windows Server 2012 R2, and Windows Server 2016.
- Per-Arc-machine/OSE SQL Server ESU subscriptions for SQL Server 2014 and SQL Server 2016.

The scripts use Azure Resource Manager REST APIs directly. They support individual and bulk operations, read-only status checks, preview modes for supported changes, and either user-token or service-principal authentication.

These scripts do not onboard machines to Azure Arc or deploy ESU patches. Machines must already be connected to Azure Arc and satisfy the requirements for the selected workflow.

<a id="choose-an-esu-workflow"></a>
## Choose an ESU workflow

Windows Server ESU licenses and SQL Server ESU subscriptions use different Azure resources, permissions, eligibility rules, and billing models. Do not use one workflow to manage the other.

| Workflow | Supported products | Azure resource changed | Start here |
| --- | --- | --- | --- |
| Windows Server ESU | Windows Server 2012, 2012 R2, and 2016 | `Microsoft.HybridCompute/licenses` and machine license profiles | [Windows Server ESU](#windows-server-esu) |
| SQL Server ESU | SQL Server 2014 and 2016 on Windows machines connected to Azure Arc | Host settings on `Microsoft.HybridCompute/machines/extensions/WindowsAgent.SqlServer` | [SQL Server ESU](#sql-server-esu) |

### How Windows and SQL ESUs differ

Windows Server and SQL Server ESUs do not use the same Azure object model. Windows Server ESUs create a license resource and assign it through a machine license profile. The SQL workflow implemented here creates no comparable license object: it enables an ESU subscription in the `WindowsAgent.SqlServer` extension of each Arc machine.

| Characteristic | Windows Server ESU | SQL Server ESU implemented here |
| --- | --- | --- |
| Azure license object | `Microsoft.HybridCompute/licenses` | None |
| Configuration location | License resource plus machine license profile | `WindowsAgent.SqlServer` extension settings |
| Operation | Create a license, then assign it | Enable or cancel a subscription per Arc machine/OSE |
| Core input | Customer supplies the licensed cores | Azure detects the cores visible to the operating system environment (OSE) |
| SQL Server in a VM | Not applicable | Azure meters the vCores visible to that VM, with the documented four-core minimum |
| SQL Server directly on a physical server | Not applicable | Azure meters the physical cores visible to that OSE, with the documented four-core minimum |
| Separate license resource group | Supported for Windows license resources | Not applicable because no SQL license resource is created |

In this documentation, **per Arc machine/OSE** means the guest VM when SQL Server runs in a VM, not the physical hypervisor. Customers enable the SQL ESU subscription separately on each Arc-connected SQL VM they want covered; Azure meters that VM's vCores rather than all cores of the virtualization host.

**Important:** SQL extension values `Paid`, `PAYG`, and `LicenseOnly` describe how the underlying SQL Server software is licensed; they are not ESU payment statuses. `Paid` means a qualifying bring-your-own license with active Software Assurance or SQL Server subscription, `PAYG` means the SQL software license is billed through Azure, and `LicenseOnly` means a license without the qualifying subscription benefit. Only `Paid` and `PAYG` qualify for the Arc-enabled ESU subscription. The separate `enableExtendedSecurityUpdates` setting controls ESU enrollment and ESU metering. `SetSQLServerESUSubscription.ps1` never sets or changes `LicenseType`: the host must already be `Paid` or `PAYG`, and hosts that are `LicenseOnly` or undefined are blocked rather than converted. `InstallSQLServerArcExtension.ps1` sets `LicenseType` only when it installs a missing extension, and only to `Paid` or `LicenseOnly`. `SetSQLServerLicenseType.ps1` is the only script that can select `PAYG`: it fills an empty `LicenseType` only, never overwrites an existing value, and requires an explicit acknowledgement for the chosen value. See the [detailed LicenseType explanation](docs/English/sql/README.md#sql-license-type), [how LicenseType gets populated](docs/English/sql/README.md#how-licensetype-gets-populated), and [why the ESU script never changes LicenseType](docs/English/sql/SetSQLServerESUSubscription.md#why-licensetype-is-never-changed).

SQL Server also offers a separate physical-core unlimited-virtualization model that creates a `Microsoft.AzureArcData/sqlServerEsuLicenses` resource. That resource can cover qualifying Arc-enabled VMs through a resource-group, subscription, or tenant scope. This repository does not create, manage, or apply those pooled physical-core licenses.

<a id="before-you-begin"></a>
## Before you begin

### Common prerequisites

- A Microsoft Entra tenant and an active Azure subscription.
- PowerShell 7.x or later. See [Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows).
- Target machines already connected to Azure Arc. See the [Connected Machine agent prerequisites](https://learn.microsoft.com/azure/azure-arc/servers/prerequisites).
- Azure permissions for the selected workflow and every applicable subscription and resource group.
- Reviewed customer inventory, licensing eligibility, and billing information before any change.

The scripts do not require the Az PowerShell module when service-principal authentication is used. User-token authentication requires a token object such as one returned by `Get-AzAccessToken`.

<a id="azure-cloud-support"></a>
### Azure cloud support

The current scripts target global Azure. They use the global Azure Resource Manager endpoint (`management.azure.com`) and Microsoft Entra endpoint (`login.microsoftonline.com`), and they validate ARM response URLs against the global Azure host. They are not compatible with Azure Government as written.

Azure Government uses different management and authentication endpoints, and feature availability can differ by cloud and region. Microsoft currently documents SQL Server enabled by Azure Arc in US Government Virginia on Windows with a limited feature set. Review [SQL Server enabled by Azure Arc in US Government](https://learn.microsoft.com/sql/sql-server/azure-arc/us-government-region?view=sql-server-ver17) for current availability and limitations.

Azure Government support would require cloud-aware endpoint and token-audience configuration, trusted-host validation for Government ARM responses, Government-specific regional endpoints, and separate API, provider, role, and regression validation. Do not adapt these scripts by replacing URLs without completing that validation.

### Authentication options

Use one of these authentication methods:

1. Pass a user token object through `-userToken`:

   ```powershell
   $authenticationToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
   ```

2. Pass `-tenantId`, `-appID`, and `-clientSecret` for a Microsoft Entra service principal.

The authenticated identity must have the required role assignments in all subscriptions involved. Never place real credentials in CSV files, command history, documentation, or logs.

### Safety, licensing, and billing

ESU edition, core type, core count, target, activation state, program year, invoice ID, and exception handling can affect billing and compliance. Verify the applicable Microsoft licensing terms before using these scripts. Incorrect selections can result in excess charges or non-compliance.

- Use read-only status scripts first.
- Use `-DryRun` or `-WhatIf` when the selected script supports it, and review the complete plan before making a change.
- Replace every fictitious value in the samples with verified customer data.
- Confirm the result with the corresponding read-only status script.
- Do not assume that enabling ESU access installs patches.

Activated Windows Server ESU licenses are billed for provisioned cores even when they are not assigned. Late enrollment and some license changes can cause back-billing. Reducing cores, deactivating a license, or deleting it can remain billable for up to five calendar days. Confirm current terms in the [official Windows Server ESU billing guidance](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates).

The information and scripts in this repository are provided as is and are not a substitute for professional, legal, or licensing advice.

<a id="windows-server-esu"></a>
## Windows Server ESU

### Scope and requirements

License creation accepts these exact `Target` values:

- `Windows Server 2012`
- `Windows Server 2012 R2`
- `Windows Server 2016`

Use Connected Machine agent 1.34 or later for Windows Server 2012/R2 and 1.62 or later for Windows Server 2016. Review the current [Windows Server ESU preparation guidance](https://learn.microsoft.com/azure/azure-arc/servers/prepare-extended-security-updates) before enrollment.

Windows Server 2016 ESUs enabled by Azure Arc support Standard and Datacenter editions. SPLA and the Windows Server 2012/R2 `InvoiceId`, `ProgramYear`, Visual Studio dev/test, and exception-tag mechanisms are not supported for Windows Server 2016. Windows Server 2016 reaches end of support on January 12, 2027, and ESU billing begins January 13, 2027.

Azure Arc-enabled servers used for these ESUs are not currently supported in Azure operated by 21Vianet. Install the licensing package and servicing stack update applicable to the target operating system; do not reuse a Windows Server 2012 package as a Windows Server 2016 prerequisite.

### Required permissions

The [ARC ESU License Administrator](Custom%20Roles/ARC%20ESU%20License%20Administrator.json) custom role contains the required license and machine license-profile actions:

- `Microsoft.HybridCompute/licenses/read`
- `Microsoft.HybridCompute/licenses/write`
- `Microsoft.HybridCompute/licenses/delete`
- `Microsoft.HybridCompute/machines/licenseProfiles/read`
- `Microsoft.HybridCompute/machines/licenseProfiles/write`

Assign the role at every scope containing Windows Server ESU licenses or target Azure Arc machines. Cross-subscription assignments require access in both the machine and license subscriptions.

### Recommended workflow

1. Run `CheckESUStatus.ps1` to inventory existing assignments without making changes.
2. Choose the single-resource or bulk script that matches the intended operation.
3. Copy the applicable CSV template and verify target, edition, core type, core count, agent version, transition values, and assignment intent.
4. Run a supported preview mode and review the complete plan.
5. Run the approved change, then check status again.

### Script and guide catalog

| Goal | Guide | CSV template or starting point |
| --- | --- | --- |
| Check assignment status without changes | [CheckESUStatus.ps1](docs/English/windows/CheckESUStatus.md) | [Status template](samples/CheckESUStatus.csv) |
| Create or update one license | [CreateESULicense.ps1](docs/English/windows/CreateESULicense.md) | Review target, edition, core type, core count, and state in the guide |
| Assign or unlink one existing license | [AssignESULicense.ps1](docs/English/windows/AssignESULicense.md) | Use when the server and license resources are known |
| Create or update licenses in bulk, with optional assignment | [ManageESULicenses.ps1](docs/English/windows/ManageESULicenses.md) | [License template](samples/ManageESULicenses.csv) |
| Assign or unlink existing licenses in bulk or across subscriptions | [ManageESUAssignments.ps1](docs/English/windows/ManageESUAssignments.md) | [Assignment template](samples/ManageESUAssignments.csv) |
| Delete one license | [DeleteESULicense.ps1](docs/English/windows/DeleteESULicense.md) | Review the deletion and billing warning in the guide |

Example read-only inventory command:

```powershell
./Scripts/windows/CheckESUStatus.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -serverResourceGroupName "rg-example-arc" -ARCServerName "server-01"
```

Example bulk preview:

```powershell
./Scripts/windows/ManageESULicenses.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -licenseResourceGroupName "rg-example-esu" -location "EastUS" -state "Deactivated" -edition "Standard" -csvFilePath ".\samples\ManageESULicenses.csv" -DryRun
```

<a id="sql-server-esu"></a>
## SQL Server ESU

> [!IMPORTANT]
> **Check the SQL extension `LicenseType` before you try to enable ESUs.** Onboarding can leave it empty, which Microsoft reports as `Configuration needed`: "the onboarding process didn't have enough information to configure the license type automatically." An empty value blocks ESU enrollment, and the ESU script never fills it in. Read [How LicenseType gets populated](docs/English/sql/README.md#how-licensetype-gets-populated), let the license owner decide the value, and then use [SetSQLServerLicenseType.ps1](docs/English/sql/SetSQLServerLicenseType.md). That script fills empty values only and shows the licensing and billing impact before any change.

### Scope and exclusions

This workflow supports SQL Server 2014 and SQL Server 2016 instances on Windows machines already connected to Azure Arc, subject to the [Azure cloud support](#azure-cloud-support) limitation above. It uses the Azure extension for SQL Server and per-Arc-machine/OSE ESU subscription settings. Read the [SQL Server ESU object-model overview](docs/English/sql/README.md) before using the SQL scripts, especially if you are familiar with the Windows Server license-assignment workflow.

It does not:

- Install, upgrade, or repair the Connected Machine agent.
- Manage native Azure virtual machines or Linux machines.
- Manage pooled physical-core `sqlServerEsuLicenses` resources or unlimited virtualization.
- Determine customer licensing eligibility.
- Deploy ESU patches automatically.

Run the prerequisite assessment before installing the extension or changing a subscription. It distinguishes eligibility evidence, extension readiness, inventory freshness, region support, and blocking machine conditions.

### Required permissions

Use the provided least-privilege roles at these scopes:

| Role | Scope | Purpose |
| --- | --- | --- |
| [SQL Server Arc ESU Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) | Subscription | Provider, machine, extension, and SQL inventory reads |
| [SQL Server Arc ESU Operator](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) | Each resource group containing target Arc machines | Install the SQL extension and update its public settings |

Read-only prerequisite and status operations require only the Reader role. Extension installation, license type, and ESU subscription changes require Reader at subscription scope and Operator on each resource group containing target `Microsoft.HybridCompute/machines` resources. No separate SQL license resource group exists in this implemented workflow.

### Recommended workflow

1. Run `TestSQLServerArcESUPrerequisites.ps1` to assess the machine, extension, inventory, region, and SQL instance evidence.
2. Run `InstallSQLServerArcExtension.ps1` only when the expected extension is absent and the external prerequisites are confirmed.
3. Run `CheckSQLServerESUStatus.ps1` to capture the current host and instance state, including `LicenseType`.
4. Only if `LicenseType` is empty, and after the license owner's decision, run `SetSQLServerLicenseType.ps1 -DryRun`, review every warning, then run it live.
5. Run `SetSQLServerESUSubscription.ps1 -DryRun` and review the proposed enable or cancellation.
6. Run the approved change, then check status again.

The lifecycle script preserves unrelated public extension settings through a GET-merge-PUT update. Its `Disable` path remains available when inventory evidence is degraded so future charges can be cancelled, while still requiring the expected extension identity and readable settings.

### Script and guide catalog

| Goal | Guide | CSV template | Minimum role |
| --- | --- | --- | --- |
| Understand SQL ESU objects, metering models, and resource-group scope | [SQL Server ESU overview](docs/English/sql/README.md) | Not applicable | None |
| Assess prerequisites and eligibility evidence | [TestSQLServerArcESUPrerequisites.ps1](docs/English/sql/TestSQLServerArcESUPrerequisites.md) | [Status template](samples/CheckSQLServerESUStatus.csv) | Reader |
| Install the Azure extension for SQL Server when absent | [InstallSQLServerArcExtension.ps1](docs/English/sql/InstallSQLServerArcExtension.md) | [Installation template](samples/InstallSQLServerArcExtension.csv) | Reader + Operator |
| Check host ESU, inventory, and metering evidence without changes | [CheckSQLServerESUStatus.ps1](docs/English/sql/CheckSQLServerESUStatus.md) | [Status template](samples/CheckSQLServerESUStatus.csv) | Reader |
| Set an empty `LicenseType` after a licensing decision (never overwrites) | [SetSQLServerLicenseType.ps1](docs/English/sql/SetSQLServerLicenseType.md) | [License type template](samples/SetSQLServerLicenseType.csv) | Reader + Operator |
| Enable or cancel a per-Arc-machine/OSE ESU subscription | [SetSQLServerESUSubscription.ps1](docs/English/sql/SetSQLServerESUSubscription.md) | [Lifecycle template](samples/SetSQLServerESUSubscription.csv) | Reader + Operator |

### Generate SQL CSV files with Azure Resource Graph

Use these queries in [Azure Resource Graph Explorer](https://portal.azure.com/#view/HubsExtension/ArgQueryBlade) and download the result as CSV. Each query projects only the exact columns accepted by its script:

| CSV purpose | Query | Notes |
| --- | --- | --- |
| Prerequisite assessment and status | [CheckSQLServerESUStatus.kql](samples/CheckSQLServerESUStatus.kql) | Returns connected Windows Arc machines that report SQL Server discovery. |
| SQL extension installation | [InstallSQLServerArcExtension.kql](samples/InstallSQLServerArcExtension.kql) | Returns discovered SQL hosts without `WindowsAgent.SqlServer`. Set the license type and prerequisite confirmation at the top of the query. |
| Empty license type | [SetSQLServerLicenseType.kql](samples/SetSQLServerLicenseType.kql) | Returns only hosts whose `LicenseType` is empty (`Configuration needed`). Set the license type and its matching acknowledgement at the top of the query. |
| ESU enable or cancellation | [SetSQLServerESUSubscription.kql](samples/SetSQLServerESUSubscription.kql) | Returns one row per host. `Enable` rows are returned only for hosts whose instances are all SQL Server 2014/2016 Standard, Enterprise, or confirmed nonproduction Developer, matching the script's checks. Set the requested action and all applicable billing, environment, and prerequisite values at the top of the query. `RequestedLicenseType` is only an optional check of the current value; the script never changes it. |

Select every subscription that contains target Arc machines before running a query. The installation, license type, and lifecycle queries deliberately return no change rows until their required constants contain valid, explicitly reviewed values. Run the resulting CSV through the script's `-DryRun` mode before approving a live operation. Resource Graph inventory is discovery evidence only; it does not establish licensing entitlement or external prerequisite compliance.

Example read-only prerequisite assessment:

```powershell
./Scripts/sql/TestSQLServerArcESUPrerequisites.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -serverResourceGroupName "rg-example-arc" -ARCServerName "sql-server-01"
```

Example lifecycle preview:

```powershell
./Scripts/sql/SetSQLServerESUSubscription.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -serverResourceGroupName "rg-example-arc" -ARCServerName "sql-server-01" -Action Enable -Environment Production -AcceptBackBilling -ConfirmExternalPrerequisites -DryRun
```

<a id="samples-and-detailed-documentation"></a>
## Samples and detailed documentation

Use the maintained guides for complete parameter definitions, CSV schemas, validation rules, output fields, cross-subscription behavior, and examples:

| Product | English guides | French guides | Scripts | Samples |
| --- | --- | --- | --- | --- |
| Windows Server ESU | [English Windows documentation](docs/English/windows/) | [Documentation Windows en français](docs/Français/windows/) | [Windows scripts](Scripts/windows/) | [Sample files](samples/) |
| SQL Server ESU | [English SQL documentation](docs/English/sql/) | [Documentation SQL en français](docs/Français/sql/) | [SQL scripts](Scripts/sql/) | [Sample files](samples/) |

<a id="contributing"></a>
## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development requirements, validation commands, and contribution guidance.

<a id="license"></a>
## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).