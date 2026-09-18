# Work slots: four long-lived git worktrees next to this checkout, in ..\Malpractice-slots\wt-1..4.
# Subagents work in a slot instead of a fresh worktree, so the Godot import cache stays warm and
# starting a task costs a branch switch and a few seconds of import. See RULES.md, "Workflow".
#
#   tools\slots.bat                   make any missing slots (and show status)
#   tools\slots.bat status            what each slot holds
#   tools\slots.bat take 2 hive-lunge  slot 2 starts branch hive-lunge from main
#   tools\slots.bat free 2            slot 2 goes back to idle (main), its branch deleted if merged
#
# Slots leave out deprecated/ (sparse checkout). A new slot copies main's .godot/ before its first
# import, so it doesn't re-import every asset from scratch.

param(
    [string]$Command = "init",
    [string]$Slot = "",
    [string]$Branch = ""
)

. "$PSScriptRoot\godot_path.ps1"
$Main = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$SlotsDir = Join-Path (Split-Path $Main -Parent) "Malpractice-slots"
$Count = 4

function SlotPath([string]$n) { Join-Path $SlotsDir "wt-$n" }

function Import-Slot([string]$path) {
    Write-Host "  importing in $path ..."
    & $GodotConsole --headless --path $path --import 2>&1 | Out-File -Encoding utf8 (Join-Path $path ".godot\import.log")
}

function Slot-Branch([string]$path) {
    $b = (git -C $path branch --show-current 2>$null)
    if ($b) { return $b } else { return "" }
}

function Slot-Dirty([string]$path) {
    return [bool](git -C $path status --porcelain 2>$null)
}

function Show-Status {
    for ($i = 1; $i -le $Count; $i++) {
        $p = SlotPath $i
        if (-not (Test-Path $p)) { Write-Host ("wt-{0}  (missing)" -f $i); continue }
        $b = Slot-Branch $p
        $state = if ($b) { $b } else { "idle" }
        if (Slot-Dirty $p) { $state += "  (uncommitted changes)" }
        Write-Host ("wt-{0}  {1}" -f $i, $state)
    }
}

function Need-Slot {
    if ($Slot -notmatch '^[1-4]$') { Write-Error "Which slot? 1 to $Count."; exit 1 }
    $p = SlotPath $Slot
    if (-not (Test-Path $p)) { Write-Error "wt-$Slot doesn't exist yet: run tools\slots.bat first."; exit 1 }
    return $p
}

switch ($Command) {
    "init" {
        New-Item -ItemType Directory -Force $SlotsDir | Out-Null
        for ($i = 1; $i -le $Count; $i++) {
            $p = SlotPath $i
            if (Test-Path $p) { continue }
            Write-Host "Making wt-$i"
            git -C $Main worktree add --no-checkout --detach $p main
            if ($LASTEXITCODE -ne 0) { exit 1 }
            git -C $p sparse-checkout set --no-cone '/*' '!/deprecated/'
            git -C $p reset --hard --quiet main
            if (Test-Path (Join-Path $Main ".godot")) {
                Write-Host "  copying the import cache from main ..."
                robocopy (Join-Path $Main ".godot") (Join-Path $p ".godot") /E /NFL /NDL /NJH /NJS /NP | Out-Null
            }
            Import-Slot $p
        }
        Show-Status
    }
    "status" { Show-Status }
    "take" {
        $p = Need-Slot
        if (-not $Branch) { Write-Error "Name the branch: tools\slots.bat take $Slot <branch>"; exit 1 }
        $cur = Slot-Branch $p
        if ($cur) { Write-Error "wt-$Slot is busy with $cur. Free it first."; exit 1 }
        if (Slot-Dirty $p) { Write-Error "wt-$Slot has uncommitted changes."; exit 1 }
        git -C $p switch --quiet -c $Branch main
        if ($LASTEXITCODE -ne 0) { exit 1 }
        Import-Slot $p
        Write-Host "wt-$Slot is on $Branch ($p)"
    }
    "free" {
        $p = Need-Slot
        if (Slot-Dirty $p) { Write-Error "wt-$Slot has uncommitted changes: commit or drop them first."; exit 1 }
        $cur = Slot-Branch $p
        git -C $p switch --quiet --detach main
        if ($LASTEXITCODE -ne 0) { exit 1 }
        if ($cur) {
            git -C $Main branch -d $cur 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host "Kept branch ${cur}: it isn't merged into main." }
        }
        Import-Slot $p
        Write-Host "wt-$Slot is idle"
    }
    default { Write-Error "Unknown command '$Command' (init, status, take, free)."; exit 1 }
}
