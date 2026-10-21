# Applies config.env to the runner and scheduled tasks; run.cmd calls it before every runner start.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Pull config.env and script fixes from the host share (oem/ on the host); keep the last copy if it's unreachable.
$share = '\\host.lan\Data'
for ($i = 0; $i -lt 12 -and -not (Test-Path "$share\config.env"); $i++) { Start-Sleep 5 }
if (Test-Path "$share\config.env") {
    $before = (Get-FileHash $PSCommandPath).Hash
    Copy-Item "$share\*" 'C:\OEM' -Force
    # This run started from the old copy; hand over to the new one so script changes apply on this start, not the next.
    if ((Get-FileHash $PSCommandPath).Hash -ne $before -and -not $env:CONFIGURE_RELAUNCHED) {
        $env:CONFIGURE_RELAUNCHED = '1'
        & $PSCommandPath
        return
    }
} else { Write-Warning "$share unreachable; using the existing C:\OEM\config.env" }

. "$PSScriptRoot\common.ps1"
Start-Transcript -Append (Join-Path $OemDir 'configure.log')
$cfg = Read-Config
New-Item -ItemType Directory -Force $RunnerDir | Out-Null
$exe = Join-Path $RunnerDir 'gitea-runner.exe'

# --- Binary: follow RUNNER_VERSION changes ("latest" is left to the update task) ---
$spec = Get-Setting $cfg 'RUNNER_VERSION' '5'
if (-not (Test-Path $exe) -or -not (Test-RunnerVersion (Get-RunnerVersion) $spec)) {
    $ver = Resolve-RunnerVersion $spec
    Write-Host "Installing gitea-runner $ver (was $(Get-RunnerVersion))"
    Install-Runner $ver
}

# --- config.yaml: rewritten every start; labels here win over the ones stored in .runner ---
$labels = (Get-Setting $cfg 'RUNNER_LABELS' 'windows-latest:host') -split ',' |
    ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { "    - `"$_`"" }
@"
log:
  level: info
runner:
  file: $RunnerDir\.runner
  capacity: $(Get-Setting $cfg 'RUNNER_CAPACITY' '1')
  timeout: 3h
  labels:
$($labels -join "`r`n")
cache:
  enabled: true
  dir: $RunnerDir\cache
host:
  workdir_parent: $RunnerDir\work
"@ | Set-Content -Encoding ASCII (Join-Path $RunnerDir 'config.yaml')

# --- Registration: kept as long as instance and name match; otherwise registered again ---
$instance = (Get-Setting $cfg 'GITEA_INSTANCE_URL').TrimEnd('/')
$name = Get-Setting $cfg 'RUNNER_NAME' $env:COMPUTERNAME
$regFile = Join-Path $RunnerDir '.runner'
$reg = if (Test-Path $regFile) { Get-Content $regFile -Raw | ConvertFrom-Json }
if (-not $reg -or $reg.address.TrimEnd('/') -ne $instance -or $reg.name -ne $name) {
    $token = Get-Setting $cfg 'GITEA_RUNNER_TOKEN'
    if (-not $token) {
        Write-Warning 'Runner needs (re)registration but GITEA_RUNNER_TOKEN is empty; keeping the current registration'
    } else {
        Write-Host "Registering '$name' with $instance (was '$($reg.name)' on $($reg.address))"
        if ($reg) { Move-Item -Force $regFile "$regFile.bak" }
        Push-Location $RunnerDir
        & $exe -c config.yaml register --no-interactive --instance $instance --token $token --name $name
        $ok = $LASTEXITCODE -eq 0
        Pop-Location
        if (-not $ok) {
            if ($reg) { Move-Item -Force "$regFile.bak" $regFile }
            throw "Runner registration failed; previous registration restored"
        }
    }
}

# --- Scheduled tasks that depend on config ---
$days = Get-Setting $cfg 'UPDATE_DAYS'
if ($days) {
    Register-SystemTask 'auto-update' `
        (New-ScheduledTaskTrigger -Weekly -DaysOfWeek ($days -split ',' | ForEach-Object Trim) -At (Get-Setting $cfg 'UPDATE_TIME' '03:00')) `
        "$OemDir\update.ps1" (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -StartWhenAvailable)
} else { Unregister-ScheduledTask -TaskName 'auto-update' -Confirm:$false -ErrorAction SilentlyContinue }

if (Get-Setting $cfg 'KMS_HOST') {
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT1M'
    Register-SystemTask 'kms-activate' $trigger "$OemDir\activate.ps1"
    # Also run now, so a KMS_HOST added after install applies without another reboot; it's a no-op once activated.
    Start-ScheduledTask -TaskName 'kms-activate'
} else { Unregister-ScheduledTask -TaskName 'kms-activate' -Confirm:$false -ErrorAction SilentlyContinue }

# --- Locale: time zone directly; the keyboard is per user, so a logon task applies it in each user's session ---
$tz = Get-Setting $cfg 'LOCALE_TIMEZONE'
if ($tz -and (Get-TimeZone).Id -ne $tz) { Set-TimeZone -Id $tz; Write-Host "Time zone -> $tz" }
if (Get-Setting $cfg 'LOCALE_KEYBOARD') {
    Register-ScheduledTask -TaskName 'keyboard-layout' -Force -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
        -Principal (New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest) `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $OemDir\keyboard.ps1") | Out-Null
    # Applies right away to users already signed in.
    Start-ScheduledTask -TaskName 'keyboard-layout'
} else { Unregister-ScheduledTask -TaskName 'keyboard-layout' -Confirm:$false -ErrorAction SilentlyContinue }

& "$OemDir\tune.ps1"

Write-Host 'Configuration applied'
