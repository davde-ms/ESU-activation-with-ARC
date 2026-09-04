# ESU activation with ARC

> Les instructions en français se trouvent dans le [fichier LISEZMOI.md](LISEZMOI.md).

## Introduction

This repository provides two separate PowerShell 7 workflows: Azure Arc ESU license resources for Windows Server 2012, Windows Server 2012 R2, and Windows Server 2016; and host-level SQL Server ESU subscriptions for SQL Server 2014 and SQL Server 2016 enabled by Azure Arc.

An eligible Arc-enabled server must be linked to an activated ESU license for its target Windows Server version before it can receive ESUs. Assignment, status, unlink, and deletion operations work with licenses for all three targets; license creation requires the exact target value.

> It is crucial to thoroughly comprehend the appropriate licensing procedures and prerequisites for the servers you intend to enable ESUs for using Azure ARC. It is imperative to generate the CORRECT form of licenses, such as Standard or Datacenter, considering whether they are for virtual or physical cores. Failing to do so could lead to either excessive billing or non-compliance with Microsoft's licensing regulations. If you have any uncertainties, please seek advice from your dedicated Microsoft Azure specialist or Microsoft Account Executive.

This information and scripts are provided as is and are not intended to be a substitute for professional advice or consulting, including but not limited to legal advice. I do not make any warranties, express, implied or statutory, as to the information in this document or scripts. I do not accept any liability for any damages, direct or consequential, arising from the use of the information contained in this document or scripts.

That being said, let's get started!

## Choose the correct ESU workflow

Windows Server ESU licenses and SQL Server ESU subscriptions use different Azure resources, scripts, permissions, eligibility rules, and billing models. Do not use the Windows Server scripts to manage SQL Server ESUs or the SQL Server scripts to manage Windows Server ESU licenses.

| Workflow | Scope | Resources changed |
| --- | --- | --- |
| Windows Server ESU | Windows Server 2012, 2012 R2, and 2016 | `Microsoft.HybridCompute/licenses` and machine license profiles |
| SQL Server ESU | SQL Server 2014 and 2016 on Windows machines already connected to Commercial Azure Arc | The host's `Microsoft.HybridCompute/machines/extensions/WindowsAgent.SqlServer` settings |

The SQL Server workflow is Windows-only and does not install, upgrade, or repair the Connected Machine agent. It does not manage native Azure VMs, Linux, physical-core pooled `sqlServerEsuLicenses`, unlimited virtualization, or automatic patch deployment. Enabling an ESU subscription grants access under the applicable terms; these scripts do not deploy ESU patches.

### SQL Server ESU navigation

| Goal | Guide | CSV template | Minimum role |
| --- | --- | --- | --- |
| Assess Arc, extension, inventory, and eligibility prerequisites | [TestSQLServerArcESUPrerequisites.ps1](docs/English/sql/TestSQLServerArcESUPrerequisites.md) | Uses the [three-column status template](samples/CheckSQLServerESUStatus.csv) | [SQL Server Arc ESU Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) |
| Install the Azure Extension for SQL Server when absent | [InstallSQLServerArcExtension.ps1](docs/English/sql/InstallSQLServerArcExtension.md) | [Install template](samples/InstallSQLServerArcExtension.csv) | [Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) at subscription + [Operator](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) at target resource group |
| Check host ESU, inventory, and metering evidence without changes | [CheckSQLServerESUStatus.ps1](docs/English/sql/CheckSQLServerESUStatus.md) | [Status template](samples/CheckSQLServerESUStatus.csv) | [SQL Server Arc ESU Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) |
| Enable or cancel a host-level SQL Server ESU subscription | [SetSQLServerESUSubscription.ps1](docs/English/sql/SetSQLServerESUSubscription.md) | [Lifecycle template](samples/SetSQLServerESUSubscription.csv) | [Reader](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Reader.json) at subscription + [Operator](Custom%20Roles/SQL%20Server%20Arc%20ESU%20Operator.json) at target resource group |

