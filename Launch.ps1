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
    $taskPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $taskPowerShell = "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" }
    $taskProcess = Start-Process -FilePath $taskPowerShell -Verb RunAs -WindowStyle Hidden -ArgumentList $taskArguments -Wait -PassThru
    $taskStatusPath = Join-Path $taskSettings.state $taskStatusName
    if (Test-Path -LiteralPath $taskStatusPath) { Get-Content -LiteralPath $taskStatusPath -Raw | Write-Host }
    if ($taskProcess.ExitCode -ne 0) { throw ('The operation did not complete. See the status output above, or ' + $taskStatusPath) }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
