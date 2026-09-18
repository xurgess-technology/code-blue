@echo off
setlocal
rem Export Malpractice the way it ships on Steam: an .exe plus a .pck of pre-imported assets,
rem written to builds\windows\. No import step when you play it, and the shader baker runs here
rem so the first launch compiles less.
rem
rem   build.bat          release build (what players get), then launches it
rem   build.bat debug    debug build with Malpractice.console.exe for the engine log, then launches it
rem   build.bat nolaunch release build only (add "debug" too for a debug build)
cd /d "%~dp0"

set "GODOT=%USERPROFILE%\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
if not exist "%GODOT%" set "GODOT=%USERPROFILE%\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=%USERPROFILE%\Desktop\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT%" (
  echo.
  echo Could not find Godot. Looked under your Desktop for
  echo   Godot_v4.7.2-stable_win64.exe
  echo.
  echo Open build.bat in Notepad and point GODOT at your Godot 4.7 executable.
  echo.
  pause
  exit /b 1
)

set "TEMPLATES=%APPDATA%\Godot\export_templates\4.7.2.stable"
if not exist "%TEMPLATES%\windows_release_x86_64.exe" (
  echo.
  echo Godot 4.7.2 export templates are not installed. In the Godot editor:
  echo   Editor ^> Manage Export Templates ^> Download and Install
  echo.
  pause
  exit /b 1
)

set "MODE=release"
set "LAUNCH=1"
for %%A in (%*) do (
  if /i "%%A"=="debug" set "MODE=debug"
  if /i "%%A"=="nolaunch" set "LAUNCH=0"
)

set "OUT=builds\windows"
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%"

title Malpractice build
echo Exporting a %MODE% build to %OUT% ...
echo.
rem Not --headless: the shader baker needs a real GPU to pre-compile shaders into the .pck,
rem so a Godot window flashes up for the ~30 seconds this takes. A windowed editor run re-saves
rem project.godot in its own format on the way out, so it is put back untouched afterwards.
copy /y project.godot "%TEMP%\malpractice_project.godot.bak" >nul
"%GODOT%" --path . --export-%MODE% "Windows Desktop" "%OUT%\Malpractice.exe"
set EXPORT_RC=%ERRORLEVEL%
copy /y "%TEMP%\malpractice_project.godot.bak" project.godot >nul
if not "%EXPORT_RC%"=="0" goto failed
if not exist "%OUT%\Malpractice.exe" goto failed
if not exist "%OUT%\Malpractice.pck" goto failed

echo.
echo Built %OUT%\Malpractice.exe
if "%LAUNCH%"=="0" exit /b 0

if "%MODE%"=="debug" (
  "%OUT%\Malpractice.console.exe"
) else (
  start "" "%OUT%\Malpractice.exe"
)
exit /b 0

:failed
echo.
echo Export failed. The log above says why.
pause
exit /b 1
