@echo off
setlocal
title Total Computer Health Scan
rem One-click scan: runs the read-only collector, then opens the dashboard with the new report.
rem By default no file is written. Extra arguments are passed through:
rem   Open-HealthScan.cmd -SaveReport   also keep the report in the reports\ folder
rem   Open-HealthScan.cmd -QuickScan    also request a Defender quick scan (as administrator)
rem -ExecutionPolicy Bypass applies to this one PowerShell process only; it does not change
rem any system or user setting, and a policy enforced by your organization still wins.
if not exist "%~dp0Collect-Health.ps1" (
  echo Collect-Health.ps1 was not found next to this file.
  echo If you opened this from inside a ZIP, extract the whole folder first, then run it again.
  pause
  exit /b 1
)
rem Windows PowerShell by its full path, so a powershell.exe in the current folder is never run.
rem A 32-bit Command Prompt sees the 32-bit copy under System32; Sysnative reaches the 64-bit one.
set "HS_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "HS_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%HS_PS%" (
  echo Windows PowerShell was not found at %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe.
  echo It is part of Windows 10 and 11; if it was removed, the scan cannot run.
  pause
  exit /b 1
)
echo Collecting local health status. No settings are changed and nothing is uploaded.
echo.
"%HS_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Collect-Health.ps1" -OpenDashboard %*
rem PowerShell can exit with a negative code, which "if errorlevel 1" would miss.
if not "%errorlevel%"=="0" (
  echo.
  echo The collector could not run, so there is no new report.
  echo Opening the dashboard anyway. If it shows results, they are from an EARLIER saved scan;
  echo check the "Collected" time. See README.txt for running the collector manually.
  start "" "%~dp0index.html"
  pause
)
endlocal
