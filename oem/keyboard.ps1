# Runs at each user logon: sets LOCALE_KEYBOARD as the user's keyboard and copies it to the logon screen and new users.
. "$PSScriptRoot\common.ps1"
$culture = Get-Setting (Read-Config) 'LOCALE_KEYBOARD'
if (-not $culture) { return }

$layout = [Globalization.CultureInfo]::GetCultureInfo($culture).KeyboardLayoutId
$tip = '{0:X4}:{1:X8}' -f $layout, $layout
$list = Get-WinUserLanguageList
if ($list.Count -eq 1 -and $list[0].InputMethodTips.Count -eq 1 -and $list[0].InputMethodTips[0] -eq $tip) { return }

# Keeps the display language, replaces the keyboards with the requested one.
$list[0].InputMethodTips.Clear()
$list[0].InputMethodTips.Add($tip)
while ($list.Count -gt 1) { $list.RemoveAt(1) }
Set-WinUserLanguageList $list -Force
Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