Start with the prerequisite assessment, install the extension only if it is absent, check status, and use `SetSQLServerESUSubscription.ps1 -DryRun` before a live enable or cancellation. The lifecycle script preserves unrelated public extension settings through a GET-merge-PUT update. Its `Disable` path remains available with degraded inventory evidence so customers can cancel future charges, while still requiring the exact expected extension identity and readable settings.

## Prerequisites

- An Microsoft Entra ID tenant as well as an active Azure subscription.
- Eligible Windows Server 2012, Windows Server 2012 R2, or Windows Server 2016 machines already onboarded to Azure Arc. Use Connected Machine agent 1.34 or later for 2012/R2 and 1.62 or later for 2016. Check the [Connected Machine agent prerequisites](https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites) and the [ESU preparation guidance](https://learn.microsoft.com/azure/azure-arc/servers/prepare-extended-security-updates).
- One or more Azure resource groups to store the ESU licenses that will be created with these scripts. ESU licenses can be located in the same subscription as your ARC servers or in a different subscription.
- An Microsoft Entra Enterprise application and service principal that will be used to authenticate to Azure. Please check the [Create an Azure service principal with Azure CLI](https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal) to create a service principal.
- The Microsoft Entra application ID and secret key for the service principal created above.
- A delegation of rights to the resource group that holds the licenses as well as a delegation of rights to the resource group(s) that contain the Azure ARC servers. Please check the [Delegating access to Azure resources](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-steps) to delegate access to the resource groups if you need assistance. The required delegated rights will be documented in the next section.
- A computer with Powershell 7.x or higher installed. Please check [Install PowerShell 7 on Windows](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows) to install Powershell 7.x or higher. The current version of the scripts do not use the AZ Powershell module, but it is recommended to install it for future use. Please check the [Install Azure PowerShell on Windows](https://learn.microsoft.com/en-us/powershell/azure/install-azps-windows) to install the AZ Powershell module if you want to.

> **Note**: Multiple scripts now support **user token authentication** as an alternative to service principal authentication. These scripts (AssignESULicense.ps1, CreateESULicense.ps1, DeleteESULicense.ps1, CheckESUStatus.ps1, ManageESUAssignments.ps1, and ManageESULicenses.ps1) can work with a user provided Microsoft Entra ID authentication token, so the service principal is no longer required for their execution. You can provide either the tenantID, appID and clientSecret parameters OR a valid Microsoft Entra ID authentication token that has the rights to manage ESU licenses.

### Supported targets and Windows Server 2016 eligibility

License creation accepts only these exact `Target` values:

- `Windows Server 2012`
- `Windows Server 2012 R2`
- `Windows Server 2016`

Windows Server 2016 ESUs enabled by Azure Arc support Standard and Datacenter editions. General eligibility requires qualifying Software Assurance through an eligible Volume Licensing program or an equivalent Server Subscription. For Windows Server 2016 workloads running on-premises, Software Assurance is required. SPLA isn't available for Windows Server 2016 ESUs, and transition from Volume Licensing by using `InvoiceId` and `ProgramYear` isn't supported.

Microsoft currently documents the Visual Studio dev/test benefit and the `WS2012 VISUAL STUDIO DEV TEST`, `WS2012 DISASTER RECOVERY`, and `WS2012 MULTIPURPOSE` exception tags only for Windows Server 2012/R2. No equivalent Visual Studio dev/test benefit or Azure Arc exception-tag protocol is documented for Windows Server 2016. Do not reuse those WS2012 values for 2016, and do not treat any tag as an eligibility or billing control.

Azure Arc-enabled servers used for Windows Server 2012/R2 or 2016 ESUs are not currently available in Azure operated by 21Vianet. Review the current [Windows Server ESU preparation guidance](https://learn.microsoft.com/azure/azure-arc/servers/prepare-extended-security-updates) before enrollment.

### OS updates and billing

- For Windows Server 2012/R2, install the licensing package and servicing stack update (SSU) identified in Microsoft's guidance. For Windows Server 2016, Microsoft currently directs customers to install any required licensing package and SSU from the applicable Windows Server 2016 Knowledge Base article but does not name a specific KB. Follow the current [ESU troubleshooting prerequisites](https://learn.microsoft.com/azure/azure-arc/servers/troubleshoot-extended-security-updates#esu-prerequisites); do not use the Windows Server 2012 KB as a 2016 prerequisite.
- Windows Server 2016 reaches end of support on January 12, 2027. Billing for Windows Server 2016 ESUs enabled by Azure Arc begins January 13, 2027.
- An activated license is billed for its provisioned cores even when it isn't linked to a server. Customers are responsible for deleting activated, unlinked licenses they no longer require.
- A license or additional cores provisioned after the applicable end-of-support date can be back-billed to that date. Late enrollment, activation or reactivation, deletion followed by recreation, and changing the license region or tenant can trigger back-billing.
- Reducing cores, deactivating a license, or deleting it can continue to incur charges for up to five calendar days. Recreation does not avoid charges for the corresponding period.

Confirm current terms in the [official ESU billing guidance](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates) before any billing-sensitive operation.

## Azure rights required for the scripts to work

The following rights have to be delegated on the resource groups you plan on using to store the ESU licence objects as well as the resource groups containing the Azure ARC servers:

- "Microsoft.HybridCompute/licenses/read"
- "Microsoft.HybridCompute/licenses/write"
- "Microsoft.HybridCompute/licenses/delete"
- "Microsoft.HybridCompute/machines/licenseProfiles/read"
- "Microsoft.HybridCompute/machines/licenseProfiles/write"

There is a custom role definition located in the Custom Roles folder in this repository that can be used to create a custom role with the required rights. Please check [Create a custom role with a JSON template](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles-powershell#create-a-custom-role-with-json-template) to create a custom role with the custom role definition.

Once the role is created, assign it to the security principal and apply it to the all resource groups storing the licenses or the Azure ARC Server objects. For example, if you have 3 resource groups, one for the licenses and two for the Azure ARC servers, you will need to assign the custom role to the security principal and apply it to all three resource groups. **Important Note**: For cross-subscription scenarios, ensure the service principal has appropriate rights in all relevant subscriptions (ARC servers subscription and ESU licenses subscription).

## Windows Server ESU scripts

The following scripts manage Windows Server ESU license resources and assignments:

- [AssignESULicense.ps1](docs/English/windows/AssignESULicense.md) (assigns an existing ESU license to an Azure ARC server)
- [CreateESULicense.ps1](docs/English/windows/CreateESULicense.md) (creates a new ESU license)
- [DeleteESULicense.ps1](docs/English/windows/DeleteESULicense.md) (deletes an existing ESU license)
- [CheckESUStatus.ps1](docs/English/windows/CheckESUStatus.md) (checks the ESU license status for Azure ARC servers)
- [ManageESULicenses.ps1](docs/English/windows/ManageESULicenses.md) (creates and optionally assigns ESU licenses in bulk, taking its input from a CSV file)
- [ManageESUAssignments.ps1](docs/English/windows/ManageESUAssignments.md) (assigns ESU licenses in bulk, taking its input from a CSV file, supports cross-subscription scenarios)

### Which script should I use?

| Goal | Script | Start here |
| --- | --- | --- |
| Check current ESU assignment status without making changes | `CheckESUStatus.ps1` | [Guide](docs/English/windows/CheckESUStatus.md) and [CSV template](samples/CheckESUStatus.csv) |
| Create or update one 2012, 2012 R2, or 2016 ESU license | `CreateESULicense.ps1` | Review the licensing model before choosing target, edition, core type, and core count. |
| Assign or unlink one existing license | `AssignESULicense.ps1` | Use when you already know the server and license resource. |
| Create or update mixed-target licenses in bulk, with optional assignment or unlinking | `ManageESULicenses.ps1` | [Guide](docs/English/windows/ManageESULicenses.md) and [CSV template](samples/ManageESULicenses.csv) |
| Assign or unlink existing licenses in bulk, including cross-subscription licenses | `ManageESUAssignments.ps1` | [Guide](docs/English/windows/ManageESUAssignments.md) and [CSV template](samples/ManageESUAssignments.csv) |
| Delete an existing license | `DeleteESULicense.ps1` | Review the deletion and billing warning before running it. |

### Safe customer workflow

1. Run `CheckESUStatus.ps1` first to inventory current assignments. It is read-only.
2. Copy the relevant template from the [`samples`](samples/) folder and replace every fictitious value with reviewed customer data.
3. Preview the plan before making changes. Use `-DryRun` with `ManageESUAssignments.ps1` or `ManageESULicenses.ps1`; both scripts also support `-WhatIf` and `-Confirm`.
4. Review each exact target, transition mode, minimum agent version, normalized core count, edition/core-type choice, generated license name, and assignment or unlink action shown in the plan and summary.
5. Run the same reviewed command without `-DryRun` or `-WhatIf` only when the plan is correct. Use `-Confirm` when you want an interactive prompt for each operation.

`ManageESULicenses.ps1` validates the whole file before authentication or any Azure request. A single invalid target, transition, exception, agent version, core value, name, or assignment row rejects the complete file. `ManageESUAssignments.ps1 -DryRun` validates the CSV and resource access with read-only Azure `GET` requests; it sends no mutation request. `ManageESULicenses.ps1 -DryRun` performs the complete preflight and uses read-only Azure `GET` requests to count existing and new licenses; it does not create, modify, assign, unlink, or delete resources. `-WhatIf` also prevents mutation while displaying PowerShell's proposed operations. Both preview modes still require valid authentication and can perform documented read-only requests.

## AssignESULicense.ps1

This script will assign an ESU license to a specific Azure ARC server. Here is the command line you should use to run it:

    ./Scripts/windows/AssignESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -serverResourceGroupName "rg-arservers" -ARCServerName "Win2012" -location "EastUS"

where:

- subscriptionId is the subscription ID of the Azure subscription where your ARC servers and ESU licenses are located.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- licenseResourceGroupName is the name of the resource group that contains the ESU license you want to assign to the Azure ARC server.
- licenseName is the name of the ESU license you want to assign to the Azure ARC server.
- serverResourceGroupName is the name of the resource group that contains the Azure ARC server you want to assign the ESU license to.
- ARCServerName is the name of the Azure ARC server you want to assign the ESU license to.
- location is the Azure region where you ARC objects are deployed.

You can use the -u at the end of the command line to UNLINK an existing license from an Azure ARC server. If you do not specify the -u parameter, the script will link the license to the Azure ARC server (default behavior).

> **Note:** This script now supports **user token authentication** as an alternative to service principal authentication. You can use `Get-AzAccessToken -ResourceUrl https://management.azure.com/` to obtain a token and pass it using the `-userToken` parameter instead of providing tenantId, appID, and clientSecret.

## CreateESULicense.ps1

This script will create an ESU license. Here is the command line you should use to run it:

    ./Scripts/windows/CreateESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-example-esu" -licenseName "ESU-WS2016-App01" -location "EastUS" -state "Deactivated" -edition "Standard" -target "Windows Server 2016" -coreType "vCore" -coreCount 8 -WhatIf

where:

- subscriptionId is the subscription ID of the Azure subscription where your ARC servers and ESU licenses are located.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- licenseResourceGroupName is the name of the resource group that will contain the ESU license.
- licenseName is the name of the ESU license you want to create.
- location is the Azure region where you want to deploy the ESU license.
- state is the activation state of the ESU license. It can be "Activated" or "Deactivated".
- edition is the edition of the ESU license. It can be "Standard" or "Datacenter".
- target is the Windows Server version covered by the license. It accepts exactly `Windows Server 2012`, `Windows Server 2012 R2`, or `Windows Server 2016` and defaults to `Windows Server 2012` when omitted.
- coreType is the core type of the ESU license. It can be "vCore" or "pCore".
- coreCount is the number of cores of the ESU license. Provide an even value from 8 through 128 for `vCore`, or from 16 through 256 for `pCore`.

The script rejects odd or out-of-range core counts; it does not calculate or normalize the value.

**Note:** The script can also be rerun with the same base parameters to change some of the properties of the license. Those properties are:

- state (allows you to create a deactivated license and activate it later)
- coreCount (allows you to change the number of cores of the license if you have need to increase or decrease it)

All other parameters are immutable and cannot be changed once the license is created.

Use `-WhatIf` to preview a single-license create or modification. The preview performs no Azure mutation.

> **Note:** This script now supports **user token authentication** as an alternative to service principal authentication. You can use `Get-AzAccessToken -ResourceUrl https://management.azure.com/` to obtain a token and pass it using the `-userToken` parameter instead of providing tenantId, appID, and clientSecret.

## DeleteESULicense.ps1

This script will delete an ESU license. When you delete a license, it will be removed from the Azure ARC server it was assigned to and stop the billing tied to that license.

> **Deleting or deactivating a license can remain billable for up to five calendar days. If you delete and then recreate an ESU license, back-billing still applies for the corresponding period; deletion does not exempt you from those charges. Confirm the current impact in the [official ESU billing guidance](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates#billing-associated-with-modifications-to-an-azure-arc-esu-license) before proceeding.**

Here is the command line you should use to run it:

    ./Scripts/windows/DeleteESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores"

where:

- subscriptionId is the subscription ID of the Azure subscription where your ESU licenses are located.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- licenseResourceGroupName is the name of the resource group that contains the ESU license you want to delete.
- licenseName is the name of the ESU license you want to delete.

> **Note:** This script now supports **user token authentication** as an alternative to service principal authentication. You can use `Get-AzAccessToken -ResourceUrl https://management.azure.com/` to obtain a token and pass it using the `-userToken` parameter instead of providing tenantId, appID, and clientSecret.

## CheckESUStatus.ps1

This script checks whether Azure ARC servers have an ESU license resource assigned by making REST API calls to Azure and provides detailed status information about that assignment.

> **Note:** This script is **read-only** and does not make any changes to your ESU licenses or servers. It only retrieves and displays license status information.

Here is the command line you should use to run it for a single server:

    ./Scripts/windows/CheckESUStatus.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server"

For bulk checking using a CSV file:

    ./Scripts/windows/CheckESUStatus.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -csvFilePath "C:\Temp\ARC Servers to Check.csv"

where:

- subscriptionId is the subscription ID of the Azure subscription where your ARC servers are located.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- serverResourceGroupName is the name of the resource group that contains the Azure ARC server you want to check (for single server checks).
- ARCServerName is the name of the Azure ARC server you want to check ESU license status for (for single server checks).
- location is an optional compatibility parameter. Existing commands may continue to pass it, but the read-only status request does not use it.
- csvFilePath is the path to the CSV file that contains the list of ARC servers to check (for bulk processing).

### CSV File Format for CheckESUStatus.ps1

For bulk processing, the CSV file should contain the following columns:

- **Name** (or **ARCServerName**): The name of the ARC server to check
- **ServerResourceGroupName**: The resource group containing the ARC server
- **SubscriptionId** (optional): Override subscription for specific servers

### Output Information

The script provides comprehensive status information including:

- **License Status**: Licensed, No License Assigned, No ESU Profile, or Error
- **License Details**: License name, resource group, and **full license URI**
- **Summary Report**: Total servers checked, licensed servers, unlicensed servers, and errors
- **Export Options**: Results can be exported to CSV using the `-exportCsvPath` parameter

> **Note:** This script supports **user token authentication** as an alternative to service principal authentication. You can use `Get-AzAccessToken -ResourceUrl https://management.azure.com/` to obtain a token and pass it using the `-userToken` parameter instead of providing tenantId, appID, and clientSecret.

## ManageESUAssignments.ps1

This script will assign ESU licenses in bulk, taking its information from a CSV file. **Now supports cross-subscription scenarios** where ESU licenses can be located in different Azure subscriptions than the ARC servers.

> **The main goal for this script is to enable one (license) to many (Azure ARC servers) assignments. This is useful if/when you have a large number of Azure ARC servers that need to be assigned to the same license.**

Here is the command line you should use to run it:

    ./Scripts/windows/ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"

**For cross-subscription scenarios**, you can optionally specify a different subscription for ESU licenses:

    ./Scripts/windows/ManageESUAssignments.ps1 -arcServerSubscriptionId "00000000-0000-0000-0000-000000000001" -licenseSubscriptionId "00000000-0000-0000-0000-000000000004" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -location "EastUS" -csvFilePath "C:\foldername\ESULicensesAssignments.csv"

where:

- arcServerSubscriptionId is the subscription ID where your Azure ARC servers are located. The previous `-subscriptionId` name remains available as a compatibility alias.
- licenseSubscriptionId _(optional)_ is the subscription ID where your ESU licenses are located. If not provided, uses the same subscription as ARC servers.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- location is the Azure region where you ARC objects are deployed.
- csvFilePath is the path to the CSV file that contains the information about the ESU licenses assignments you want to apply to Azure ARC servers.

> The CSV file has to be manually created and should contain the following columns:

- Name: the name of the Azure ARC server you want to assign the license to.
- ServerResourceGroupName: the name of the resource group that contains the Azure ARC server.
- LicenseName: the name of the ESU license that will be assigned to the Azure ARC server.
- LicenseResourceGroupName: the name of the resource group that contains the ESU license you want to assign to the Azure ARC server.
- AssignESULicense: Set it to **True** if you want the license to be assigned to the Azure ARC server or **False** to unlink the license from the Azure ARC server.
- LicenseSubscriptionId _(optional)_: The subscription ID where the specific license is located. **This column always takes precedence** over the command line parameter when provided. If omitted, uses the script parameter or defaults to the ARC server subscription for backward compatibility.

Here is an example of the expected format of the CSV file:

![CSV File Layout](media/ManageESUAssignments_CSV_example.jpg)

### Cross-Subscription Examples

**Mixed scenario CSV** (some licenses in different subscriptions):

```csv
Name,ServerResourceGroupName,LicenseName,LicenseResourceGroupName,AssignESULicense,LicenseSubscriptionId
Server1,rg-servers,ESU-License-1,rg-licenses,True,00000000-0000-0000-0000-000000000004
Server2,rg-servers,ESU-License-2,rg-licenses,True,
Server3,rg-servers,ESU-License-3,rg-licenses,False,00000000-0000-0000-0000-000000000005
```

**Subscription Priority Logic:**

1. **CSV Column First**: If `LicenseSubscriptionId` is provided in the CSV row → always use that
2. **Command Line Parameter**: If no CSV value but `-licenseSubscriptionId` provided → use that
3. **Fallback**: Use ARC server subscription (backward compatibility)

> **Authentication:** You can pass a token returned by `Get-AzAccessToken -ResourceUrl https://management.azure.com/` through `-userToken` instead of providing `tenantId`, `appID`, and `clientSecret`.

> **Dry run:** `-DryRun` performs CSV and resource-access validation with read-only `GET` requests. It does not send `PUT`, `PATCH`, or `DELETE` requests.

## ManageESULicenses.ps1

This script creates, assigns, and manages Windows Server 2012, Windows Server 2012 R2, and Windows Server 2016 ESU licenses in bulk from one CSV file.

> **Agent requirement:** Windows Server 2012/R2 rows require Connected Machine agent 1.34 or later; Windows Server 2016 rows require 1.62 or later. If any row is below its target-specific minimum, the whole CSV fails validation before authentication or Azure requests.

The creation of the CSV file can be done in 2 ways:

### **Manually**:

(by providing the required information in the CSV file). Here are the columns that have to be present in the CSV file:

- Name: the name of the ESU license that will be created (usually matches a server name but not mandatory if you plan on using ESU licenses to cover multiple servers).
- Cores: the number of cores of the VM or physical server.
- IsVirtual: a value that indicates if the server is virtual or not, set is to **Virtual** for VMs or **Physical** for physical servers.
  > **Note:** The IsVirtual column is only used to determine the type of core that is going to be assigned to the license. You usually will almost always use vCore licenses unless you are covering physical servers.
- AgentVersion: the version of the Azure ARC agent installed on the server. This information can be retrieved from the Azure portal or by running the [Azure Resource Graph Explorer query](https://learn.microsoft.com/azure/governance/resource-graph/first-query-portal) mentioned below.
- Target (optional): one of the three exact values `Windows Server 2012`, `Windows Server 2012 R2`, or `Windows Server 2016`. A nonempty row value overrides `-target`; an empty or absent value uses `-target`, whose default is `Windows Server 2012`.
- InvoiceId (optional): the invoice ID for an applicable Windows Server 2012/R2 Volume Licensing transition. A nonempty row value overrides `-invoiceId`.
- ProgramYear (optional): `Year 1`, `Year 2`, or `Year 3` for an applicable Windows Server 2012/R2 transition. A nonempty row value overrides `-programYear`. An effective invoice is required when a program year is explicitly supplied.
- ServerResourceGroupName: the name of the resource group that contains the Azure ARC server.
- AssignESULicense: Set it to **True** if you want the license to be assigned to the Azure ARC server, **False** to unlink the license from the Azure ARC server or omit the value altogether to create a license without assigning it.

> **Note:** The AssignESULicense column is **optional** and is used IF/WHEN you want to manage license assignment as part of the script execution. Note that it is NOT automatically created when using Azure Graph Explorer to generate the CSV file. You will need to **manually** add it to the CSV file if you want to manage assignment of license as part of the execution of this script.

- ESUException: Optional text copied to the license resource's `ESU Usage` tag. Establish eligibility for any no-cost or evaluation scenario separately under the applicable Microsoft licensing terms before using this field.

Windows Server 2016 rows reject effective `InvoiceId` or explicit `ProgramYear` values and the reserved WS2012 exception values. For a mixed-target file that transitions only selected 2012/R2 rows, leave the batch transition parameters unbound and populate `InvoiceId` and `ProgramYear` only on those rows.

```csv
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException,Target,InvoiceId,ProgramYear
ws2012r2-app01,8,Virtual,1.62,rg-example-arc,True,,Windows Server 2012 R2,INV-EXAMPLE-001,Year 3
ws2016-app02,16,Physical,1.62,rg-example-arc,True,,Windows Server 2016,,
```

> **Billing warning:** Tags do not establish eligibility and do not affect billing. Microsoft states that billing is tied to the number of cores associated with the activated license regardless of tags. Do not provision cores for machines whose eligibility for a no-cost scenario has been established separately. See the [official license provisioning guidance](https://learn.microsoft.com/azure/azure-arc/servers/license-extended-security-updates).
> Bulk assignment of existing licenses is supported by [ManageESUAssignments.ps1](docs/English/windows/ManageESUAssignments.md).

Start with the copy-ready [ManageESULicenses CSV template](samples/ManageESULicenses.csv).

Here is an example of the expected format of the CSV file:

![Example CSV file](media/ManageESULicenses_CSV_Example.jpg)

### **Automatically**:

(by running the following [Azure Resource Graph Explorer query](https://learn.microsoft.com/azure/governance/resource-graph/first-query-portal) and saving its output to a CSV):

```kusto
resources
| where type =~ 'microsoft.hybridcompute/machines'
| extend OperatingSystem = tostring(properties.osSku)
| extend Target = case(
    OperatingSystem has 'Windows Server 2012 R2', 'Windows Server 2012 R2',
    OperatingSystem has 'Windows Server 2012', 'Windows Server 2012',
    OperatingSystem has 'Windows Server 2016', 'Windows Server 2016',
    '')
| where isnotempty(Target)
| extend AgentVersion = tostring(properties.agentVersion)
| extend ESUStatus = tostring(properties.licenseProfile.esuProfile.licenseAssignmentState)
| extend Cloud = tostring(properties.cloudMetadata.provider)
| extend IsVirtual = iff(properties.detectedProperties.model == 'Virtual Machine' or properties.detectedProperties.manufacturer == 'VMware, Inc.' or properties.detectedProperties.manufacturer == 'Nutanix' or Cloud in~ ('AWS', 'GCP'), 'Virtual', 'Physical')
| extend Cores = toint(properties.detectedProperties.coreCount), Model = tostring(properties.detectedProperties.model), Manufacturer = tostring(properties.detectedProperties.manufacturer)
| project Name=name, Cores, IsVirtual, AgentVersion, ServerResourceGroupName=resourceGroup, AssignESULicense='', ESUException='', Target, InvoiceId='', ProgramYear='', ESUStatus, OperatingSystem, Model, Manufacturer, Cloud
```

The query includes Windows Server 2012, Windows Server 2012 R2, and Windows Server 2016 and emits the exact `Target` strings accepted by the script. Filter and review the exported rows before use. You may keep the additional inventory columns for analysis, but retain all required CSV columns and any optional columns you intend to use.

Always review `Cores` and `IsVirtual`. Azure Resource Graph can return a null or incorrect core count or an incorrect physical/virtual classification. Replace a null or incorrect value with the verified machine value before running the script; never allow an unreviewed value to determine billing.

Here is the command line you should use to run it:

    ./Scripts/windows/ManageESULicenses.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -userToken $authenticationToken -licenseResourceGroupName "rg-example-esu" -location "EastUS" -state "Deactivated" -edition "Standard" -csvFilePath "C:\Examples\MixedTargets.csv" -licenseNamePrefix "ESU-" -DryRun

where:

- subscriptionId is the subscription ID of the Azure subscription where your ARC servers are located and where ESU licenses will be created.
- tenantId is the tenant ID of the Microsoft Entra ID tenant you want to use.
- appID is the application ID of the service principal you created in the prerequisites section.
- clientSecret is the secret key of the service principal you created in the prerequisites section.
- licenseResourceGroupName is the name of the resource group that will contain the ESU licenses.
- location is the Azure region where you want to deploy the ESU licenses.
- state is the activation state of the ESU license. It can be "Activated" or "Deactivated".
- edition is the edition of the ESU license. It can be "Standard" or "Datacenter".
- target (optional) sets the batch fallback target and accepts the three exact target values. It defaults to `Windows Server 2012`; a nonempty row `Target` takes precedence.
- csvFilePath is the path to the CSV file that contains the information about the ESU licenses you want to create.
- licenseNamePrefix (optional) is the prefix that will be used to create the ESU licenses. The script will concatenate the prefix with the content of the 'Name' found in the CSV to create the license name.
- licenseNameSuffix (optional) is the suffix that will be used to create the ESU licenses. The script will concatenate the suffix with the content of the 'Name' found in the CSV to create the license name.
- token (optional) is a valid Microsoft Entra ID authentication object that has the rights to create and assign ESU licenses.
- invoiceId and programYear are optional batch fallbacks for applicable Windows Server 2012/R2 Volume Licensing transition rows only. Nonempty row values take precedence. Do not bind these parameters for a mixed file containing Windows Server 2016 because the batch values would also apply to its rows and cause whole-file validation to fail.
- DryRun validates the full CSV, displays the target-aware plan, and performs only documented read-only Azure checks. `-WhatIf` also prevents create, modify, assign, and unlink requests.

### Notes

> **Note:** `-invoiceId` and `-programYear` apply only to eligible Windows Server 2012/R2 Volume Licensing transitions. Windows Server 2016 does not support this transition path.

> **Note:** The token parameter offers a way for you to work without having to rely on a Service Principal for authentication. You can either provide a token OR provide the tenantID, appID and clientSecret parameters. If you provide both, the token will be preferred and used.

> **Note**: you can use the optional parameters to add a prefix and/or suffix to the license name that will be created. If you specify "ESU-" as a prefix and "-marketing" as a suffix, the script will create licenses named "ESU-ServerName-marketing" for each server in the CSV file. That can help you differentiate licenses belonging to different departments or business units for example.

> **Note**: you can get a valid token Microsoft EntraID token by running the following command:

    $authenticationToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/ -TenantId $tenantId

> **Note**: you can use the optional parameters -log to specify a log file path.

## License

This project is licensed under the terms of the MIT license. See the [LICENSE](LICENSE) file.
