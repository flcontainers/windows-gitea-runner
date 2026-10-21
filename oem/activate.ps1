# Converts an evaluation edition if needed, then activates against the configured KMS host; no-op once licensed.
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\common.ps1"
Start-Transcript -Append (Join-Path $OemDir 'activate.log')

# An edition conversion disables the runner and DISM reboots without returning here; re-enable it at the next boot.
if ((Get-ScheduledTask -TaskName 'gitea-runner').State -eq 'Disabled') { Write-Host 'Re-enabling gitea-runner'; Start-Runner }

$cfg = Read-Config
$kmsHost = Get-Setting $cfg 'KMS_HOST'
$kmsPort = [int](Get-Setting $cfg 'KMS_PORT' '1688')
$edition = (Get-ItemProperty $NtKey).EditionID
if (-not $kmsHost) { Write-Host 'KMS_HOST not set; nothing to do'; return }

# Evaluation editions can't take a KMS key, and KMS_EDITION may ask for another edition (e.g. Standard -> Datacenter).
# Convert in place; DISM reboots, so let any running job finish first.
$target = Get-Setting $cfg 'KMS_EDITION' ($edition -replace 'Eval$', '')
if ($edition -like '*Eval' -or $edition -ne $target) {
    $targets = dism /online /Get-TargetEditions | Select-String 'Target Edition : (\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
    if ($targets -notcontains $target) {
        Write-Warning "$edition can't be converted to $target (possible: $($targets -join ', ')); keeping $edition"
        $target = $edition
    }
}
if ($edition -ne $target) {
    if (-not (Wait-RunnerIdle 240)) { Write-Warning 'Runner stayed busy; conversion postponed to next boot'; return }
    Stop-Runner
    Write-Host "Converting $edition to $target; this can take 10+ minutes"
    dism /online /Set-Edition:$target /ProductKey:$(Get-KmsKey $cfg $target) /AcceptEula /Quiet
    Write-Host "DISM exited with $LASTEXITCODE"
    # Reached only if DISM didn't reboot (e.g. it failed).
    Start-Runner
    return
}

$windowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
function Get-Product {
    Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$windowsAppId' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
}
$product = Get-Product
$key = Get-KmsKey $cfg $edition
$keyCurrent = $product.Description -match 'VOLUME_KMSCLIENT' -and $key.EndsWith($product.PartialProductKey)
$wantHost = if ($kmsHost -eq 'auto') { '' } else { $kmsHost }
if ($keyCurrent -and $product.LicenseStatus -eq 1 -and $product.KeyManagementServiceMachine -eq $wantHost -and
    ($kmsHost -eq 'auto' -or $product.KeyManagementServicePort -eq $kmsPort)) {
    Write-Host "Already activated against '$kmsHost'"; return
}

$slmgr = "$env:windir\System32\slmgr.vbs"
if (-not $keyCurrent) { cscript //nologo $slmgr /ipk $key }
if ($kmsHost -eq 'auto') { cscript //nologo $slmgr /ckms } else { cscript //nologo $slmgr /skms "${kmsHost}:$kmsPort" }
cscript //nologo $slmgr /ato

$product = Get-Product
Write-Host "LicenseStatus=$($product.LicenseStatus) ($($product.Description))"
