@echo off
reg delete "HKCU\Software\ContadorOverlay" /f >nul 2>&1
echo Buffer reiniciado a 0.
pause
