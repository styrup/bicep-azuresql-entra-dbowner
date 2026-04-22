# ---------------------------------------------------------------
# Add an Entra ID group as db_owner to an Azure SQL Database.
# Runs inside a Microsoft.Resources/deploymentScripts container.
# ---------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$sqlServerFqdn  = $env:SQL_SERVER_FQDN
$databaseName   = $env:SQL_DATABASE_NAME
$groupName      = $env:ENTRA_GROUP_NAME

Write-Host "Target : $sqlServerFqdn / $databaseName"
Write-Host "Group  : $groupName"

# --- Obtain access token for Azure SQL via the managed identity ---
$tokenResponse = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
if ($tokenResponse.Token -is [securestring]) {
    $accessToken = $tokenResponse.Token | ConvertFrom-SecureString -AsPlainText
} else {
    $accessToken = $tokenResponse.Token
}

# --- Connect to the database ---
$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Data Source=$sqlServerFqdn;Initial Catalog=$databaseName;Connect Timeout=30;Encrypt=True;TrustServerCertificate=False"
$conn.AccessToken = $accessToken
$conn.Open()
Write-Host 'Connected to database.'

try {
    # --- Build safe T-SQL using QUOTENAME to protect against special characters ---
    $sql = @"
-- Use QUOTENAME for safe identifier construction
DECLARE @groupName NVARCHAR(256) = @pGroupName;
DECLARE @quotedName NVARCHAR(260) = QUOTENAME(@groupName);
DECLARE @sql NVARCHAR(MAX);

-- 1. Create the user from Entra ID if it does not already exist
IF NOT EXISTS (
    SELECT 1 FROM sys.database_principals
    WHERE name = @groupName AND type IN ('E', 'X')
)
BEGIN
    SET @sql = N'CREATE USER ' + @quotedName + N' FROM EXTERNAL PROVIDER';
    EXEC sp_executesql @sql;
    PRINT 'User created: ' + @groupName;
END
ELSE
BEGIN
    PRINT 'User already exists: ' + @groupName;
END

-- 2. Add the user to db_owner if not already a member
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    JOIN sys.database_principals r  ON rm.role_principal_id  = r.principal_id
    JOIN sys.database_principals m  ON rm.member_principal_id = m.principal_id
    WHERE r.name = N'db_owner' AND m.name = @groupName
)
BEGIN
    SET @sql = N'ALTER ROLE [db_owner] ADD MEMBER ' + @quotedName;
    EXEC sp_executesql @sql;
    PRINT 'Added to db_owner: ' + @groupName;
END
ELSE
BEGIN
    PRINT 'Already member of db_owner: ' + @groupName;
END
"@

    $cmd = New-Object System.Data.SqlClient.SqlCommand($sql, $conn)
    $cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@pGroupName', $groupName))) | Out-Null
    $cmd.CommandTimeout = 60

    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host 'Script completed successfully.'
}
finally {
    $conn.Close()
    Write-Host 'Connection closed.'
}

$DeploymentScriptOutputs = @{
    groupName    = $groupName
    databaseName = $databaseName
    result       = 'SUCCESS'
}
