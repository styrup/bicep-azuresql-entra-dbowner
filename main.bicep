// ---------------------------------------------------------------------------
// Adds an Entra ID group to a SQL database role on an Azure SQL Database
// using a deploymentScript with AzurePowerShell.
//
// Prerequisites:
//   1. SQL Server has Entra ID authentication enabled with an Entra admin set
//   2. The user-assigned managed identity is the Entra ID admin of the SQL Server
//      (or already has permission to CREATE USER and ALTER ROLE in the target DB)
//   3. The SQL Server identity has Directory Readers role (or equivalent Graph permissions)
//      so it can resolve external Entra ID principals
//   4. Network access:
//      - Public: SQL Server firewall allows Azure services
//      - Private endpoint: provide subnetResourceId + storageAccountName
//        (subnet must be delegated to Microsoft.ContainerInstance/containerGroups
//         and have connectivity + DNS resolution to the SQL private endpoint)
// ---------------------------------------------------------------------------

// ── Required parameters ─────────────────────────────────────────────────────

@description('FQDN of the Azure SQL Server (e.g. myserver.database.windows.net)')
param sqlServerFqdn string

@description('Name of the target database')
param sqlDatabaseName string

@description('Display name of the Entra ID group to add to the specified SQL role')
param entraIdGroupName string

@description('Resource ID of the user-assigned managed identity used to authenticate to Azure SQL')
param managedIdentityResourceId string

// ── Optional parameters ─────────────────────────────────────────────────────

@description('Location for the deployment script resource')
param location string = resourceGroup().location

@description('Change this value to force the deployment script to re-execute (e.g. a new GUID or timestamp)')
param forceUpdateTag string = utcNow()

// ── Private networking (optional – set both to enable) ──────────────────────

@description('Resource ID of the subnet for running the deployment script in a VNet (required for private endpoint scenarios). The subnet must be delegated to Microsoft.ContainerInstance/containerGroups.')
param subnetResourceId string = ''

@description('Name of a storage account in the same VNet for deployment script file shares (required when subnetResourceId is set). The managed identity must have Storage File Data Privileged Contributor on this account.')
param storageAccountName string = ''

@description('Custom DNS server IP address for the deployment script container group (optional, only needed if using private networking and your DNS is not handled by Azure). Note: the custom DNS server must be able to resolve the SQL Server FQDN to the private endpoint IP address.')
param customdnsserver string = ''

@description('SQL database role to assign the Entra ID group to (e.g. db_owner, db_datareader, db_datawriter)')
param sqlRoleName string = 'db_owner'

@description('Enable debug output including JWT token payload (default: false)')
param enableDebug bool = false

@description('Version of Az PowerShell module to use in the deployment script')
param azPowerShellVersion string = '15.5'

// ── Computed ────────────────────────────────────────────────────────────────

var usePrivateNetworking = !empty(subnetResourceId) && !empty(storageAccountName)

// ── Deployment Script ───────────────────────────────────────────────────────

resource addGroupToDatabase 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'add-entra-group-db-role-${uniqueString(sqlServerFqdn, sqlDatabaseName, entraIdGroupName)}'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityResourceId}': {}
    }
  }
  properties: {
    azPowerShellVersion: azPowerShellVersion
    forceUpdateTag: forceUpdateTag
    retentionInterval: 'P1D'
    cleanupPreference: 'OnSuccess'
    timeout: 'PT10M'
    environmentVariables: [
      { name: 'SQL_SERVER_FQDN', value: sqlServerFqdn }
      { name: 'SQL_DATABASE_NAME', value: sqlDatabaseName }
      { name: 'ENTRA_GROUP_NAME', value: entraIdGroupName }
      { name: 'CUSTOM_DNS_SERVER', value: customdnsserver }
      { name: 'SQL_ROLE_NAME', value: sqlRoleName }
      { name: 'ENABLE_DEBUG', value: string(enableDebug) }
      { name: 'USE_PRIVATE_NETWORKING', value: string(usePrivateNetworking) }
    ]
    scriptContent: loadTextContent('scripts/add-entra-group-db-role.ps1')
    containerSettings: usePrivateNetworking
      ? {
          subnetIds: [
            { id: subnetResourceId }
          ]
        }
      : null
    storageAccountSettings: usePrivateNetworking
      ? {
          storageAccountName: storageAccountName
        }
      : null
  }
}

output deploymentScriptName string = addGroupToDatabase.name
output deploymentScriptStatus string = addGroupToDatabase.properties.provisioningState
