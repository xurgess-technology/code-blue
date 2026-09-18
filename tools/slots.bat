@echo off
rem Work slots for subagents: see tools\slots.ps1 and RULES.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0slots.ps1" %*
