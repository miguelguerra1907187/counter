@echo off
set "script=%~dp0PO_BOL_ClipQueue_v2.ps1"
set "vbs=%TEMP%\run_po_bol_clipqueue.vbs"
(
echo Set WshShell = CreateObject^("WScript.Shell"^)
echo WshShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%script%""", 0, False
) > "%vbs%"
cscript //nologo "%vbs%"
del "%vbs%"
