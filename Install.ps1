$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$taskSettings = & (Join-Path $PSScriptRoot 'Settings.ps1')
$taskState = $taskSettings.state
$taskReport = Join-Path $taskState 'status.json'
$taskManifest = Get-Content -LiteralPath (Join-Path $taskState 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$taskIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($taskIdentity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator privileges are required. No settings were changed.'
}
if ($taskManifest.preparedBy -ne $taskIdentity.Name) { throw 'Elevate as the same user who prepared this installation.' }
$taskNode = $taskSettings.node
$taskHelper = Join-Path $PSScriptRoot 'guard.cjs'
$taskGroup = 'ClashEgressGuard'
$taskFirewallChanged = $false
$taskRestoring = $false
$taskDiagnostics = @{}
$taskStep = 'preflight'
$taskRestorationVerified = $false
$taskFirewallBackup = Join-Path $taskState ('firewall-before-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '.wfw')

function Set-TaskStatus($taskPhase, $taskDetails) {
    @{ phase = $taskPhase; revision = '0.1.0'; time = [DateTime]::UtcNow.ToString('o'); details = $taskDetails } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $taskReport -Encoding UTF8
}
function Invoke-TaskHelper([string]$taskOperation) {
    $taskOutput = & $taskNode $taskHelper $taskOperation 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Network helper failed ($taskOperation): $($taskOutput -join ' ')" }
    return ($taskOutput -join "`n" | ConvertFrom-Json)
}
function Resolve-TaskCorePath([int]$taskCoreId) {
    if (-not ('ClashEgressGuardProcessImage' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class ClashEgressGuardProcessImage {
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref uint size);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    public static string Get(int processId) {
        IntPtr handle = OpenProcess(0x1000, false, processId);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            uint size = 32768;
            var buffer = new StringBuilder((int)size);
            if (!QueryFullProcessImageNameW(handle, 0, buffer, ref size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return buffer.ToString();
        } finally { CloseHandle(handle); }
    }
}
'@
    }
    $taskActualPath = [ClashEgressGuardProcessImage]::Get($taskCoreId)
    if ($taskActualPath.StartsWith('\\?\')) { $taskActualPath = $taskActualPath.Substring(4) }
    $taskActualPath = [IO.Path]::GetFullPath($taskActualPath)
    $taskReferencePath = [IO.Path]::GetFullPath($taskManifest.core)
    $taskServiceRoot = [IO.Path]::GetFullPath($taskManifest.trustedServiceCoreRoot).TrimEnd('\') + '\'
    $script:taskDiagnostics = @{ coreProcessId=$taskCoreId; runtimeCore=$taskActualPath; referenceCore=$taskReferencePath }
    if ([IO.Path]::GetFileName($taskActualPath) -ne 'verge-mihomo.exe' -or
        ($taskActualPath -ne $taskReferencePath -and -not $taskActualPath.StartsWith($taskServiceRoot,[StringComparison]::OrdinalIgnoreCase))) {
        throw 'The running core is outside the installed app and the official service core directory.'
    }
    $taskActualHash = (Get-FileHash -LiteralPath $taskActualPath -Algorithm SHA256).Hash
    $taskReferenceHash = (Get-FileHash -LiteralPath $taskReferencePath -Algorithm SHA256).Hash
    $script:taskDiagnostics.runtimeSha256 = $taskActualHash
    $script:taskDiagnostics.referenceSha256 = $taskReferenceHash
    if ($taskActualHash -ne $taskManifest.coreSha256 -or $taskReferenceHash -ne $taskManifest.coreSha256) {
        throw 'The running core binary does not match the reviewed installed binary; no firewall exceptions were added.'
    }
    return $taskActualPath
}
function Wait-TaskTun {
    for ($taskAttempt = 0; $taskAttempt -lt 60; $taskAttempt++) {
        Start-Sleep -Seconds 1
        $taskAdapterNow = Get-NetAdapter -Name $taskManifest.device -ErrorAction SilentlyContinue
        if ($taskAdapterNow -and $taskAdapterNow.Status -eq 'Up') { return }
    }
    throw 'The existing Clash service did not recover its TUN adapter within 60 seconds.'
}
function Restore-TaskChanges {
    $script:taskRestoring = $true
    if ($script:taskFirewallChanged) {
        & "$env:SystemRoot\System32\netsh.exe" advfirewall import $taskFirewallBackup | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Firewall restoration failed. Run restore.cmd to recover the previous firewall snapshot.' }
        $taskRestoredProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
        foreach ($taskOriginalProfile in $taskProfiles) {
            $taskRestoredProfile = @($taskRestoredProfiles | Where-Object { $_.Name -eq $taskOriginalProfile.Name })
            if ($taskRestoredProfile.Count -ne 1 -or $taskRestoredProfile[0].Enabled -ne $taskOriginalProfile.Enabled -or $taskRestoredProfile[0].DefaultOutboundAction -ne $taskOriginalProfile.DefaultOutboundAction) {
                throw 'Firewall profile restoration could not be verified. Run Restore.cmd.'
            }
        }
        if (@(Get-NetFirewallRule -PolicyStore PersistentStore -Group $taskGroup -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Temporary ClashEgressGuard rules remain after restoration.' }
        $script:taskRestorationVerified = $true
    }
}

try {
    Set-TaskStatus 'preflight' @{}
    if (@(Get-NetFirewallRule -PolicyStore PersistentStore -Group $taskGroup -ErrorAction SilentlyContinue).Count -gt 0) { throw 'ClashEgressGuard rules already exist; inspect or restore the previous installation before retrying.' }
    try { $taskPolicy = Invoke-TaskHelper 'policy-check' } catch {
        & (Join-Path $PSScriptRoot 'ApplyPolicy.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Prepared policy activation failed.' }
        $taskPolicy = Invoke-TaskHelper 'policy-check'
    }
    $taskServiceProcesses = @(Get-Process -Name 'clash-verge-service' -ErrorAction SilentlyContinue)
    $taskServices = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -eq $taskSettings.serviceName -and $_.State -eq 'Running' })
    if ($taskServices.Count -ne 1) { throw 'A single running Clash service is required before installing the kill switch.' }
    $taskServiceName = $taskServices[0].Name
    $taskCoreProcess = @(Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue)
    if ($taskCoreProcess.Count -ne 1) { throw 'A single running Mihomo process is required.' }
    $taskRuntimeCorePath = Resolve-TaskCorePath $taskCoreProcess[0].Id
    Set-TaskStatus 'core-verified' $taskDiagnostics
    if ((Get-Service -Name MpsSvc).Status -ne 'Running') { throw 'Windows Firewall service is not running.' }
    $taskProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    foreach ($taskProfile in $taskProfiles) {
        if ($taskProfile.AllowLocalFirewallRules -eq 'False') { throw 'A managed policy disallows local firewall rules.' }
        if (@($taskProfile.DisabledInterfaceAliases | Where-Object { $_ -and $_ -ne 'NotConfigured' }).Count -gt 0) { throw 'Some interfaces bypass Windows Firewall; review them before enabling protection.' }
    }
    $taskActiveAllows = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Outbound -Action Allow -Enabled True)
    if (@($taskActiveAllows | Where-Object { $_.PolicyStoreSourceType -eq 'GroupPolicy' }).Count -gt 0) { throw 'Managed outbound allow rules prevent a reliable local kill switch.' }
    $taskLocalAllows = @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound -Action Allow -Enabled True)
    $taskLocalNames = @($taskLocalAllows.Name)
    if (@($taskActiveAllows | Where-Object { $_.Name -notin $taskLocalNames }).Count -gt 0) { throw 'Non-local outbound allow rules require manual review; no settings were changed.' }
    $taskBaseline = Invoke-TaskHelper 'proxy-check'
    & "$env:SystemRoot\System32\netsh.exe" advfirewall export $taskFirewallBackup | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not back up Windows Firewall.' }
    @{file=(Split-Path -Leaf $taskFirewallBackup)} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskState 'last-firewall-backup.json') -Encoding UTF8
    ConvertTo-Json -InputObject @($taskLocalNames) | Set-Content -LiteralPath (Join-Path $taskState 'disabled-allow-rules.json') -Encoding UTF8
    Set-TaskStatus 'checking-active-tun' @{ baseline = $taskBaseline; policy = $taskPolicy }
    $taskAdapter = Get-NetAdapter -Name $taskManifest.device
    if ($taskAdapter.Status -ne 'Up') { throw 'ClashEgressGuard TUN adapter is not up.' }
    $taskTunCheck = Invoke-TaskHelper 'direct-check'
    Set-TaskStatus 'validating-disabled-firewall-rules' @{ tunCheck = $taskTunCheck }
    $taskFirewallChanged = $true
    $taskBase = @{Group=$taskGroup; Direction='Outbound'; Action='Allow'; Enabled='False'; Profile='Any'; PolicyStore='PersistentStore'}
    $taskRuleSpecs = @(
        @{Name='ClashEgressGuard-Loopback'; DisplayName='ClashEgressGuard: local IPv4 proxy'; RemoteAddress=@('127.0.0.1')},
        @{Name='ClashEgressGuard-Tun'; DisplayName='ClashEgressGuard: TUN egress'; InterfaceAlias=$taskManifest.device},
        @{Name='ClashEgressGuard-Upstream'; DisplayName='ClashEgressGuard: pinned VPN upstream'; Program=$taskRuntimeCorePath; RemoteAddress=$taskManifest.upstreamAddresses; Protocol='TCP'; RemotePort=$taskManifest.upstreamPort}
    )
    foreach ($taskProtocol in @('TCP','UDP')) {
        $taskRuleSpecs += @{Name="ClashEgressGuard-BootstrapDNS-$taskProtocol"; DisplayName="ClashEgressGuard: core bootstrap DNS $taskProtocol"; Program=$taskRuntimeCorePath; RemoteAddress=@($taskSettings.bootstrapDns); Protocol=$taskProtocol; RemotePort=53}
    }
    $taskRuleSpecs += @{Name='ClashEgressGuard-DHCP'; DisplayName='ClashEgressGuard: DHCP lease'; Program="$env:SystemRoot\System32\svchost.exe"; Service='Dhcp'; Protocol='UDP'; LocalPort=68; RemotePort=67; RemoteAddress='Any'}
    $taskCreationErrors = [System.Collections.Generic.List[string]]::new()
    $taskStep = 'validate-disabled-rule-definitions'
    foreach ($taskRuleSpec in $taskRuleSpecs) {
        try { New-NetFirewallRule @taskBase @taskRuleSpec | Out-Null }
        catch { $taskCreationErrors.Add($taskRuleSpec.Name + ': ' + $_.Exception.Message) }
    }
    if ($taskCreationErrors.Count -gt 0) { throw ('Firewall rule validation failed: ' + ($taskCreationErrors -join ' | ')) }
    $taskStep = 'activate-validated-rules'
    foreach ($taskRuleSpec in $taskRuleSpecs) { Enable-NetFirewallRule -Name $taskRuleSpec.Name -PolicyStore PersistentStore | Out-Null }
    foreach ($taskRule in $taskLocalAllows) { Set-NetFirewallRule -PolicyStore PersistentStore -Name $taskRule.Name -Enabled False | Out-Null }
    $taskStep = 'apply-outbound-block-default'
    Set-NetFirewallProfile -PolicyStore PersistentStore -All -Enabled True -DefaultOutboundAction Block
    if (@(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { $_.Enabled -ne 'True' -or $_.DefaultOutboundAction -ne 'Block' }).Count -gt 0) { throw 'Effective firewall defaults are not blocking outbound traffic.' }
    if (@(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Outbound -Action Allow -Enabled True | Where-Object { $_.Group -ne $taskGroup }).Count -gt 0) { throw 'An unexpected outbound allow rule remains active.' }
    $taskStep = 'verify-protected-egress'
    $taskOnline = Invoke-TaskHelper 'direct-check'
    Set-TaskStatus 'testing-kill-switch' @{ online = $taskOnline }
    try {
        $taskStep = 'verify-service-stop-blocks-direct-egress'
        Stop-Service -Name $taskServiceName -Force
        Start-Sleep -Seconds 2
        $taskStoppedAdapter = Get-NetAdapter -Name $taskManifest.device -ErrorAction SilentlyContinue
        if ($taskStoppedAdapter -and $taskStoppedAdapter.Status -eq 'Up') { throw 'TUN remained up after stopping the service; the stop test cannot be verified.' }
        $taskBlocked = Invoke-TaskHelper 'blocked-check'
    } finally {
        Start-Service -Name $taskServiceName
        Wait-TaskTun
    }
    $taskStep = 'verify-service-recovery'
    $taskRecovered = Invoke-TaskHelper 'direct-check'
    Set-TaskStatus 'complete' @{ online=$taskOnline; directConnectionBlocked=$taskBlocked; recovered=$taskRecovered; device=$taskManifest.device; service=$taskServiceName; runtimeCore=$taskRuntimeCorePath; startup='Use Clash settings to configure login startup'; udp='blocked'; note='Only core bootstrap DNS and DHCP are allowed outside the pinned upstream.' }
} catch {
    $taskFailure = $_.Exception.Message
    try {
        if (-not $taskRestoring) { Restore-TaskChanges }
        Set-TaskStatus 'firewall-not-installed' @{ error=$taskFailure; failedStep=$taskStep; firewallRestored=$taskRestorationVerified; diagnostics=$taskDiagnostics; tun='The active ClashEgressGuard TUN configuration is retained.' }
    } catch {
        Set-TaskStatus 'restoration-required' @{ error=$taskFailure; restoreError=$_.Exception.Message }
    }
    exit 1
}
