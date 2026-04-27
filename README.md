# Azure SQL – Add Entra ID Group to Database Role (Bicep deploymentScript)

Bicep template that uses `Microsoft.Resources/deploymentScripts` to add an
Entra ID group to a **SQL database role** on an Azure SQL Database.
The role is configurable (default: `db_owner`).

## File structure

```bash
main.bicep                              # Bicep template
scripts/
  add-entra-group-db-role.ps1           # PowerShell script executed by the deploymentScript
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

### Understanding the identities involved

There are **three separate identities** that each play a distinct role. Confusing them
is a common source of errors:

| Identity | Purpose | Required permissions |
| --- | --- | --- |
| **Deployment script managed identity** (parameter `managedIdentityResourceId`) | Runs the PowerShell script, obtains an access token and logs in to SQL Server | Must be set as **Entra ID admin** on the SQL Server (or already have a database user with `CREATE USER` / `ALTER ROLE` rights). When using private networking, must also have **Storage File Data Privileged Contributor** on the storage account |
| **SQL Server Entra ID admin** | The identity that is allowed to authenticate to SQL Server | Should be the same as the deployment script MI (see above) |
| **SQL Server's own identity** (system- or user-assigned MI on the SQL Server *resource*) | Used **internally by SQL Server** to look up Entra ID principals via Microsoft Graph when executing `CREATE USER ... FROM EXTERNAL PROVIDER` | Must have **Directory Readers** role in Entra ID, *or* the following Microsoft Graph application permissions: `User.Read.All`, `GroupMember.Read.All`, `Application.Read.All` |

> **Important:** The SQL Server Entra admin does **not** need Directory Readers.
> Conversely, the SQL Server's own identity does **not** need to be the Entra admin.
> They serve completely different purposes.

## Parameters

| Parameter                    | Required | Description                                                                                                  |
| ---------------------------- | -------- | ------------------------------------------------------------------------------------------------------------ |
| `sqlServerFqdn`              | ✅       | FQDN of the SQL Server (e.g. `myserver.database.windows.net`)                                                |
| `sqlDatabaseName`            | ✅       | Name of the target database                                                                                  |
| `entraIdGroupName`           | ✅       | Display name of the Entra ID group                                                                           |
| `managedIdentityResourceId`  | ✅       | Full resource ID of the user-assigned managed identity                                                       |
| `sqlRoleName`                |          | SQL database role to assign (default: `db_owner`). Examples: `db_datareader`, `db_datawriter`, `db_ddladmin`  |
| `enableDebug`                |          | Enable debug output including JWT token payload (default: `false`)                                            |
| `location`                   |          | Azure region (default: resource group location)                                                            |
| `forceUpdateTag`             |          | Change to force re-execution (default: `utcNow()`)                                                        |
| `subnetResourceId`           |          | Resource ID of the subnet for private networking (see below)                                             |
| `storageAccountName`         |          | Name of the storage account in the VNet (required with `subnetResourceId`)                                |
| `customdnsserver`            |          | IP of a custom DNS server for the container (see [DNS caveat](#dns-caveat-for-private-networking) below) |
| `azPowerShellVersion`        |          | Version of the Az PowerShell module (default: `15.5`)                                                     |

## Deploy – public network

```bash
# Azure CLI – default role (db_owner)
az deployment group create \
  --resource-group <rg-name> \
  --template-file main.bicep \
  --parameters \
    sqlServerFqdn='myserver.database.windows.net' \
    sqlDatabaseName='mydb' \
    entraIdGroupName='MyEntraGroup' \
    managedIdentityResourceId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>'
```

```bash
# Azure CLI – custom role with debug enabled
az deployment group create \
  --resource-group <rg-name> \
  --template-file main.bicep \
  --parameters \
    sqlServerFqdn='myserver.database.windows.net' \
    sqlDatabaseName='mydb' \
    entraIdGroupName='MyEntraGroup' \
    managedIdentityResourceId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>' \
    sqlRoleName='db_datareader' \
    enableDebug=true
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
    storageAccountName='<storage-account-name>' \
    customdnsserver='10.0.0.4'
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
  -storageAccountName '<storage-account-name>' `
  -customdnsserver '10.0.0.4'
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

### DNS caveat for private networking

When a `deploymentScripts` container runs inside a delegated subnet, the underlying
Azure Container Instance **does not always use the custom DNS servers** configured on
the VNet. It may fall back to Azure's default DNS (`168.63.129.16`), which means a
SQL Server private endpoint FQDN could resolve to the **public** IP instead of the
private one.

Two ways to handle this:

1. **Private DNS Zone (recommended)** – Create a Private DNS Zone
   `privatelink.database.windows.net` linked to your VNet. Azure's default DNS will
   then resolve the SQL FQDN to the private endpoint IP automatically, and no custom
   DNS parameter is needed.

2. **`customdnsserver` parameter** – If you run your own DNS server (e.g. for
   on-premises forwarding), pass its IP via the `customdnsserver` parameter. The
   PowerShell script will use this server explicitly for name resolution via simply overwrite */etc/resolv.conf* with the specified DNS server.

When useing private networking, **always verify the DNS resolution** of the Azure Storage account and the Container instance. It must resolve to private IPs, otherwise the deployment script won't be able to access the storage account. To be sure please add a local dns zone and add the storage account name with the private endpoint IP as an A record.

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
- Checks whether the user is already a member of the specified role in `sys.database_role_members` before `ALTER ROLE`.
- `forceUpdateTag` (default `utcNow()`) ensures the script runs on every deployment.

## Security

- SQL identifiers are handled with `QUOTENAME()` and parameterized SQL to prevent injection.
- Both the group name and role name are passed as environment variables and bound as SQL parameters.
- The access token is obtained via managed identity – no credentials in the template.
- Debug output (JWT payload) is disabled by default and must be explicitly enabled via `enableDebug`.
