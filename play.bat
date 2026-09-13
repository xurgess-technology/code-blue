@echo off
setlocal
rem Double-click to play Code Blue.
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

title Code Blue
echo Starting Code Blue from %CD%
echo Using %GODOT%
echo.
"%GODOT%" --path .
set RC=%ERRORLEVEL%
echo.
echo Game closed (exit code %RC%).
if not "%RC%"=="0" pause
