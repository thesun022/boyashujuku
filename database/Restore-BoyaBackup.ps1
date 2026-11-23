[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupDirectory,
    [string]$RestoreAssetRoot,
    [string]$ServerBin = 'E:\MySQL\sever\bin',
    [string]$LoginPath = 'boya_restore',
    [string]$PipeName
)

$ErrorActionPreference = 'Stop'
$mysql = Join-Path $ServerBin 'mysql.exe'
$connection = if ($PipeName) {
    @('--no-defaults', '--protocol=PIPE', "--socket=$PipeName", '--user=root')
} else {
    $profileHeader = '^\[' + [regex]::Escape($LoginPath) + '\]$'
    $configEditor = Join-Path $ServerBin 'mysql_config_editor.exe'
    $profileExists = & $configEditor print "--login-path=$LoginPath" | Select-String -Pattern $profileHeader -Quiet
    if ($LASTEXITCODE -ne 0 -or !$profileExists) { throw "MySQL login path '$LoginPath' is missing." }
    @("--login-path=$LoginPath", '--protocol=TCP', '--connect-timeout=5')
}
$manifest = Get-Content -Raw -LiteralPath (Join-Path $BackupDirectory 'manifest.json') | ConvertFrom-Json
$sql = Get-Item -LiteralPath (Join-Path $BackupDirectory 'boya_media_center.sql')
if ($manifest.Database -ne 'boya_media_center' -or
    (Get-FileHash -LiteralPath $sql.FullName -Algorithm SHA256).Hash -ne $manifest.DatabaseSHA256) {
    throw 'The database backup failed manifest validation.'
}

$assetCopies = @()
if ($RestoreAssetRoot) {
    if (!$manifest.AssetsIncluded) { throw 'This backup has no file archive.' }
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RestoreAssetRoot)
    if (Test-Path -LiteralPath $target) { throw 'RestoreAssetRoot must be a new directory.' }
    $archive = (Get-Item -LiteralPath (Join-Path $BackupDirectory 'assets')).FullName
    $assetCopies = @(foreach ($entry in $manifest.Files) {
        if ([System.IO.Path]::IsPathRooted($entry.Path) -or $entry.Path -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Invalid relative asset path: $($entry.Path)"
        }
        $source = Get-Item -LiteralPath (Join-Path $archive $entry.Path)
        if ($source.Length -ne $entry.Bytes -or
            (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash -ne $entry.SHA256) {
            throw "Asset failed manifest validation: $($entry.Path)"
        }
        @{ Source = $source.FullName; Destination = (Join-Path $target $entry.Path); Hash = $entry.SHA256 }
    })
}

$exists = & $mysql @connection --batch --skip-column-names --execute="
  SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='boya_media_center';"
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the restore instance.' }
if ($exists -ne '0') { throw 'Destination already contains boya_media_center.' }
& $mysql @connection --execute='CREATE DATABASE boya_media_center CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;'
if ($LASTEXITCODE -ne 0) { throw 'Could not create the restore schema.' }

# Stream the original bytes without PowerShell line or encoding conversion.
$start = [System.Diagnostics.ProcessStartInfo]::new($mysql)
$start.UseShellExecute = $false
$start.RedirectStandardInput = $true
foreach ($arg in $connection + @('--default-character-set=utf8mb4', '--binary-mode=1', '--database=boya_media_center')) {
    $start.ArgumentList.Add($arg)
}
$proc = [System.Diagnostics.Process]::Start($start)
$stream = [System.IO.File]::OpenRead($sql.FullName)
try {
    $stream.CopyTo($proc.StandardInput.BaseStream)
} finally {
    $stream.Dispose()
    $proc.StandardInput.Close()
}
$proc.WaitForExit()
$exitCode = $proc.ExitCode
$proc.Dispose()
if ($exitCode -ne 0) { throw "MySQL restore failed with exit code $exitCode." }

if ($RestoreAssetRoot) {
    [void](New-Item -ItemType Directory -Path $target)
    foreach ($copy in $assetCopies) {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($copy.Destination))
        [System.IO.File]::Copy($copy.Source, $copy.Destination, $false)
        if ((Get-FileHash -LiteralPath $copy.Destination -Algorithm SHA256).Hash -ne $copy.Hash) {
            throw "Restored asset failed hash verification: $($copy.Destination)"
        }
    }
}
Write-Output "Restored boya_media_center; verified $($assetCopies.Count) file(s)."
