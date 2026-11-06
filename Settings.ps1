$ErrorActionPreference='Stop'
$taskNodeCommand=Get-Command node.exe -ErrorAction Stop
$taskSettingsOutput=& $taskNodeCommand.Source (Join-Path $PSScriptRoot 'guard.cjs') settings
if($LASTEXITCODE -ne 0){throw 'Cannot load config.local.json; see the setup instructions.'}
$taskSettings=$taskSettingsOutput -join "`n" | ConvertFrom-Json
$taskSettings | Add-Member -NotePropertyName node -NotePropertyValue $taskNodeCommand.Source -Force
return $taskSettings
