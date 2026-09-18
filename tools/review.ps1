# Opens a game window from a work slot for Zach to look at. It starts minimized and flashes in the
# taskbar (it never takes focus). The window's title, and a yellow bar at the top of the screen,
# say what it's for. See RULES.md, "Reviews".
#
#   tools\review.bat 2 "HIVE: does the lunge read?"
#   tools\review.bat 2 "OR: try the new saw" -Scene res://tools/monster_lab.tscn
#   tools\review.bat 3 "NET: join and shove me" -Count 2          (two windows, for co-op)
#   tools\review.bat main "FAX: new stamp timing"                 (this checkout instead of a slot)
#   toolseview.bat 4 "ICONS: pick things up" --setup=icons      (skips the menu: a solo shift with the
#                                                                  named setup from scripts/review_setups.gd staged)
#
# Anything after the named options goes to the game as user args (after "--"), e.g. --seed=3.
# Steam is off (--no-steam) unless you pass --steam. Logs go to <slot>\.godot\review-<n>.log.

param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Slot,
    [Parameter(Mandatory = $true, Position = 1)][string]$Say,
    [string]$Scene = "",
    [int]$Count = 1,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GameArgs = @()
)

. "$PSScriptRoot\godot_path.ps1"
$Main = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($Slot -eq "main") {
    $p = $Main
} elseif ($Slot -match '^[1-4]$') {
    $p = Join-Path (Split-Path $Main -Parent) "Malpractice-slots\wt-$Slot"
} else {
    $p = $Slot
}
if (-not (Test-Path (Join-Path $p "project.godot"))) { Write-Error "No project at $p"; exit 1 }

# Stale import cache = black screen and "nil" errors (see play.bat); this is quick when current.
& $GodotConsole --headless --path $p --import 2>&1 | Out-File -Encoding utf8 (Join-Path $p ".godot\import.log")

for ($i = 1; $i -le $Count; $i++) {
    $title = if ($Count -gt 1) { "$Say ($i)" } else { $Say }
    $log = Join-Path $p ".godot\review-$i.log"
    $a = @("--path", "`"$p`"", "--log-file", "`"$log`"")
    if ($Count -gt 1) { $a += @("--position", ("{0},{1}" -f (60 + ($i - 1) * 820), 80), "--resolution", "800x450") }
    if ($Scene) { $a += $Scene }
    $a += @("--", "`"--review=$title`"", "--no-steam")
    foreach ($g in $GameArgs) { $a += "`"$g`"" }
    # Minimized and never activated (SW_SHOWMINNOACTIVE): it waits in the taskbar, flashing, until
    # Zach opens it, and doesn't take keyboard focus. Start-Process's "Minimized" still activates the
    # window, and a child of this shell may take the foreground, so WMI starts it instead.
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]7 }
    $cmd = "`"$GodotGui`" " + ($a -join " ")
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $cmd; CurrentDirectory = $p; ProcessStartupInformation = $startup }
    if ($r.ReturnValue -ne 0) { Write-Error "Couldn't start Godot (WMI code $($r.ReturnValue))."; exit 1 }
    Write-Host "Opened: $title  (pid $($r.ProcessId), log: $log)"
}
