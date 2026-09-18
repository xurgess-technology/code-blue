@echo off
rem Opens a review window from a work slot: see toolseview.ps1 and RULES.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0review.ps1" %*
