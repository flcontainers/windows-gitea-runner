@echo off
rem Run by dockur at the end of unattended setup; provisioning lives in setup.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
