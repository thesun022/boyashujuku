[CmdletBinding()]
param([string]$ServerBin = 'E:\MySQL\sever\bin')

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$mysql = Join-Path $ServerBin 'mysql.exe'
$mysqlAdmin = Join-Path $ServerBin 'mysqladmin.exe'
$mysqlServer = Join-Path $ServerBin 'mysqld.exe'
$pipe = 'BoyaQuality' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$lab = (New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) $pipe)).FullName
$data = Join-Path $lab 'data'
$errorLog = Join-Path $lab 'server.err'
$transport = @('--no-defaults', '--protocol=PIPE', "--socket=$pipe", '--user=root')
$clientArgs = $transport + @('--database=boya_media_center', '--default-character-set=utf8mb4',
                            '--batch', '--skip-column-names')

function Test-SqlFile([string]$File, [string]$LogName) {
    $results = @(Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $PSScriptRoot $File) | & $mysql @clientArgs)
    $nativeExit = $LASTEXITCODE
    $results | Set-Content -Encoding utf8 -LiteralPath (Join-Path $lab $LogName)
    if ($nativeExit -ne 0) { throw "$File failed with MySQL exit code $nativeExit." }
    $failures = @($results | Where-Object { $_ -match '^FAIL\t' })
    if ($failures) { throw "$File failed:`n$($failures -join "`n")" }
    @($results | Where-Object { $_ -match '^PASS\t' }).Count
}

Write-Output "Quality test artifacts: $lab"
& $mysqlServer --no-defaults --initialize-insecure "--datadir=$data" "--log-error=$errorLog"
if ($LASTEXITCODE -ne 0) { throw "MySQL initialization failed. See $errorLog." }
$serverArgs = @('--no-defaults', '--skip-networking', '--named-pipe', "--socket=$pipe",
                "--datadir=`"$data`"", "--log-error=`"$errorLog`"",
                '--innodb-buffer-pool-size=64M', '--skip-log-bin')
$server = Start-Process -FilePath $mysqlServer -ArgumentList $serverArgs -WindowStyle Hidden -PassThru
try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 40 -and !$server.HasExited; $attempt++) {
        & $mysqlAdmin @transport ping 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (!$ready) { throw "The disposable MySQL server did not start. See $errorLog." }
    $install = Join-Path $PSScriptRoot 'Invoke-BoyaDatabase.ps1'
    & $install -Action Install -PipeName $pipe -ServerBin $ServerBin 6>&1 |
        Tee-Object -FilePath (Join-Path $lab 'install.log')
    $baseline = @(& $install -Action Test -PipeName $pipe -ServerBin $ServerBin 6>&1 |
        Tee-Object -FilePath (Join-Path $lab 'baseline.log') | Where-Object { "$_" -like 'PASS *' })
    if ($baseline.Count -ne 52) { throw "Expected 52 baseline assertions, found $($baseline.Count)." }
    Write-Output "PASS $($baseline.Count) baseline assertions"
    $objects = Test-SqlFile '09_schema_contract_tests.sql' 'schema-objects.tsv'
    if ($objects -ne 379) { throw "Expected 379 schema checks, found $objects." }
    Write-Output "PASS $objects schema object checks"
    $business = Test-SqlFile '10_quality_regressions.sql' 'quality-regressions.tsv'
    if ($business -ne 55) { throw "Expected 55 additional checks, found $business." }
    Write-Output "PASS $business additional SQL checks"
    & (Join-Path $PSScriptRoot 'Test-BoyaConcurrency.ps1') -PipeName $pipe -ServerBin $ServerBin |
        Tee-Object -FilePath (Join-Path $lab 'concurrency.log')
} finally {
    if (!$server.HasExited) {
        & $mysqlAdmin @transport shutdown
        if ($LASTEXITCODE -ne 0) { throw "Could not shut down the disposable instance $pipe." }
        Write-Output "Stopped disposable instance $pipe"
    }
    $server.Dispose()
}
