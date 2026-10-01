@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Disable-LanAccess.ps1"
if errorlevel 1 pause
