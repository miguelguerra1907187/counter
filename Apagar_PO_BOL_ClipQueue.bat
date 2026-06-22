@echo off
set "lockFile=%TEMP%\PoBolClipQueue.lock"

if not exist "%lockFile%" (
    echo No hay ninguna instancia de PO/BOL corriendo.
    pause
    exit /b
)

set /p pid=<"%lockFile%"

tasklist /FI "PID eq %pid%" | findstr "%pid%" >nul
if errorlevel 1 (
    echo No se encontro el proceso ^(PID %pid%^). Borrando archivo de bloqueo viejo...
    del "%lockFile%" >nul 2>&1
    pause
    exit /b
)

taskkill /PID %pid% /F >nul 2>&1
del "%lockFile%" >nul 2>&1
echo PO/BOL ClipQueue apagado.
pause
