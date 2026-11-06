$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$taskSettings=& (Join-Path $PSScriptRoot 'Settings.ps1')
$taskManifest=Get-Content -LiteralPath (Join-Path $taskSettings.state 'manifest.json') -Raw | ConvertFrom-Json
$taskIdentity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($taskIdentity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)-or $taskManifest.preparedBy -ne $taskIdentity.Name){throw 'Elevate as the user who prepared this installation.'}
$taskChanged=$false
function Stop-PreparedNetwork {
    foreach($taskProcess in @(Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)){
        if($taskProcess.Path -ne [IO.Path]::GetFullPath($taskManifest.app)){throw 'An unexpected Clash application is running.'}
        Stop-Process -Id $taskProcess.Id -Force
    }
    if((Get-Service -Name $taskSettings.serviceName).Status -ne 'Stopped'){Stop-Service -Name $taskSettings.serviceName -Force}
    Start-Sleep -Seconds 2
}
function Start-PreparedNetwork {
    if((Get-Service -Name $taskSettings.serviceName).Status -ne 'Running'){Start-Service -Name $taskSettings.serviceName}
    Start-Process -FilePath $taskManifest.app -WindowStyle Hidden
}
try{
    foreach($taskRelative in $taskManifest.files){
        if($taskRelative -notin @('profiles/Script.js','config.yaml','verge.yaml','clash-verge.yaml')){throw 'Unexpected file in the preparation manifest.'}
        if((Get-FileHash -LiteralPath (Join-Path $taskManifest.root $taskRelative) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskManifest.hashes.$taskRelative){throw 'Clash configuration changed after preparation. Create a fresh plan before applying it.'}
    }
    & $taskManifest.core -t -d $taskManifest.root -f (Join-Path $taskSettings.state 'staged/clash-verge.yaml') | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Mihomo rejected the staged configuration.'}
    Stop-PreparedNetwork
    $taskChanged=$true
    foreach($taskRelative in $taskManifest.files){Copy-Item -LiteralPath (Join-Path (Join-Path $taskSettings.state 'staged') $taskRelative) -Destination (Join-Path $taskManifest.root $taskRelative) -Force}
    Start-PreparedNetwork
    $taskReady=$false
    for($taskAttempt=0;$taskAttempt -lt 60;$taskAttempt++){
        $taskAdapter=Get-NetAdapter -Name $taskManifest.device -ErrorAction SilentlyContinue
        if($taskAdapter -and $taskAdapter.Status -eq 'Up'){$taskReady=$true;break}
        Start-Sleep -Seconds 1
    }
    if(-not $taskReady){throw 'The prepared TUN adapter did not start.'}
    & $taskSettings.node (Join-Path $PSScriptRoot 'guard.cjs') policy-check | Out-Null
    if($LASTEXITCODE -ne 0){throw 'The application overrode the prepared policy. Inspect TUN, IPv6 and DNS settings in Clash.'}
    & $taskSettings.node (Join-Path $PSScriptRoot 'guard.cjs') direct-check | Out-Null
    if($LASTEXITCODE -ne 0){throw 'The prepared TUN did not produce the configured egress.'}
}catch{
    $taskFailure=$_.Exception.Message
    if($taskChanged){
        Stop-PreparedNetwork
        foreach($taskRelative in $taskManifest.files){Copy-Item -LiteralPath (Join-Path (Join-Path $taskSettings.state 'backup') $taskRelative) -Destination (Join-Path $taskManifest.root $taskRelative) -Force}
        Start-PreparedNetwork
    }
    Write-Error $taskFailure
    exit 1
}
