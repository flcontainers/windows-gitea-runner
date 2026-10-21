# First-boot provisioning: winget, VS2022 and tools, and the gitea-runner task (config is applied by configure.ps1).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\common.ps1"
Start-Transcript -Append (Join-Path $OemDir 'setup.log')

New-Item -ItemType Directory -Force $RunnerDir | Out-Null

function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
}

function Install-WingetPackage($id, [string[]]$extra = @()) {
    Write-Host "winget install $id"
    winget install --id $id --exact --source winget --silent --disable-interactivity `
        --accept-package-agreements --accept-source-agreements @extra
    # Non-zero also covers "already installed"/"reboot required"; callers verify what they need.
    if ($LASTEXITCODE -ne 0) { Write-Warning "winget $id exited with $LASTEXITCODE" }
    Update-Path
}

# --- System ---
New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force | Out-Null
try { Add-MpPreference -ExclusionPath $RunnerDir } catch { Write-Warning "Defender exclusion failed: $_" }
# dockur's host share (\\host.lan\Data) is guest-only Samba; Server 2025 blocks guest logons and requires signing.
Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -RequireSecuritySignature $false -Force

# --- winget (not guaranteed on Server; the Store isn't supported there) ---
# Server 2025 ships App Installer, but at first logon its per-user registration may not have happened yet.
function Wait-Winget([int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while (-not (Get-Command winget -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep 5; Update-Path }
    [bool](Get-Command winget -ErrorAction SilentlyContinue)
}
Update-Path
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
    if (-not (Wait-Winget 300)) {
        # Not fatal by itself: -Latest can pick an older build than the in-box one, which Add-AppxPackage rejects.
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
            Set-PSRepository PSGallery -InstallationPolicy Trusted
            Install-Module Microsoft.WinGet.Client -Scope AllUsers -Force
            Repair-WinGetPackageManager -AllUsers -Latest -Force
        } catch { Write-Warning "Repair-WinGetPackageManager failed: $_" }
        if (-not (Wait-Winget 60)) { throw 'winget is not available' }
    }
}
winget --version

# --- Team toolset, same as the reference build host (machine scope so the SYSTEM runner sees them) ---
foreach ($id in $WingetPackages.Keys) {
    Write-Host "winget install $id"
    winget install @(Get-WingetArgs $id)
    if ($LASTEXITCODE -ne 0) { Write-Warning "winget $id exited with $LASTEXITCODE" }
}
Update-Path
git config --system core.longpaths true
git config --system --add safe.directory '*'
git lfs install --system

# --- VS2022 Community from the team vsconfig ---
Install-WingetPackage 'Microsoft.VisualStudio.2022.Community' @('--override',
    "--quiet --wait --norestart --nocache --config `"$OemDir\vs2022.vsconfig`"")
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = if (Test-Path $vswhere) { & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' }
if (-not $msbuild) { throw 'VS2022 install failed: MSBuild not found (see %TEMP%\dd_*.log)' }
Write-Host "MSBuild: $msbuild"

# Machine PATH entries the reference build host has: MSBuild and VS's bundled CMake.
$vsPath = & $vswhere -latest -products * -property installationPath
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
foreach ($dir in "$vsPath\MSBuild\Current\Bin", "$vsPath\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin") {
    if (($machinePath -split ';') -notcontains $dir) { $machinePath = $machinePath.TrimEnd(';') + ";$dir"; Write-Host "PATH += $dir" }
}
[Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
Update-Path

# --- gitea-runner: binary, config, registration and config-driven tasks are handled by configure.ps1 ---
# Restart loop: Task Scheduler's restart-on-failure doesn't fire when the process exits later.
# ping is the delay because timeout.exe fails without an interactive console.
@"
@echo off
cd /d $RunnerDir
powershell -NoProfile -ExecutionPolicy Bypass -File $OemDir\configure.ps1
:loop
gitea-runner.exe -c config.yaml daemon >> runner.log 2>&1
echo %date% %time% gitea-runner exited with %errorlevel%, restarting in 10s >> runner.log
ping -n 11 127.0.0.1 > nul
goto loop
"@ -replace "`r?`n", "`r`n" | Set-Content -Encoding ASCII (Join-Path $RunnerDir 'run.cmd')

# The 5-minute trigger is a watchdog: it's ignored while the task is running, relaunches it otherwise.
Register-SystemTask 'gitea-runner' @((New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5))) `
    "$RunnerDir\run.cmd" (New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)

Write-Host 'Setup complete, rebooting'
Restart-Computer -Force
