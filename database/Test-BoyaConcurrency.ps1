[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PipeName,
    [string]$ServerBin = 'E:\MySQL\sever\bin'
)

$ErrorActionPreference = 'Stop'
$mysql = Join-Path $ServerBin 'mysql.exe'
$clientArgs = @('--no-defaults', '--protocol=PIPE', "--socket=$PipeName", '--user=root',
                '--database=boya_media_center', '--batch', '--skip-column-names',
                "--init-command=SET SESSION time_zone = '+08:00'")

function Start-Sql([string]$Sql) {
    $start = [System.Diagnostics.ProcessStartInfo]::new($mysql)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in $clientArgs + @("--execute=$Sql")) { $start.ArgumentList.Add($arg) }
    $process = [System.Diagnostics.Process]::Start($start)
    @{
        Process = $process
        Output = $process.StandardOutput.ReadToEndAsync()
        Errors = $process.StandardError.ReadToEndAsync()
        Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Complete-Sql($Ticket) {
    if (!$Ticket.Process.WaitForExit(20000)) {
        $Ticket.Process.Kill()
        throw 'Timed out waiting for test client.'
    }
    $elapsed = $Ticket.Stopwatch.ElapsedMilliseconds
    $result = @{
        ExitCode = $Ticket.Process.ExitCode
        Output = $Ticket.Output.GetAwaiter().GetResult().Trim()
        Errors = $Ticket.Errors.GetAwaiter().GetResult().Trim()
        ElapsedMs = $elapsed
    }
    $Ticket.Process.Dispose()
    $result
}

function Invoke-Sql([string]$Sql) {
    $result = Complete-Sql (Start-Sql $Sql)
    if ($result.ExitCode -ne 0) { throw $result.Errors }
    $result.Output
}

function Assert-Contention([string]$First, [string]$Second, [string]$Marker, [string]$ExpectedError) {
    $firstTicket = Start-Sql "$First SELECT GET_LOCK('$Marker',0); DO SLEEP(4); COMMIT;"
    $ready = $false
    for ($attempt = 0; $attempt -lt 30 -and !$firstTicket.Process.HasExited; $attempt++) {
        if ((Invoke-Sql "SELECT IS_USED_LOCK('$Marker') IS NOT NULL;") -eq '1') {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if (!$ready) {
        $firstResult = Complete-Sql $firstTicket
        throw "First transaction did not acquire its locks. $($firstResult.Errors)"
    }
    $secondResult = Complete-Sql (Start-Sql $Second)
    $firstResult = Complete-Sql $firstTicket
    if ($firstResult.ExitCode -ne 0) { throw $firstResult.Errors }
    if ($secondResult.ExitCode -eq 0 -or !$secondResult.Errors.Contains($ExpectedError) -or
        $secondResult.ElapsedMs -lt 500) {
        throw "Second connection did not wait and return the expected error. $($secondResult.Errors)"
    }
    Write-Output "PASS $ExpectedError (second session waited $($secondResult.ElapsedMs) ms)"
}

$token = [guid]::NewGuid().ToString('N').Substring(0, 12)
$fixture = Invoke-Sql @"
CALL sp_create_campaign(1,'CONC-$token','Concurrency verification',CURRENT_TIMESTAMP,NULL,FALSE);
SET @c=(SELECT id FROM campaign WHERE code='CONC-$token');
CALL sp_create_project(1,@c,'A','Concurrency task A','PHOTO','WORK_ONLY',FALSE);
CALL sp_create_project(1,@c,'B','Concurrency task B','PHOTO','WORK_ONLY',FALSE);
SET @p1=(SELECT id FROM project WHERE campaign_id=@c AND code='A');
SET @p2=(SELECT id FROM project WHERE campaign_id=@c AND code='B');
CALL sp_create_work(1,@p1,'PHOTO','Camera work A','PHOTO',NULL,TRUE);
CALL sp_create_work(1,@p2,'PHOTO','Camera work B','PHOTO',NULL,TRUE);
INSERT INTO equipment(code,name,model,source) VALUES ('CONC-$token','Concurrency camera','QA','OWNED');
SELECT @p1, (SELECT id FROM work_item WHERE project_id=@p1),
       (SELECT id FROM work_item WHERE project_id=@p2), LAST_INSERT_ID();
"@
$projectA, $workA, $workB, $camera = $fixture -split "`t"
$expected = Invoke-Sql "SELECT lock_version FROM work_item WHERE id=$workA;"
$expectedB = Invoke-Sql "SELECT lock_version FROM work_item WHERE id=$workA;"
if ($expected -ne '0' -or $expectedB -ne '0') { throw 'Both clients must initially see version 0.' }
Assert-Contention `
    "START TRANSACTION; SELECT id FROM project WHERE id=$projectA FOR UPDATE;
     UPDATE work_item SET status='IN_PROGRESS', lock_version=lock_version+1, changed_by=1
     WHERE id=$workA AND lock_version=$expected;" `
    "CALL sp_set_work_status(1,$workA,$expectedB,'BLOCKED');" `
    "boya_work_$token" 'Work version conflict'
$workResult = Invoke-Sql "SELECT CONCAT(status,':',lock_version) FROM work_item WHERE id=$workA;"
if ($workResult -ne 'IN_PROGRESS:1') { throw "First work update was not preserved. $workResult" }

Assert-Contention `
    "START TRANSACTION; INSERT INTO equipment_usage(equipment_id,work_item_id,membership_id,reserved_by,starts_at,ends_at)
     VALUES ($camera,$workA,7,1,CURRENT_DATE+INTERVAL 1 DAY,CURRENT_DATE+INTERVAL 2 DAY);" `
    "CALL sp_reserve_camera(1,$camera,$workB,8,CURRENT_DATE+INTERVAL 1 DAY,CURRENT_DATE+INTERVAL 2 DAY);" `
    "boya_camera_$token" 'Camera reservation overlaps'
$cameraResult = Invoke-Sql "SELECT CONCAT(COUNT(*),':',MIN(work_item_id)) FROM equipment_usage WHERE equipment_id=$camera;"
if ($cameraResult -ne "1:${workA}") { throw "Expected only the first reservation. $cameraResult" }
Write-Output "PASS durable work state $workResult and exactly one camera reservation for work item $workA"
