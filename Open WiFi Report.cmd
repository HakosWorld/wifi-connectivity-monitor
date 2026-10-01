@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Open-WifiReport.ps1"
if errorlevel 1 pause
