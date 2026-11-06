$ErrorActionPreference='Stop'
$taskShell=New-Object -ComObject WScript.Shell
$taskDesktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
foreach($taskItem in @(@{Name='Egress Guard - Live';File='live.cmd'},@{Name='Egress Guard - Protect';File='protect.cmd'})){
    $taskDestination=Join-Path $taskDesktop ($taskItem.Name+'.lnk')
    if(Test-Path -LiteralPath $taskDestination){throw "A shortcut already exists: $($taskItem.Name)"}
    $taskLink=$taskShell.CreateShortcut($taskDestination)
    $taskLink.TargetPath=Join-Path $PSScriptRoot $taskItem.File
    $taskLink.WorkingDirectory=$PSScriptRoot
    $taskLink.Description='Switch network mode. A Windows administrator prompt is required.'
    $taskLink.Save()
}
