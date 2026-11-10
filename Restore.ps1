$ErrorActionPreference = 'Stop'
$taskIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($taskIdentity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Restore.cmd and accept the administrator prompt.' }
$taskSettings = & (Join-Path $PSScriptRoot 'Settings.ps1')
$taskState = $taskSettings.state
$taskManifest = Get-Content -LiteralPath (Join-Path $taskState 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$taskFirewallBackup = Join-Path $taskState 'firewall-before.wfw'
$taskBackupIndex = Join-Path $taskState 'last-firewall-backup.json'
if (Test-Path -LiteralPath $taskBackupIndex) {
    $taskBackupName = (Get-Content -LiteralPath $taskBackupIndex -Raw | ConvertFrom-Json).file
    if ($taskBackupName -notmatch '^firewall-before-\d{8}-\d{6}-\d{7}\.wfw$') { throw 'Invalid firewall backup name.' }
    $taskFirewallBackup = Join-Path $taskState $taskBackupName
    if (-not (Test-Path -LiteralPath $taskFirewallBackup)) { throw 'The indexed firewall backup is missing.' }
}
if (Test-Path -LiteralPath $taskFirewallBackup) {
    & "$env:SystemRoot\System32\netsh.exe" advfirewall import $taskFirewallBackup | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Firewall restore failed.' }
}
$taskServiceProcesses = @(Get-Process -Name 'clash-verge-service' -ErrorAction SilentlyContinue)
$taskServices = @(Get-CimInstance Win32_Service | Where-Object { $_.ProcessId -in @($taskServiceProcesses.Id) -and $_.State -eq 'Running' })
foreach ($taskService in $taskServices) { Stop-Service -Name $taskService.Name -Force }
foreach ($taskProcess in @(Get-Process -Name 'clash-verge','verge-mihomo' -ErrorAction SilentlyContinue)) {
    if ($taskProcess.Path -eq ($taskManifest.app -replace '/', '\') -or $taskProcess.Path -eq ($taskManifest.core -replace '/', '\')) { Stop-Process -Id $taskProcess.Id -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 2
foreach ($taskRelative in $taskManifest.files) { Copy-Item -LiteralPath (Join-Path (Join-Path $taskState 'backup') $taskRelative) -Destination (Join-Path $taskManifest.root $taskRelative) -Force }
foreach ($taskService in $taskServices) { Start-Service -Name $taskService.Name }
Start-Process -FilePath $taskManifest.app -WindowStyle Hidden
@{ phase='restored'; time=[DateTime]::UtcNow.ToString('o'); details=@{} } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskState 'status.json') -Encoding UTF8
