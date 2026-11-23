[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupDirectory,
    [string]$AssetRoot,
    [string]$ServerBin = 'E:\MySQL\sever\bin',
    [string]$LoginPath = 'boya_admin',
    [string]$PipeName
)

$ErrorActionPreference = 'Stop'
$mysql = Join-Path $ServerBin 'mysql.exe'
$mysqldump = Join-Path $ServerBin 'mysqldump.exe'
$connection = if ($PipeName) {
    @('--no-defaults', '--protocol=PIPE', "--socket=$PipeName", '--user=root')
} else {
    $profileHeader = '^\[' + [regex]::Escape($LoginPath) + '\]$'
    $configEditor = Join-Path $ServerBin 'mysql_config_editor.exe'
    $profileExists = & $configEditor print "--login-path=$LoginPath" | Select-String -Pattern $profileHeader -Quiet
    if ($LASTEXITCODE -ne 0 -or !$profileExists) { throw "MySQL login path '$LoginPath' is missing." }
    @("--login-path=$LoginPath", '--protocol=TCP')
}
$logBin = & $mysql @connection --connect-timeout=5 --batch --skip-column-names --execute='SELECT @@global.log_bin;'
if ($LASTEXITCODE -ne 0 -or $logBin -notin @('0','1')) { throw 'Could not read server binlog status.' }

if ($AssetRoot) {
    $assetDirectory = (Get-Item -LiteralPath $AssetRoot).FullName
    if (!(Test-Path -LiteralPath $assetDirectory -PathType Container)) { throw 'AssetRoot must be a directory.' }
}
$resolvedBackup = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupDirectory)
if ($assetDirectory -and [System.IO.Path]::GetRelativePath($assetDirectory, $resolvedBackup) -notmatch '^\.\.(\\|/|$)' -and
    [System.IO.Path]::GetPathRoot($assetDirectory) -eq [System.IO.Path]::GetPathRoot($resolvedBackup)) {
    throw 'BackupDirectory must be outside AssetRoot.'
}
$target = (New-Item -ItemType Directory -Path $resolvedBackup).FullName
$sqlPath = Join-Path $target 'boya_media_center.sql'
$dumpArgs = @('--default-character-set=utf8mb4', '--single-transaction', '--quick',
              '--routines', '--triggers', '--events', '--no-tablespaces',
              '--set-gtid-purged=OFF', '--skip-add-drop-table', "--result-file=$sqlPath")
if ($logBin -eq '1') {
    $supportsSourceData = & $mysqldump --no-defaults --help | Select-String -SimpleMatch '--source-data' -Quiet
    if ($supportsSourceData) { $dumpArgs += '--source-data=2' } else { $dumpArgs += '--master-data=2' }
}
& $mysqldump @connection @dumpArgs boya_media_center
if ($LASTEXITCODE -ne 0) { throw "mysqldump failed. The incomplete backup is at $target." }

$files = @()
if ($assetDirectory) {
    $assetTarget = (New-Item -ItemType Directory -Path (Join-Path $target 'assets')).FullName
    $files = @(foreach ($file in (Get-ChildItem -LiteralPath $assetDirectory -Recurse -File -Force)) {
        if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Back up the referent through its managed storage provider. Reparse point: $($file.FullName)"
        }
        $relative = [System.IO.Path]::GetRelativePath($assetDirectory, $file.FullName)
        $copy = Join-Path $assetTarget $relative
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($copy))
        [System.IO.File]::Copy($file.FullName, $copy, $false)
        $hash = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
        if ($hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
            throw "Asset changed during backup: $relative"
        }
        [ordered]@{ Path = $relative; SHA256 = $hash; Bytes = (Get-Item -LiteralPath $copy).Length }
    })
}

$coordinate = if ($logBin -eq '1') {
    $line = Select-String -LiteralPath $sqlPath -Pattern '^-- CHANGE (REPLICATION SOURCE TO|MASTER TO)' |
        Select-Object -First 1 -ExpandProperty Line
    if ($line -notmatch "(?:SOURCE|MASTER)_LOG_FILE='([^']+)',\s*(?:SOURCE|MASTER)_LOG_POS=(\d+)") {
        throw 'The dump did not contain recognizable binlog coordinates.'
    }
    [ordered]@{ File = $Matches[1]; Position = [long]$Matches[2] }
} else { $null }

[ordered]@{
    Database = 'boya_media_center'
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    DatabaseSHA256 = (Get-FileHash -LiteralPath $sqlPath -Algorithm SHA256).Hash
    BinlogEnabled = ($logBin -eq '1')
    BinlogCoordinate = $coordinate
    AssetsIncluded = [bool]$assetDirectory
    Files = @($files)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $target 'manifest.json') -Encoding utf8
Write-Output $target
