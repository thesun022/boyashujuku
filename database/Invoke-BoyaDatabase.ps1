[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Inspect', 'Install', 'Test')]
    [string]$Action,
    [string]$ServerBin = 'E:\MySQL\sever\bin',
    [string]$LoginPath = 'boya_admin',
    [string]$PipeName,
    [switch]$SkipDemo
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$mysql = Join-Path $ServerBin 'mysql.exe'
$schema = 'boya_media_center'
$connection = if ($PipeName) {
    @('--no-defaults', '--protocol=PIPE', "--socket=$PipeName", '--user=root')
} else {
    $profileHeader = '^\[' + [regex]::Escape($LoginPath) + '\]$'
    $configEditor = Join-Path $ServerBin 'mysql_config_editor.exe'
    $profileExists = & $configEditor print "--login-path=$LoginPath" | Select-String -Pattern $profileHeader -Quiet
    if ($LASTEXITCODE -ne 0 -or !$profileExists) { throw "MySQL login path '$LoginPath' is missing." }
    @("--login-path=$LoginPath", '--protocol=TCP', '--connect-timeout=5')
}
$clientArgs = $connection + @('--default-character-set=utf8mb4', '--batch')

function Invoke-Query([string]$Sql) {
    & $mysql @clientArgs --skip-column-names "--execute=$Sql"
    if ($LASTEXITCODE -ne 0) { throw "MySQL query failed with exit code $LASTEXITCODE." }
}

function Import-Sql([string]$File, [switch]$WithoutSchema) {
    Write-Host "Importing $File"
    $importArgs = $clientArgs
    if (!$WithoutSchema) { $importArgs += "--database=$schema" }
    Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $PSScriptRoot $File) | & $mysql @importArgs
    if ($LASTEXITCODE -ne 0) { throw "Import of $File failed with exit code $LASTEXITCODE." }
}

$schemaCount = Invoke-Query "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$schema';"
switch ($Action) {
    'Inspect' {
        & $mysql @clientArgs --execute="
          SELECT VERSION() AS server_version, @@global.log_bin AS log_bin,
                 @@global.binlog_format AS binlog_format;
          SELECT SCHEMA_NAME FROM information_schema.schemata WHERE schema_name = '$schema';
          SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS FROM information_schema.tables
          WHERE table_schema = '$schema' ORDER BY TABLE_NAME;"
        if ($LASTEXITCODE -ne 0) { throw "Inspection failed with exit code $LASTEXITCODE." }
    }
    'Install' {
        if ($schemaCount -ne '0') { throw "Schema $schema already exists. Inspect it before planning a migration." }
        $version = Invoke-Query 'SELECT VERSION();'
        if ($version -notmatch '^(\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'8.0.16' -or $version -match 'MariaDB') {
            throw "Expected MySQL 8.0.16+, found $version."
        }
        $roleCount = Invoke-Query "SELECT COUNT(*) FROM mysql.user WHERE User = 'boya_media_center_runtime' AND Host = '%';"
        if ($roleCount -ne '0') { throw 'The MySQL runtime role name is already in use.' }
        if (!$SkipDemo -and (Invoke-Query "SELECT CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', '+08:00') >= '2026-10-27';") -ne '1') {
            throw 'The fictional fixtures require a server date on or after 2026-10-27. Use -SkipDemo for schema only.'
        }
        Import-Sql '01_create_database.sql' -WithoutSchema
        foreach ($file in @('02_create_tables.sql', '03_constraints_indexes.sql',
                            '05_create_views.sql', '06_create_triggers.sql',
                            '06b_create_procedures.sql', '06c_security_roles.sql', '04_reference_data.sql')) {
            Import-Sql $file
        }
        if (!$SkipDemo) { Import-Sql '04_initial_data.sql' }
    }
    'Test' {
        if ($schemaCount -ne '1') { throw "Schema $schema must be installed before test." }
        Import-Sql '07_test_database.sql'
    }
}
