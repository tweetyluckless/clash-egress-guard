$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$taskModeState=Join-Path ([IO.Path]::GetTempPath()) ('egress-guard-test-' + [Guid]::NewGuid().ToString('N'))
$taskInstallState=Join-Path $taskModeState 'install'
$taskLiveSnapshot=Join-Path $taskModeState 'live-firewall.json'
$taskGroup='ClashEgressGuard'
$taskRequiredRuleNames=@('ClashEgressGuard-Loopback','ClashEgressGuard-Tun','ClashEgressGuard-Upstream','ClashEgressGuard-BootstrapDNS-TCP','ClashEgressGuard-BootstrapDNS-UDP','ClashEgressGuard-DHCP')
New-Item -ItemType Directory -Path $taskInstallState -Force | Out-Null
@('original-A','original-B') | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskInstallState 'disabled-allow-rules.json')
$script:taskRules=@($taskRequiredRuleNames | ForEach-Object {[pscustomobject]@{Name=$_;Group=$taskGroup;Enabled='True';Direction='Outbound';Action='Allow'}})
$script:taskRules+=@('original-A','original-B','user-disabled') | ForEach-Object {[pscustomobject]@{Name=$_;Group='User';Enabled='False';Direction='Outbound';Action='Allow'}}
$script:taskProfiles=@('Domain','Private','Public') | ForEach-Object {[pscustomobject]@{Name=$_;Enabled='True';DefaultOutboundAction='Block'}}
function Get-NetFirewallRule {
    [CmdletBinding()]param($PolicyStore,$Direction,$Action,$Enabled)
    @($script:taskRules | Where-Object {(-not $Direction -or $_.Direction -eq $Direction) -and (-not $Action -or $_.Action -eq $Action) -and (-not $Enabled -or $_.Enabled -eq $Enabled)})
}
function Set-NetFirewallRule {
    [CmdletBinding()]param($InputObject,$Enabled)
    $InputObject.Enabled=[string]$Enabled
}
function Get-NetFirewallProfile {
    [CmdletBinding()]param($PolicyStore)
    $script:taskProfiles
}
function Set-NetFirewallProfile {
    [CmdletBinding()]param($PolicyStore,[switch]$All,$DefaultOutboundAction,$Enabled)
    foreach($taskProfile in $script:taskProfiles){if($DefaultOutboundAction){$taskProfile.DefaultOutboundAction=$DefaultOutboundAction};if($Enabled){$taskProfile.Enabled=$Enabled}}
}
$taskTokens=$null;$taskErrors=$null
$taskAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Modes.ps1'),[ref]$taskTokens,[ref]$taskErrors)
if($taskErrors.Count -gt 0){throw 'Mode script contains syntax errors.'}
$taskFunctionNames=@('Get-ManagedAllowRules','Get-GuardRules','Save-LiveRuleStates','Initialize-LiveRuleStates','Enable-LiveFirewall','Enable-ProtectedFirewall','Save-ProtectedProxy','Restore-ModeProxy')
foreach($taskFunctionName in $taskFunctionNames){
    $taskFunction=$taskAst.Find({param($taskNode) $taskNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $taskNode.Name -eq $taskFunctionName},$true)
    Invoke-Expression $taskFunction.Extent.Text
}
Initialize-LiveRuleStates
Enable-LiveFirewall
if(@($script:taskRules | Where-Object {$_.Group -eq $taskGroup -and $_.Enabled -ne 'False'}).Count -gt 0){throw 'Guard rules were not paused.'}
if(($script:taskRules | Where-Object Name -eq 'original-A').Enabled -ne 'True' -or ($script:taskRules | Where-Object Name -eq 'user-disabled').Enabled -ne 'False'){throw 'Original and manually disabled rules were not distinguished.'}
($script:taskRules | Where-Object Name -eq 'original-A').Enabled='False'
$script:taskRules+=[pscustomobject]@{Name='new-live-app';Group='User';Enabled='True';Direction='Outbound';Action='Allow'}
Save-LiveRuleStates
Enable-ProtectedFirewall
if(@($script:taskRules | Where-Object {$_.Group -ne $taskGroup -and $_.Enabled -ne 'False'}).Count -gt 0){throw 'Protection left a direct allow rule enabled.'}
if(@($script:taskProfiles | Where-Object DefaultOutboundAction -ne 'Block').Count -gt 0){throw 'Protection did not block default egress.'}
Enable-LiveFirewall
if(($script:taskRules | Where-Object Name -eq 'original-A').Enabled -ne 'False' -or ($script:taskRules | Where-Object Name -eq 'new-live-app').Enabled -ne 'True'){throw 'User changes made in live mode were not preserved.'}

# System proxy snapshot round trip. Registry access is mocked; the key below does not exist, so an
# unmocked cmdlet would fail instead of touching the real Internet Settings.
$taskProxyKey='HKCU:\Software\ClashEgressGuard-Test-DoesNotExist'
$taskProxySnapshot=Join-Path $taskModeState 'protected-proxy.json'
$script:taskRegistry=[ordered]@{ProxyEnable=1;ProxyServer='127.0.0.1:7890';ProxyOverride='<local>'}
function Get-ItemProperty {
    [CmdletBinding()]param($LiteralPath)
    if($LiteralPath -ne $taskProxyKey){throw 'Unexpected registry read.'}
    [pscustomobject]$script:taskRegistry
}
function Set-ItemProperty {
    [CmdletBinding()]param($LiteralPath,$Name,$Value,$Type)
    if($LiteralPath -ne $taskProxyKey -or $Name -isnot [string]){throw 'Unexpected registry write (one value name per call is required).'}
    $script:taskRegistry[$Name]=$Value
}
function Remove-ItemProperty {
    [CmdletBinding()]param($LiteralPath,$Name)
    if($LiteralPath -ne $taskProxyKey -or $Name -isnot [string]){throw 'Unexpected registry removal.'}
    $script:taskRegistry.Remove($Name)
}
function Refresh-ModeProxy {}
Save-ProtectedProxy
$script:taskRegistry=[ordered]@{ProxyEnable=0;AutoConfigURL='http://example.invalid/proxy.pac'}
Restore-ModeProxy
if($script:taskRegistry['ProxyEnable'] -ne 1 -or $script:taskRegistry['ProxyServer'] -ne '127.0.0.1:7890' -or $script:taskRegistry['ProxyOverride'] -ne '<local>' -or $script:taskRegistry.Contains('AutoConfigURL')){throw 'System proxy settings were not restored from the snapshot.'}

Remove-Item -LiteralPath $taskModeState -Recurse -Force
@{ruleStateTransitions='passed'; userChangesPreserved=$true; proxySnapshotRoundTrip='passed'; actualFirewallTouched=$false; actualRegistryTouched=$false} | ConvertTo-Json -Compress
