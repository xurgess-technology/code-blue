# Finds Godot 4.7 the same way play.bat does. Dot-source it: . "$PSScriptRoot\godot_path.ps1"
# Sets $GodotConsole (logs to the terminal: imports, headless runs) and $GodotGui (no console
# window: review windows).

$dir = Join-Path $env:USERPROFILE "Desktop\Godot_v4.7.2-stable_win64.exe"
$GodotConsole = $null
$GodotGui = $null
foreach ($p in @((Join-Path $dir "Godot_v4.7.2-stable_win64_console.exe"), (Join-Path $dir "Godot_v4.7.2-stable_win64.exe"), $dir)) {
    if (Test-Path $p -PathType Leaf) { $GodotConsole = $p; break }
}
foreach ($p in @((Join-Path $dir "Godot_v4.7.2-stable_win64.exe"), $dir, $GodotConsole)) {
    if ($p -and (Test-Path $p -PathType Leaf)) { $GodotGui = $p; break }
}
if (-not $GodotConsole) {
    Write-Error "Could not find Godot under $dir (see play.bat)."
    exit 1
}
