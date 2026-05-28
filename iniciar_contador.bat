@echo off
set "script=%~dp0contador_overlay.ps1"
set "vbs=%TEMP%\run_contador.vbs"
(
echo Set WshShell = CreateObject^("WScript.Shell"^)
echo WshShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%script%""", 0, False
) > "%vbs%"
cscript //nologo "%vbs%"
del "%vbs%"