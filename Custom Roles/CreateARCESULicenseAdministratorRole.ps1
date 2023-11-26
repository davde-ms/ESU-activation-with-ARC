<# 
//-----------------------------------------------------------------------

THE SUBJECT SCRIPT IS PROVIDED “AS IS” WITHOUT ANY WARRANTY OF ANY KIND AND SHOULD ONLY BE USED FOR TESTING OR DEMO PURPOSES.
YOU ARE FREE TO REUSE AND/OR MODIFY THE CODE TO FIT YOUR NEEDS

//-----------------------------------------------------------------------

.SYNOPSIS
Creates a custom Azure role that can be used to assign ESU licenses to ARC server objects.

.DESCRIPTION
This script will create a custom Azure role that can be used to assign ESU licenses to ARC server objects.
You can edit the scope for the role to make it available at the subscription or management group level.
You can also edit the name and description of the role to fit your needs.

.NOTES
File Name : CreateARCESULicenseAdministratorRole.ps1
Author    : David De Backer
Version   : 1.0
Date      : 24-November-2023
Update    : 24-November-2023
Tested on : PowerShell Version 7.3.8
Module    : Azure Powershell version 9.6.0
Requires  : Powershell Core version 7.x or later
Product   : Azure

.CHANGELOG
v1.0 - Initial release

.LINK
A list of the syntax of valid scope values can be found here:
https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions#assignablescopes

.EXAMPLE-1
./CreateARCESULicenseAdministratorRole -scope "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

for single subscription assignment scope

or

./CreateARCESULicenseAdministratorRole -scope "managementgroupname"

for assignment scope at a management group level

#>

##############################
#Parameters definition block #
##############################

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, HelpMessage="The ID of the subscription where the license will be created.")]
    [ValidatePattern('(^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$)|^([a-zA-Z0-9_\(\)\.\-]{1,90})$)', ErrorMessage="The input '{0}' has to be a valid subscription ID or a valid management group name.")]
    [Alias("s")]
    [string]$scope,

    [Parameter (Mandatory=$false, HelpMessage="The name of the custom role you want to create.")]
    [Alias("name")]
    [string] $roleName = "ARC ESU License Administrator",

    [Parameter (Mandatory=$false, HelpMessage="The description of the custome role you want to create.")]
    [Alias("desc")]
    [string] $roleDescription = "ESU License administrator, grants the rights to create, manage and assign ESU licenses to ARC server nodes."
)

#####################################
#End of Parameters definition block #
#####################################

##############################
# Variables definition block #
##############################

#########################################
# End of the variables definition block #
#########################################

#####################
# Main script block #
#####################

# Getting hold of an existing role and modifying it to create a our custom role
$role = Get-AzRoleDefinition -Name "Virtual Machine Contributor"

# Replacing the name and description of the role
$role.Name = $roleName
$role.Description = $roleDescription

# Clearing the existing role properties so that we have a clean slate to work with
$role.Id = $null
$role.IsCustom = $True
$role.Actions.Clear()
$role.DataActions.Clear()
$role.AssignableScopes.Clear()
$role.AssignableScopes.Clear()

# Adding the required actions to the role
$role.Actions.Add("Microsoft.HybridCompute/licenses/read")
$role.Actions.Add("Microsoft.HybridCompute/licenses/write")
$role.Actions.Add("Microsoft.HybridCompute/licenses/delete")
$role.Actions.Add("Microsoft.HybridCompute/machines/licenseProfiles/read")
$role.Actions.Add("Microsoft.HybridCompute/machines/licenseProfiles/write")
$role.Actions.Add("Microsoft.HybridCompute/machines/licenseProfiles/delete")


# Setting the scope of the role
if ($scope -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    $role.AssignableScopes.Add("/subscriptions/$scope")
} else {
    $role.AssignableScopes.Add("/providers/Microsoft.Management/managementGroups/$scope")
}

Write-Output "Role definition created with the following properties: $role"

# Writing the new role back to Azure
try {
    New-AzRoleDefinition -Role $role
} catch {
    Write-Error "Failed to create new Azure role definition: $_"
    throw
}