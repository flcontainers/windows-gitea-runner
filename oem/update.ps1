# Scheduled maintenance: waits for the runner to go idle, then updates gitea-runner, VS2022 and the winget toolset.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\common.ps1"
Start-Transcript -Append (Join-Path $OemDir 'update.log')

$cfg = Read-Config
if (-not (Wait-RunnerIdle ([int](Get-Setting $cfg 'UPDATE_MAX_WAIT_MIN' '240')))) {
    Write-Warning 'Runner stayed busy; skipping this update window'; return
}

Write-Host 'Runner idle; stopping it'
Stop-Runner
$reboot = $false
try {
    $want = Resolve-RunnerVersion (Get-Setting $cfg 'RUNNER_VERSION' '5')
    $have = Get-RunnerVersion
    if ($want -ne $have) { Write-Host "gitea-runner $have -> $want"; Install-Runner $want }
    else { Write-Host "gitea-runner $have is current" }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -format json | ConvertFrom-Json | Select-Object -First 1
    if ($vs) {
        # The bootstrapper must match the installed edition (Community/Professional/Enterprise).
        $edition = $vs.productId.Split('.')[-1].ToLower()
        $boot = Join-Path $env:TEMP "vs_$edition.exe"
        Invoke-WebRequest -UseBasicParsing "https://aka.ms/vs/17/release/vs_$edition.exe" -OutFile $boot
        Write-Host "Updating VS2022 $edition $($vs.installationVersion)"
        $p = Start-Process $boot -ArgumentList "update --installPath `"$($vs.installationPath)`" --quiet --wait --norestart" -Wait -PassThru
        switch ($p.ExitCode) {
            0 { }
            3010 { $reboot = $true }
            default { Write-Warning "VS update exited with $($p.ExitCode) (see %TEMP%\dd_*.log)" }
        }
        $vs = & $vswhere -latest -products * -format json | ConvertFrom-Json | Select-Object -First 1
        Write-Host "VS2022 now $($vs.installationVersion)"
    }

    $winget = Get-WingetExe
    if (-not $winget) { Write-Warning 'winget not found; skipping package upgrades' }
    else {
        foreach ($id in $WingetPackages.Keys) {
            & $winget upgrade @(Get-WingetArgs $id) | Out-Null
            $result = switch ($LASTEXITCODE) {
                0 { 'upgraded' }
                -1978335189 { 'up to date' }    # 0x8A15002B: no applicable upgrade
                -1978335212 { 'not installed' } # 0x8A150014: no installed package found
                3010 { $reboot = $true; 'upgraded, reboot required' }
                default { "failed ($LASTEXITCODE)" }
            }
            Write-Host "winget $id`: $result"
        }
    }
} finally {
    if ($reboot) {
        Enable-ScheduledTask -TaskName 'gitea-runner' | Out-Null
        Write-Host 'Rebooting to finish the VS update'; Restart-Computer -Force
    } else { Start-Runner }
}
