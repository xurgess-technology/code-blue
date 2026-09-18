@echo off
setlocal
rem Double-click to play Malpractice.
rem This window stays open alongside the game and shows the engine log.
cd /d "%~dp0"

set "GODOT=%USERPROFILE%\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
if not exist "%GODOT%" set "GODOT=%USERPROFILE%\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=%USERPROFILE%\Desktop\Godot_v4.7.2-stable_win64.exe"

if not exist "%GODOT%" (
  echo.
  echo Could not find Godot. Looked under your Desktop for
  echo   Godot_v4.7.2-stable_win64.exe
  echo.
  echo Open play.bat in Notepad and point GODOT at your Godot 4.7 executable.
  echo.
  pause
  exit /b 1
)

title Malpractice
echo Starting Malpractice from %CD%
echo Using %GODOT%
echo.
rem .godot/ (the import cache: which scripts declare a global class_name, which assets are
rem imported) is gitignored and local to this checkout, so a git pull that brings in new scripts
rem or assets can leave it stale -- that shows up as a black screen and "nil" script errors.
rem Re-running import here is quick when nothing changed, and self-heals when something did.
echo Checking for anything new to import...
"%GODOT%" --headless --path . --import
echo.
"%GODOT%" --path .
set RC=%ERRORLEVEL%
echo.
echo Game closed (exit code %RC%).
if not "%RC%"=="0" pause
