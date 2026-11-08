param([ValidateSet('Install','Restore','Live','Protect')][string]$Mode = 'Install')
$ErrorActionPreference = 'Stop'
$taskSettings = & (Join-Path $PSScriptRoot 'Settings.ps1')
$taskScript = Join-Path $PSScriptRoot ($Mode + '.ps1')
$taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $taskScript + '"'
$taskStatusName = 'status.json'
if ($Mode -in @('Live','Protect')) {
    $taskScript = Join-Path $PSScriptRoot 'Modes.ps1'
    $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $taskScript + '" -Mode ' + $Mode
    $taskStatusName = 'mode-status.json'
}
try {
    Write-Host ('[' + $Mode + '] Starting. Click Yes on the Windows administrator prompt.') -ForegroundColor Cyan
    $taskPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $taskPowerShell = "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" }
    $taskStatusPath = Join-Path $taskSettings.state $taskStatusName
    $taskStartedAt = [DateTime]::UtcNow
    # No -Wait: it also waits for every process the script starts, including the
    # Clash GUI, which keeps running, so the window would hang with no output.
    $taskProcess = Start-Process -FilePath $taskPowerShell -Verb RunAs -WindowStyle Hidden -ArgumentList $taskArguments -PassThru
    $taskProcess.Handle | Out-Null # Keeps ExitCode readable after the process exits.
    Write-Host ('[' + $Mode + '] Working. Keep this window open; this can take a minute or two.')
    # Do not read the status file until the script exits. Set-Content in the elevated
    # script fails while another process has the file open, which would fail the run.
    while (-not $taskProcess.WaitForExit(15000)) {
        Write-Host ('[' + $Mode + '] Still working...')
    }
    $taskReport = Get-Item -LiteralPath $taskStatusPath -ErrorAction SilentlyContinue
    if (-not $taskReport -or $taskReport.LastWriteTimeUtc -lt $taskStartedAt) {
        throw ('The script exited without writing a new status report to ' + $taskStatusPath)
    }
    Get-Content -LiteralPath $taskStatusPath -Raw | Write-Host
    if ($taskProcess.ExitCode -ne 0) { throw ('The operation did not complete. See the status output above, or ' + $taskStatusPath) }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
