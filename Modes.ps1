param([Parameter(Mandatory=$true)][ValidateSet('Live','Protect')][string]$Mode)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$taskIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($taskIdentity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Use the mode launcher and accept the administrator prompt.' }
$taskSettings = & (Join-Path $PSScriptRoot 'Settings.ps1')
$taskInstallState = $taskSettings.state
$taskModeState = $taskSettings.modeState
$taskManifest = Get-Content -LiteralPath (Join-Path $taskInstallState 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$taskRoot = $taskManifest.root
if ($taskManifest.preparedBy -ne $taskIdentity.Name) { throw 'Elevate as the same user who prepared this installation.' }
$taskHelper = Join-Path $PSScriptRoot 'guard.cjs'
$taskNode = $taskSettings.node
$taskReport = Join-Path $taskInstallState 'mode-status.json'
$taskGroup = 'ClashEgressGuard'
$taskServiceName = $taskSettings.serviceName
$taskLiveSnapshot = Join-Path $taskModeState 'live-firewall.json'
$taskProxySnapshot = Join-Path $taskModeState 'protected-proxy.json'
$taskModeMarker = Join-Path $taskModeState 'current-mode.json'
$taskProxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$taskChanged = $false
$taskLock = $null
$taskRequiredRuleNames = @('ClashEgressGuard-Loopback','ClashEgressGuard-Tun','ClashEgressGuard-Upstream','ClashEgressGuard-BootstrapDNS-TCP','ClashEgressGuard-BootstrapDNS-UDP','ClashEgressGuard-DHCP')
New-Item -ItemType Directory -Path $taskModeState -Force | Out-Null

function Write-ModeStatus([string]$taskPhase, $taskDetails) {
    @{phase=$taskPhase; mode=$Mode; revision='0.1.0'; time=[DateTime]::UtcNow.ToString('o'); details=$taskDetails} |
        ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $taskReport -Encoding UTF8
}
function Set-ModeMarker([string]$taskValue){
    @{mode=$taskValue; time=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $taskModeMarker -Encoding UTF8
}
function Invoke-ModeHelper([string]$taskOperation, [string]$taskArgument='') {
    $taskHelperArgs=@($taskHelper,$taskOperation)
    if($taskArgument){$taskHelperArgs+=$taskArgument}
    $taskOutput=& $taskNode @taskHelperArgs 2>&1
    if($LASTEXITCODE -ne 0){throw "Network check failed ($taskOperation): $($taskOutput -join ' ')"}
    return ($taskOutput -join "`n" | ConvertFrom-Json)
}
function Get-ManagedAllowRules {
    return @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound -Action Allow)
}
function Get-GuardRules {
    $taskGuards=@(Get-ManagedAllowRules | Where-Object {$_.Group -eq $taskGroup})
    if($taskGuards.Count -ne $taskRequiredRuleNames.Count -or @($taskGuards | Where-Object {$_.Name -notin $taskRequiredRuleNames}).Count -gt 0){throw 'The installed ClashEgressGuard rules are incomplete or changed. Inspect the installation before switching.'}
    return $taskGuards
}
function Save-LiveRuleStates {
    $taskStates=@(Get-ManagedAllowRules | Where-Object {$_.Group -ne $taskGroup} | ForEach-Object {@{name=$_.Name; enabled=($_.Enabled -eq 'True')}})
    @{rules=$taskStates; time=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $taskLiveSnapshot -Encoding UTF8
}
function Initialize-LiveRuleStates {
    if(Test-Path -LiteralPath $taskLiveSnapshot){return}
    $taskOriginallyEnabled=Get-Content -LiteralPath (Join-Path $taskInstallState 'disabled-allow-rules.json') -Raw | ConvertFrom-Json
    $taskOriginallyEnabled=@($taskOriginallyEnabled)
    $taskStates=@(Get-ManagedAllowRules | Where-Object {$_.Group -ne $taskGroup} | ForEach-Object {@{name=$_.Name; enabled=(($_.Name -in $taskOriginallyEnabled) -or $_.Enabled -eq 'True')}})
    @{rules=$taskStates; time=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $taskLiveSnapshot -Encoding UTF8
}
function Enable-LiveFirewall {
    $taskSaved=Get-Content -LiteralPath $taskLiveSnapshot -Raw | ConvertFrom-Json
    $taskDesired=@{}
    foreach($taskRuleState in $taskSaved.rules){$taskDesired[$taskRuleState.name]=[bool]$taskRuleState.enabled}
    foreach($taskRule in Get-ManagedAllowRules){
        if($taskRule.Group -eq $taskGroup){if($taskRule.Enabled -ne 'False'){Set-NetFirewallRule -InputObject $taskRule -Enabled False | Out-Null}}
        elseif($taskDesired.ContainsKey($taskRule.Name)){
            $taskEnabled=if($taskDesired[$taskRule.Name]){'True'}else{'False'}
            if($taskRule.Enabled -ne $taskEnabled){Set-NetFirewallRule -InputObject $taskRule -Enabled $taskEnabled | Out-Null}
        }
    }
    Set-NetFirewallProfile -PolicyStore PersistentStore -All -DefaultOutboundAction Allow
    if(@(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object {$_.DefaultOutboundAction -ne 'Allow'}).Count -gt 0){throw 'Effective firewall policy did not switch to local direct access.'}
}
function Enable-ProtectedFirewall {
    foreach($taskRule in Get-ManagedAllowRules){
        $taskEnabled=if($taskRule.Group -eq $taskGroup){'True'}else{'False'}
        if($taskRule.Enabled -ne $taskEnabled){Set-NetFirewallRule -InputObject $taskRule -Enabled $taskEnabled | Out-Null}
    }
    Set-NetFirewallProfile -PolicyStore PersistentStore -All -Enabled True -DefaultOutboundAction Block
    if(@(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object {$_.Enabled -ne 'True' -or $_.DefaultOutboundAction -ne 'Block'}).Count -gt 0){throw 'Effective firewall defaults did not restore protection.'}
    if(@(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Outbound -Action Allow -Enabled True | Where-Object {$_.Group -ne $taskGroup}).Count -gt 0){throw 'An external outbound allow rule prevents complete protection.'}
}
function Stop-ModeNetwork {
    foreach($taskAppProcess in @(Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)){
        if($taskAppProcess.Path -ne ($taskManifest.app -replace '/', '\')){throw 'An unexpected Clash application path is running.'}
        Stop-Process -Id $taskAppProcess.Id -Force
    }
    $taskService=Get-Service -Name $taskServiceName
    if($taskService.Status -ne 'Stopped'){Stop-Service -Name $taskServiceName -Force}
    for($taskAttempt=0;$taskAttempt -lt 10;$taskAttempt++){
        $taskAdapter=Get-NetAdapter -Name $taskManifest.device -ErrorAction SilentlyContinue
        if(-not $taskAdapter -or $taskAdapter.Status -ne 'Up'){return}
        Start-Sleep -Seconds 1
    }
    throw 'The TUN adapter did not stop; local direct mode was not enabled.'
}
function Wait-ModeTun {
    for($taskAttempt=0;$taskAttempt -lt 60;$taskAttempt++){
        $taskAdapter=Get-NetAdapter -Name $taskManifest.device -ErrorAction SilentlyContinue
        if($taskAdapter -and $taskAdapter.Status -eq 'Up'){return}
        Start-Sleep -Seconds 1
    }
    throw 'The protected TUN did not start within 60 seconds. Direct access remains blocked; use Live mode if needed.'
}
function Start-ModeNetwork {
    $taskService=Get-Service -Name $taskServiceName
    if($taskService.Status -ne 'Running'){Start-Service -Name $taskServiceName}
    Start-Process -FilePath $taskManifest.app -WindowStyle Hidden
    Wait-ModeTun
}
function Save-ProtectedProxy {
    $taskCurrent=Get-ItemProperty -LiteralPath $taskProxyKey
    $taskItems=@(foreach($taskName in @('ProxyEnable','ProxyServer','ProxyOverride','AutoConfigURL')){
        $taskProperty=$taskCurrent.PSObject.Properties[$taskName]
        @{name=$taskName; exists=($null -ne $taskProperty); value=if($taskProperty){$taskProperty.Value}else{$null}}
    })
    ConvertTo-Json -InputObject @($taskItems) -Depth 4 | Set-Content -LiteralPath $taskProxySnapshot -Encoding UTF8
}
function Refresh-ModeProxy {
    if(-not ('ClashEgressGuardWinInet' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClashEgressGuardWinInet {
    [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", ExactSpelling=true, SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int size);
}
'@
    }
    [ClashEgressGuardWinInet]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0) | Out-Null
    [ClashEgressGuardWinInet]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0) | Out-Null
}
function Disable-ModeProxy {
    Set-ItemProperty -LiteralPath $taskProxyKey -Name ProxyEnable -Type DWord -Value 0
    Remove-ItemProperty -LiteralPath $taskProxyKey -Name AutoConfigURL -ErrorAction SilentlyContinue
    Refresh-ModeProxy
}
function Restore-ModeProxy {
    if(-not (Test-Path -LiteralPath $taskProxySnapshot)){return}
    $taskSavedProxy=Get-Content -LiteralPath $taskProxySnapshot -Raw | ConvertFrom-Json
    foreach($taskItem in @($taskSavedProxy)){
        if($taskItem.exists){
            $taskType=if($taskItem.name -eq 'ProxyEnable'){'DWord'}else{'String'}
            Set-ItemProperty -LiteralPath $taskProxyKey -Name $taskItem.name -Value $taskItem.value -Type $taskType
        }else{Remove-ItemProperty -LiteralPath $taskProxyKey -Name $taskItem.name -ErrorAction SilentlyContinue}
    }
    Refresh-ModeProxy
}

try{
    $taskLock=[IO.File]::Open((Join-Path $taskModeState 'mode.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    Get-GuardRules | Out-Null
    $taskPreviousMode='Protect'
    if(Test-Path -LiteralPath $taskModeMarker){$taskPreviousMode=(Get-Content -LiteralPath $taskModeMarker -Raw | ConvertFrom-Json).mode}
    if($Mode -eq 'Live'){
        $taskCloseFirst=@($taskSettings.appsToCloseBeforeLive | Where-Object {$_})
        $taskStillRunning=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.ProcessName -in $taskCloseFirst})
        if($taskStillRunning.Count -gt 0){throw ('Close these applications before enabling Live mode, because Live mode uses your direct connection: ' + ((@($taskStillRunning.ProcessName) | Sort-Object -Unique) -join ', '))}
        Initialize-LiveRuleStates
        if($taskPreviousMode -ne 'Live'){Save-ProtectedProxy}
        Write-ModeStatus 'switching' @{action='Stopping Clash before enabling local direct access.'}
        $taskChanged=$true
        Stop-ModeNetwork
        Invoke-ModeHelper 'configure-mode' 'Live' | Out-Null
        Disable-ModeProxy
        Enable-LiveFirewall
        $taskFileSettings=Invoke-ModeHelper 'mode-file-check'
        if($taskFileSettings.tunConfigured -or $taskFileSettings.vergeTun -ne 'false' -or $taskFileSettings.vergeProxy -ne 'false'){throw 'The persisted live configuration could not be verified.'}
        $taskEgress=$null
        $taskNetworkNote=$null
        try{$taskEgress=Invoke-ModeHelper 'egress-check'}catch{$taskNetworkNote=$_.Exception.Message}
        Set-ModeMarker 'Live'
        Write-ModeStatus 'complete' @{effectiveMode='Live'; vpn='stopped'; directAccess=$true; egress=$taskEgress; networkCheckNote=$taskNetworkNote; note='Traffic now uses the direct connection. Keep apps listed in appsToCloseBeforeLive closed until Protect mode is restored.'}
    }else{
        $taskProfiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore)
        $taskNonGuardEnabled=@(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound -Action Allow -Enabled True | Where-Object {$_.Group -ne $taskGroup})
        if(@($taskProfiles | Where-Object {$_.DefaultOutboundAction -ne 'Block'}).Count -gt 0 -or $taskNonGuardEnabled.Count -gt 0){Save-LiveRuleStates}
        Write-ModeStatus 'switching' @{action='Restoring fail-closed protection before starting the protected TUN.'}
        $taskChanged=$true
        Enable-ProtectedFirewall
        Stop-ModeNetwork
        Invoke-ModeHelper 'configure-mode' 'Protect' | Out-Null
        Restore-ModeProxy
        Start-ModeNetwork
        $taskPolicy=Invoke-ModeHelper 'policy-check'
        $taskOnline=Invoke-ModeHelper 'direct-check'
        try{
            Stop-Service -Name $taskServiceName -Force
            Start-Sleep -Seconds 2
            $taskStopped=Get-NetAdapter -Name $taskManifest.device -ErrorAction SilentlyContinue
            if($taskStopped -and $taskStopped.Status -eq 'Up'){throw 'The TUN remained active; the disconnect test cannot be verified.'}
            $taskBlocked=Invoke-ModeHelper 'blocked-check'
        }finally{
            Start-Service -Name $taskServiceName
            Wait-ModeTun
        }
        $taskRecovered=Invoke-ModeHelper 'direct-check'
        Set-ModeMarker 'Protect'
        Write-ModeStatus 'complete' @{effectiveMode='Protect'; policy=$taskPolicy; online=$taskOnline; blocked=$taskBlocked; recovered=$taskRecovered}
    }
}catch{
    $taskFailure=$_.Exception.Message
    $taskRecovery=$null
    if($taskChanged){
        try{
            Enable-ProtectedFirewall
            Stop-ModeNetwork
            Invoke-ModeHelper 'configure-mode' 'Protect' | Out-Null
            Restore-ModeProxy
            Start-ModeNetwork
            Invoke-ModeHelper 'direct-check' | Out-Null
            Set-ModeMarker 'Protect'
            $taskRecovery='Protection was restored.'
        }catch{$taskRecovery='Direct access is blocked where possible. Run Restore.cmd if network recovery is needed. '+$_.Exception.Message}
    }
    Write-ModeStatus 'failed' @{error=$taskFailure; recovery=$taskRecovery; settingsChanged=$taskChanged}
    exit 1
}finally{
    if($taskLock){$taskLock.Dispose()}
}
