# CheckESUStatus.ps1

This script checks whether Azure ARC servers have an ESU license resource assigned by making REST API calls to Azure and provides detailed status information about that assignment.

> **Note:** This script is read-only and does not make any changes to your ESU licenses or servers. It only retrieves and displays license status information.

Here are the command lines you should use to run it:

## Single Server Check (Service Principal Authentication)

    ./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server"

## Single Server Check (User Token Authentication)

    $authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
    ./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server" -userToken $authToken

## Bulk Server Check (CSV File)

    ./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -csvFilePath "C:\Temp\ARC Servers to Check.csv"

## Parameters

| Parameter               | Description                                                                                                             | Required |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------- | -------- |
| subscriptionId          | The subscription ID of the Azure subscription where the ARC servers are located.                                        | Yes      |
| tenantId                | The tenant ID of the Microsoft Entra ID tenant you want to use.                                                         | No\*     |
| appID                   | The application ID of the service principal you created in the prerequisites section.                                   | No\*     |
| clientSecret            | The secret key of the service principal you created in the prerequisites section.                                       | No\*     |
| serverResourceGroupName | The name of the resource group that contains the Azure ARC server you want to check. Required for single server checks. | No\*\*   |
| ARCServerName           | The name of the Azure ARC server you want to check ESU license status for. Required for single server checks.           | No\*\*   |
| location                | Retained for compatibility with existing command lines; the read-only status request does not use it.                  | No       |
| csvFilePath             | The full path to the CSV file containing the list of ARC servers to check. Required for bulk processing.                | No\*\*\* |
| logFileName             | The name of the log file to be created (optional).                                                                      | No       |
| userToken               | A valid Microsoft Entra ID authentication token object (alternative to service principal).                              | No\*     |
| exportCsvPath           | Export results to a CSV file with detailed status information (optional).                                               | No       |

**Authentication Requirements:**

- \* You must provide either service principal credentials (tenantId, appID, clientSecret) OR a valid userToken
- \*\* Required when checking a single server (not using CSV file)
- \*\*\* Required when doing bulk processing (not checking a single server)

> **Note:** The userToken parameter offers a way for you to work without having to rely on a Service Principal for authentication. You can either provide a token OR provide the tenantID, appID and clientSecret parameters. If you provide both, **the token will be used**.

> **Compatibility note:** Existing command lines may continue to pass `-location`, but new commands can omit it.

## CSV File Format for Bulk Processing

When using the `-csvFilePath` parameter for bulk processing, the CSV file should contain the following columns:

### Required Columns:

- **Name** (or **ARCServerName**): The name of the ARC server to check
- **ServerResourceGroupName**: The resource group containing the ARC server

### Optional Columns:

- **SubscriptionId**: Override subscription for specific servers (if different from the script parameter)

Here is an example of the expected format of the CSV file:

| Name            | ServerResourceGroupName | SubscriptionId                       |
| --------------- | ----------------------- | ------------------------------------ |
| WIN-2K12R2-01   | rg-arcservers           | 00000000-0000-0000-0000-000000000001 |
| WIN-2K12R2-02   | rg-arcservers-prod      |                                      |
| SRV-DATABASE-01 | rg-database-servers     | 00000000-0000-0000-0000-000000000004 |

> **Note:** If SubscriptionId is not provided for a server in the CSV, the script will use the subscriptionId parameter value for that server.

## Output Information

The script provides comprehensive status information for each server:

### License Status Types:

- **Licensed**: The server license profile contains an assigned ESU license resource ID. This status does not independently verify the referenced license's activation or provisioning state.
- **No License Assigned**: Server has an ESU profile but no license assigned
- **No ESU Profile**: Server has no ESU profile configured
- **Error**: Error occurred while checking the server

### Information Displayed:

For each server with a license, the script shows:

- Server name and resource group
- License status
- License name and resource group
- **Full license URI** (complete Azure Resource Manager path)

### Summary Report:

- Total servers checked
- Number of servers with assigned ESU license resource IDs
- Number of servers without ESU licenses
- Number of servers with errors

## Export Options

Use the `-exportCsvPath` parameter to export detailed results to a CSV file:

    ./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -csvFilePath "C:\servers.csv" -exportCsvPath "C:\Results\ESU-Status-Report.csv"

The exported CSV contains all server details including license URIs, status, timestamps, and error messages.

## Logging

Use the `-logFileName` parameter to create a transcript log of the script execution:

    ./CheckESUStatus -subscriptionId "00000000-0000-0000-0000-000000000001" -tenantId "00000000-0000-0000-0000-000000000002" -appID "00000000-0000-0000-0000-000000000003" -clientSecret "your_application_secret_value" -serverResourceGroupName "rg-arcservers" -ARCServerName "Win2012-Server" -logFileName "C:\Logs\ESU-Check.log"

## Sample Output

```
==============================================
Starting ESU License Status Check
==============================================

[INFO] Getting authentication token from Microsoft Entra ID
[INFO] Checking ESU license status for server 'WIN-2K12R2-01' in resource group 'rg-arcservers'
[SUCCESS] Server 'WIN-2K12R2-01' has ESU license assigned: ESU-WIN-2K12R2-01

License URI: /subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-esulicenses/providers/Microsoft.HybridCompute/licenses/ESU-WIN-2K12R2-01

==============================================
ESU License Status Summary
==============================================

[INFO] Total servers checked: 1
[SUCCESS] Servers with valid ESU licenses: 1
[INFO] Servers without ESU licenses: 0
[INFO] Servers with errors: 0

Detailed Results:
=================
Server: WIN-2K12R2-01 | Resource Group: rg-arcservers | Status: Licensed
  License: ESU-WIN-2K12R2-01 | License RG: rg-esulicenses
```

## Prerequisites

Before running this script, ensure you have:

1. **PowerShell Core 7.x or later** installed
2. **Azure Arc servers** onboarded and visible in Azure
3. **Authentication credentials** (either service principal or Azure PowerShell login for user token)
4. **Appropriate permissions** to read ARC server resources and license profiles

## Use Cases

This script is useful for:

- **Compliance Auditing**: Verify which servers have ESU licenses applied
- **License Management**: Get a comprehensive view of your ESU license assignments
- **Troubleshooting**: Identify servers that may not have licenses properly assigned
- **Reporting**: Generate detailed reports of ESU license status across your environment
- **Planning**: Understand your current ESU coverage before making changes

## Error Handling

The script includes comprehensive error handling for common scenarios:

- **404 Errors**: Server not found or no license profile exists
- **403 Errors**: Access denied (check permissions)
- **Authentication Failures**: Invalid credentials or expired tokens
- **CSV File Issues**: Missing files or invalid format
- **Network Issues**: Connection problems with Azure APIs

[]: # Path: docs/CheckESUStatus.md
