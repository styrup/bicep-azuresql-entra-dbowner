# Azure SQL – Add Entra ID Group as db_owner (Bicep deploymentScript)

Bicep template that uses `Microsoft.Resources/deploymentScripts` to add an
Entra ID group as **db_owner** on an Azure SQL Database.

## File structure

```bash
main.bicep                              # Bicep template
scripts/
  add-entra-group-db-owner.ps1          # PowerShell script executed by the deploymentScript
README.md
```

## Prerequisites

1. **Entra ID authentication** is enabled on the Azure SQL Server with an Entra ID admin configured.
2. **User-assigned managed identity** is either:
   - Set as the Entra ID admin on the SQL Server, **or**
   - Already has permissions to `CREATE USER` and `ALTER ROLE` in the target database.
3. **SQL Server identity** (system- or user-assigned) has the **Directory Readers** role
   in Entra ID, so the server can resolve external Entra ID principals.
4. **Network / Firewall**: The SQL Server must allow connections from Azure services
   (*"Allow Azure services and resources to access this server"*), or
   the deployment script must run in a delegated subnet with access.
5. **The Entra ID group** must exist in the tenant.

## Parameters

| Parameter                    | Required | Description                                                                |
| ---------------------------- | -------- | -------------------------------------------------------------------------- |
| `sqlServerFqdn`              | ✅       | FQDN of the SQL Server (e.g. `myserver.database.windows.net`)              |
| `sqlDatabaseName`            | ✅       | Name of the target database                                                |
| `entraIdGroupName`           | ✅       | Display name of the Entra ID group                                         |
| `managedIdentityResourceId`  | ✅       | Full resource ID of the user-assigned managed identity                     |
| `location`                   |          | Azure region (default: resource group location)                            |
| `forceUpdateTag`             |          | Change to force re-execution (default: `utcNow()`)                        |
| `subnetResourceId`           |          | Resource ID of the subnet for private networking (see below)               |
| `storageAccountName`         |          | Name of the storage account in the VNet (required with `subnetResourceId`) |

## Deploy – public network

```bash
# Azure CLI
az deployment group create \
  --resource-group <rg-name> \
  --template-file main.bicep \
  --parameters \
    sqlServerFqdn='myserver.database.windows.net' \
    sqlDatabaseName='mydb' \
    entraIdGroupName='MyEntraGroup' \
    managedIdentityResourceId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>'
```

```powershell
# Azure PowerShell
New-AzResourceGroupDeployment `
  -ResourceGroupName '<rg-name>' `
  -TemplateFile './main.bicep' `
  -sqlServerFqdn 'myserver.database.windows.net' `
  -sqlDatabaseName 'mydb' `
  -entraIdGroupName 'MyEntraGroup' `
  -managedIdentityResourceId '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>'
```

## Deploy – private endpoint

If your SQL Server is only accessible via a private endpoint, the deployment script must
run inside a VNet. Provide `subnetResourceId` and `storageAccountName`:

```bash
# Azure CLI
az deployment group create \
  --resource-group <rg-name> \
  --template-file main.bicep \
  --parameters \
    sqlServerFqdn='myserver.database.windows.net' \
    sqlDatabaseName='mydb' \
    entraIdGroupName='MyEntraGroup' \
    managedIdentityResourceId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<mi-name>' \
    subnetResourceId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>' \
    storageAccountName='<storage-account-name>'
```

```powershell
# Azure PowerShell
New-AzResourceGroupDeployment `
  -ResourceGroupName '<rg-name>' `
  -TemplateFile './main.bicep' `
  -sqlServerFqdn 'myserver.database.windows.net' `
  -sqlDatabaseName 'mydb' `
  -entraIdGroupName 'MyEntraGroup' `
  -managedIdentityResourceId '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<mi-name>' `
  -subnetResourceId '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>' `
  -storageAccountName '<storage-account-name>'
```

### Why is a storage account needed?

When a deployment script runs inside a VNet (via `containerSettings.subnetIds`), Azure
cannot use its internal infrastructure to transfer script files to the container. Instead,
Azure mounts an **Azure File Share** from the specified storage account as a volume in the
Azure Container Instance. This is where the PowerShell script and any output files are
stored during execution. Therefore the storage account must:

- Be accessible from the subnet the container runs in
- Grant the managed identity write access via the **Storage File Data Privileged Contributor** role

Without private networking, Azure handles this automatically using an internal storage
account and the parameter can be omitted.

### Subnet and storage account requirements

| Resource            | Configuration                                                                                         |
| ------------------- | ----------------------------------------------------------------------------------------------------- |
| **Subnet**          | Delegated to `Microsoft.ContainerInstance/containerGroups`                                             |
|                     | Service endpoint `Microsoft.Storage` enabled                                                          |
|                     | Network access + DNS resolution to the SQL Server private endpoint                                    |
| **Storage account** | In the same VNet (or with the subnet added to its firewall rules)                                     |
|                     | Managed identity has the **Storage File Data Privileged Contributor** role                             |
|                     | *"Allow Azure services on the trusted services list"* enabled under Networking → Exceptions           |

## Idempotency

The script is fully idempotent:

- Checks whether the user already exists in `sys.database_principals` before `CREATE USER`.
- Checks whether the user is already a member of `db_owner` in `sys.database_role_members` before `ALTER ROLE`.
- `forceUpdateTag` (default `utcNow()`) ensures the script runs on every deployment.

## Security

- SQL identifiers are handled with `QUOTENAME()` and parameterized SQL to prevent injection.
- The group name is passed as an environment variable and bound as a SQL parameter.
- The access token is obtained via managed identity – no credentials in the template.
