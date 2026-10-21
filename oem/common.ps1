# Shared helpers for the provisioning and maintenance scripts.
$OemDir = 'C:\OEM'
$RunnerDir = 'C:\runner'
$NtKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Read-Config {
    $cfg = @{}
    $path = Join-Path $OemDir 'config.env'
    if (Test-Path $path) {
        foreach ($line in Get-Content $path) {
            if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    $cfg
}

function Get-Setting($cfg, $name, $default = '') {
    if ($cfg[$name]) { $cfg[$name] } else { $default }
}

# Team toolset: installed by setup.ps1, upgraded by update.ps1. Value = forced installer type, for packages that
# also ship a per-user MSIX, which winget prefers even with --scope machine and the SYSTEM runner can't see.
$WingetPackages = [ordered]@{
    'Kitware.CMake' = ''; 'Git.Git' = ''; 'GitHub.GitLFS' = ''; 'OpenJS.NodeJS.LTS' = ''; '7zip.7zip' = ''
    'Microsoft.PowerShell' = 'wix'; 'Python.PythonInstallManager' = 'wix'
}

function Get-WingetArgs($id) {
    $a = @('--id', $id, '--exact', '--source', 'winget', '--scope', 'machine', '--silent', '--disable-interactivity',
        '--accept-package-agreements', '--accept-source-agreements')
    if ($WingetPackages[$id]) { $a += @('--installer-type', $WingetPackages[$id]) }
    $a
}

# The winget alias only exists in user profiles; SYSTEM has to call the App Installer package's exe directly.
function Get-WingetExe {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Directory.Name -split '_')[1] } -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Register-SystemTask($name, $triggers, $script, $settings = (New-ScheduledTaskSettingsSet -StartWhenAvailable)) {
    $action = if ($script -like '*.ps1') {
        New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $script"
    } else { New-ScheduledTaskAction -Execute $script -WorkingDirectory (Split-Path $script) }
    Register-ScheduledTask -TaskName $name -Force -Trigger $triggers -Action $action -Settings $settings `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) | Out-Null
}

# --- gitea-runner ---

# $spec is "latest", a version prefix ("5", "5.1") or an exact version ("5.1.1").
function Resolve-RunnerVersion($spec) {
    if ($spec -match '^\d+\.\d+\.\d+$') { return $spec }
    # Assigned first: piped directly, Invoke-RestMethod emits the JSON array as one object.
    $releases = Invoke-RestMethod 'https://gitea.com/api/v1/repos/gitea/runner/releases?limit=50'
    $best = $releases |
        Where-Object { -not $_.prerelease -and -not $_.draft } |
        ForEach-Object { $_.tag_name.TrimStart('v') } |
        Where-Object { $_ -match '^\d+\.\d+\.\d+$' -and ($spec -eq 'latest' -or $_ -like "$spec.*") } |
        Sort-Object { [version]$_ } -Descending | Select-Object -First 1
    if (-not $best) { throw "No gitea-runner release matches '$spec'" }
    $best
}

function Test-RunnerVersion($have, $spec) {
    $have -and ($spec -eq 'latest' -or $have -eq $spec -or $have -like "$spec.*")
}

function Get-RunnerVersion { Get-Content (Join-Path $RunnerDir 'version.txt') -ErrorAction SilentlyContinue }

function Install-Runner($version) {
    $tmp = Join-Path $RunnerDir 'gitea-runner.new.exe'
    Invoke-WebRequest -UseBasicParsing "https://gitea.com/gitea/runner/releases/download/v$version/gitea-runner-$version-windows-amd64.exe" -OutFile $tmp
    Move-Item -Force $tmp (Join-Path $RunnerDir 'gitea-runner.exe')
    Set-Content (Join-Path $RunnerDir 'version.txt') $version
}

# Host-mode jobs run as child processes of gitea-runner (node, pwsh, msbuild, ...).
function Test-RunnerBusy {
    $ids = @(Get-CimInstance Win32_Process -Filter "Name='gitea-runner.exe'" | ForEach-Object ProcessId)
    if (-not $ids) { return $false }
    [bool](Get-CimInstance Win32_Process | Where-Object { $ids -contains $_.ParentProcessId -and $_.Name -ne 'conhost.exe' })
}

# Requires several idle checks in a row: there's no child process between a job's steps.
function Wait-RunnerIdle([int]$maxMinutes) {
    $deadline = (Get-Date).AddMinutes($maxMinutes)
    $idle = 0
    while ($idle -lt 4) {
        if ((Get-Date) -gt $deadline) { return $false }
        if (Test-RunnerBusy) { $idle = 0 } else { $idle++ }
        Start-Sleep 30
    }
    $true
}

# Disabled first so the watchdog trigger doesn't relaunch it.
function Stop-Runner {
    Disable-ScheduledTask -TaskName 'gitea-runner' | Out-Null
    Stop-ScheduledTask -TaskName 'gitea-runner'
    Get-Process gitea-runner -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Start-Runner {
    Enable-ScheduledTask -TaskName 'gitea-runner' | Out-Null
    Start-ScheduledTask -TaskName 'gitea-runner'
}

# --- KMS ---

# Microsoft's published Windows Server KMS client setup keys (GVLKs), by OS build then edition.
$Gvlk = @{
    '20348' = @{ ServerStandard = 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H'; ServerDatacenter = 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33' }
    '26100' = @{ ServerStandard = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'; ServerDatacenter = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF' }
}

function Get-KmsKey($cfg, $edition) {
    $key = Get-Setting $cfg 'KMS_CLIENT_KEY'
    if ($key) { return $key }
    $build = (Get-ItemProperty $NtKey).CurrentBuildNumber
    if ($Gvlk.ContainsKey($build)) { $key = $Gvlk[$build][$edition] }
    if (-not $key) { throw "No GVLK known for build $build / $edition; set KMS_CLIENT_KEY" }
    $key
}
