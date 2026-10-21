# Trims the VM for unattended builds: unneeded services, Azure Arc Setup, Defender scanning of build tools, power plan, auto-logon.
# Idempotent; configure.ps1 runs it at every runner start.

function Set-StartMode($names, [int]$start) {
    foreach ($n in $names) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$n"
        if (-not (Test-Path $key)) { continue }
        if ((Get-ItemProperty $key).Start -ge $start) { continue }
        # Registry first (Set-Service is denied for some protected services), SCM if the key's ACL refuses even admins.
        try { Set-ItemProperty $key -Name Start -Value $start -ErrorAction Stop }
        catch { sc.exe config $n start= $(if ($start -eq 4) { 'disabled' } else { 'demand' }) | Out-Null }
        if ((Get-ItemProperty $key).Start -eq $start) { Write-Host "service $n -> $(@{3='Manual';4='Disabled'}[$start])" }
        else { Write-Warning "service ${n}: couldn't change start mode" }
        if ($start -eq 4) { Stop-Service $n -Force -ErrorAction SilentlyContinue }
    }
}

# Disabled: printing, telemetry, prefetching, search indexing, maps, location, AI fabric, compatibility appraisal.
Set-StartMode @('Spooler', 'DiagTrack', 'SysMain', 'WSearch', 'MapsBroker', 'lfsvc', 'WSAIFabricSvc', 'InventorySvc') 4
# Manual (trigger-started if something needs them): audio, autoplay, text input, IPv6 transition, SMB server, CDP, diagnostics.
Set-StartMode @('Audiosrv', 'AudioEndpointBuilder', 'ShellHWDetection', 'TextInputManagementService', 'TabletInputService',
    'iphlpsvc', 'LanmanServer', 'CDPSvc', 'DPS', 'WerSvc', 'PcaSvc') 3

# Defender: files opened by build tools aren't scanned, scans are throttled, no scheduled full scan.
try {
    Add-MpPreference -ExclusionProcess 'cl.exe', 'link.exe', 'lib.exe', 'MSBuild.exe', 'VBCSCompiler.exe', 'mspdbsrv.exe',
        'rc.exe', 'midl.exe', 'cvtres.exe', 'git.exe', 'git-lfs.exe', 'node.exe', 'nuget.exe', 'gitea-runner.exe'
    Add-MpPreference -ExclusionPath $RunnerDir, "$env:ProgramFiles\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Windows Kits"
    Set-MpPreference -ScanAvgCPULoadFactor 20 -ScanScheduleDay 8
} catch { Write-Warning "Defender tuning failed: $_" }

# Azure Arc Setup (Server 2025 tray icon and onboarding wizard) and Server Manager at logon aren't wanted here.
# Newer builds ship it as a removable feature; early 26100 builds only start the tray app from the Run key.
try {
    if ((Get-WindowsFeature AzureArcSetup).Installed) { Uninstall-WindowsFeature AzureArcSetup | Out-Null; Write-Host 'Azure Arc Setup removed' }
} catch { Write-Warning "Azure Arc Setup removal failed: $_" }
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name AzureArcSetup -ErrorAction SilentlyContinue
Stop-Process -Name AzureArcSysTray -Force -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null

# High performance power plan.
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

# No auto-logon: the runner runs as SYSTEM, so a desktop session only costs RAM. Log in via the web console when needed.
# dockur's answer file sets a huge AutoLogonCount, which keeps logging in even with AutoAdminLogon=0.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $winlogon -Name AutoAdminLogon -Value '0'
Remove-ItemProperty $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
