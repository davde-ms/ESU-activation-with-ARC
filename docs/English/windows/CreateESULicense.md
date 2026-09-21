# CreateESULicense.ps1

This script creates or updates an Azure Arc ESU license for Windows Server 2012, Windows Server 2012 R2, or Windows Server 2016.

Here are the command lines you should use to run it:

## Service Principal Authentication

    ./Scripts/windows/CreateESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "WS2016-Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8 -target "Windows Server 2016"

## User Token Authentication

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./Scripts/windows/CreateESULicense.ps1 -subscriptionId "00000000-0000-0000-0000-000000000001" -licenseResourceGroupName "rg-ARC-ESULicenses" -licenseName "Standard-8vcores" -location "EastUS" -state "Activated" -edition "Standard" -coreType "vCore" -coreCount 8 -userToken $authToken

## Parameters

Where:

| Parameter                | Description                                                                                | Required |
| ------------------------ | ------------------------------------------------------------------------------------------ | -------- |
| subscriptionId           | The subscription ID of the Azure subscription you want to use.                             | Yes      |
| tenantId                 | The tenant ID of the Microsoft Entra ID tenant you want to use.                            | No\*     |
| appID                    | The application ID of the service principal you created in the prerequisites section.      | No\*     |
| clientSecret             | The secret key of the service principal you created in the prerequisites section.          | No\*     |
| licenseResourceGroupName | The name of the resource group that will contain the ESU license.                          | Yes      |
| licenseName              | The name of the ESU license you want to create.                                            | Yes      |
| location                 | The Azure region where you want to deploy the ESU license.                                 | Yes      |
| state                    | The activation state of the ESU license. It can be "Activated" or "Deactivated".           | Yes      |
| edition                  | The edition of the ESU license. It can be "Standard" or "Datacenter".                      | Yes      |
| coreType                 | The core type of the ESU license. It can be "vCore" or "pCore".                            | Yes      |
| coreCount                | Even core count: 8-128 for `vCore` or 16-256 for `pCore`.                                  | Yes      |
| target                   | Exact license target: `Windows Server 2012`, `Windows Server 2012 R2`, or `Windows Server 2016`. Defaults to `Windows Server 2012` when omitted. | No |
| userToken                | A valid Microsoft Entra ID authentication token object (alternative to service principal). | No\*     |

**Authentication Requirements:**

- \* You must provide either service principal credentials (tenantId, appID, clientSecret) OR a valid userToken

The script rejects odd or out-of-range core counts; it does not calculate or normalize the value.

> **Note:** The userToken parameter offers a way for you to work without having to rely on a Service Principal for authentication. You can either provide a token OR provide the tenantID, appID and clientSecret parameters. If you provide both, **the token will be used**.

**Note:** The script can also be rerun with the same base parameters to change some of the properties of the license. Those properties are:

- **state** (allows you to create a deactivated license and activate it later)
- **coreCount** (allows you to change the number of cores of the license if you have need to increase or decrease it)

> **All other parameters are immutable and cannot be changed once the license is created.**

## Target prerequisites and eligibility

- Windows Server 2012/2012 R2 requires Azure Connected Machine agent 1.34 or later. Windows Server 2016 requires agent 1.62 or later.
- Windows Server 2016 ESUs support Standard and Datacenter editions. General eligibility requires qualifying Software Assurance (SA) or an equivalent Server Subscription. For Windows Server 2016 workloads running on-premises, SA is required. The Windows Server 2016 offer is not available through SPLA, does not support transition from Volume Licensing, and has no documented Visual Studio dev/test benefit.
- The reserved values `WS2012 VISUAL STUDIO DEV TEST`, `WS2012 DISASTER RECOVERY`, and `WS2012 MULTIPURPOSE` apply only to Microsoft's documented Windows Server 2012/R2 exception flow. Do not reuse them for Windows Server 2016 or treat any tag as an entitlement or billing control.
- Azure Arc-enabled servers used for these Windows Server ESUs are not currently available in Azure operated by 21Vianet.
- For Windows Server 2016, follow Microsoft's current [preparation guidance](https://learn.microsoft.com/azure/azure-arc/servers/prepare-extended-security-updates) for the applicable licensing package and servicing stack update (SSU). Microsoft does not currently name a Windows Server 2016 KB on that page; do not substitute the Windows Server 2012 KB.

## Billing safeguards

Windows Server 2016 reaches end of support on January 12, 2027, and Azure Arc ESU billing begins January 13, 2027. An activated license starts billing even when it is not assigned to a server. Late enrollment and licenses or cores added after end of support are back-billed to the applicable end-of-support date. Reactivation, recreation, region changes, and tenant changes are also subject to back-billing. Decreasing cores, deactivating, or deleting a license can continue to incur charges for up to five calendar days. Review Microsoft's current [billing guidance](https://learn.microsoft.com/azure/azure-arc/servers/billing-extended-security-updates) before activation or modification.

## Preview and confirmation

Add `-WhatIf` to preview the license target and operation without sending the Azure REST update. Run without `-WhatIf` after reviewing the action. Add `-Confirm` when you want PowerShell to ask before creation or modification.

```powershell
./Scripts/windows/CreateESULicense.ps1 <parameters> -WhatIf
./Scripts/windows/CreateESULicense.ps1 <parameters> -Confirm
```

## Troubleshooting

| Message or symptom | What to check |
| --- | --- |
| Authentication token is missing or expired | Supply all three service principal parameters, or obtain a new `Get-AzAccessToken` token object. |
| `401` or `403` response | Verify the identity can create or update ESU licenses in the target resource group. |
| `404` response | Check the subscription and license resource group names. |
| Conflict or immutable-property response | Keep the existing license's edition, core type, and location; only supported properties can be updated. |
| Core-count validation fails | Use an even value from 8 through 128 for `vCore`, or from 16 through 256 for `pCore`, with a supported edition/core-type combination. |
| Script exits with code `1` | Read the final failure message, correct the input or permission, and rerun with `-WhatIf`. |
