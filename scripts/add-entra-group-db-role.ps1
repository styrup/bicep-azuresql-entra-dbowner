# ---------------------------------------------------------------
# Add an Entra ID group to a SQL database role on Azure SQL Database.
# Runs inside a Microsoft.Resources/deploymentScripts container.
# ---------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$sqlServerFqdn = $env:SQL_SERVER_FQDN
$databaseName = $env:SQL_DATABASE_NAME
$groupName = $env:ENTRA_GROUP_NAME
$roleName = if ([string]::IsNullOrEmpty($env:SQL_ROLE_NAME)) { 'db_owner' } else { $env:SQL_ROLE_NAME }
$enableDebug = $env:ENABLE_DEBUG -eq 'true'

$customDNSServer = $ENV:CUSTOM_DNS_SERVER
if (-not [string]::IsNullOrEmpty($customDNSServer)) {
    Write-Host "Using custom DNS server: $customDNSServer"
    Write-Output "nameserver $customDNSServer" | Out-File -FilePath /etc/resolv.conf -Encoding ascii -Force
}
else {
    Write-Host "No custom DNS server specified, using default."
}

Write-Host "--------"
Write-Host "Target : $sqlServerFqdn / $databaseName"
Write-Host "Group  : $groupName"
Write-Host "Role   : $roleName"
Write-Host "Debug  : $enableDebug"

# --- Obtain access token for Azure SQL via the managed identity ---
$tokenResponse = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
if ($tokenResponse.Token -is [securestring]) {
    $accessToken = $tokenResponse.Token | ConvertFrom-SecureString -AsPlainText
}
else {
    $accessToken = $tokenResponse.Token
}

# --- Debug: decode JWT to verify identity ---
if ($enableDebug) {
    $jwtParts = $accessToken.Split('.')
    $b64 = $jwtParts[1].Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) { 2 { $b64 += '==' } 3 { $b64 += '=' } }
    $payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    Write-Host "JWT payload: $payload"
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
DECLARE @roleName NVARCHAR(256) = @pRoleName;
DECLARE @quotedName NVARCHAR(260) = QUOTENAME(@groupName);
DECLARE @quotedRole NVARCHAR(260) = QUOTENAME(@roleName);
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

-- 2. Add the user to the specified role if not already a member
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    JOIN sys.database_principals r  ON rm.role_principal_id  = r.principal_id
    JOIN sys.database_principals m  ON rm.member_principal_id = m.principal_id
    WHERE r.name = @roleName AND m.name = @groupName
)
BEGIN
    SET @sql = N'ALTER ROLE ' + @quotedRole + N' ADD MEMBER ' + @quotedName;
    EXEC sp_executesql @sql;
    PRINT 'Added to ' + @roleName + ': ' + @groupName;
END
ELSE
BEGIN
    PRINT 'Already member of ' + @roleName + ': ' + @groupName;
END
"@

    $cmd = New-Object System.Data.SqlClient.SqlCommand($sql, $conn)
    $cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@pGroupName', $groupName))) | Out-Null
    $cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@pRoleName', $roleName))) | Out-Null
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
    roleName     = $roleName
    result       = 'SUCCESS'
}
