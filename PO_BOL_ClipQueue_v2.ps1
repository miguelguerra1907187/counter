# ============================================================
#  PO_BOL_ClipQueue_v2.ps1   (motor: polling, sin hook global)
#
#  Ctrl + Shift derecho  -> abre ventana de input (nuevo lote)
#  Ctrl+V            -> pega elemento actual, carga el siguiente
#  ` (tecla arriba del Tab, teclado EUA)  -> envia 7 tabuladores
#
#  Al terminar la cola -> ventana se minimiza, cola se limpia
#  Volver a llamar Ctrl+Shift derecho -> ventana fresca
#
#  WIDGET KG -> LBS (integrado, mismo proceso):
#  Caja flotante chiquita en la esquina sup. derecha. Clic -> se
#  expande y puedes escribir un numero en kg. Enter -> convierte a
#  libras (redondeado hacia arriba). Se encoge sola a los 15s o con
#  ESC. No usa hotkey de teclado global, solo clic con el mouse.
#
#  SIN PROCESAMIENTO DE TEXTO:
#    El texto pegado se usa tal cual (sin mayusculas forzadas, sin
#    quitar simbolos, sin unir lineas partidas).
#    Separa   ->  espacio , / salto de linea (solo para armar la cola)
#
#  NOTA TECNICA:
#  Este script usa GetAsyncKeyState (polling cada 40ms), el mismo
#  metodo que contador_overlay.ps1. No instala un hook global de
#  teclado (SetWindowsHookEx). Ventajas:
#    - No depende de que el hook se "instale" correctamente
#      (en la version anterior podia fallar silenciosamente).
#    - GetAsyncKeyState no necesita foco en ninguna ventana.
#    - Es un patron mucho menos parecido a un keylogger real,
#      por lo que es menos probable que un antivirus/EDR
#      (ej. Cisco Secure/AMP) lo marque como sospechoso.
#  NOTA: la tecla ` manda 7 tabs via SendKeys (no depende del
#  Tab real, a diferencia del diseño anterior con Espacio+Tab).
# ============================================================

# -- Una sola instancia a la vez --------------------------------
$lockFile = "$env:TEMP\PoBolClipQueue.lock"
if (Test-Path $lockFile) {
    $pid_guardado = Get-Content $lockFile -ErrorAction SilentlyContinue
    $sigue_vivo   = Get-Process -Id $pid_guardado -ErrorAction SilentlyContinue
    if ($sigue_vivo) { exit }
}
$PID | Set-Content $lockFile

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -- Win32: minimizar consola + GetAsyncKeyState + estilo ventana --
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PoBolWin32 {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@ -ErrorAction SilentlyContinue

# Modo debug: si se define la variable de entorno PO_BOL_DEBUG=1
# (la pone DEBUG_PO_BOL_ClipQueue.bat), la consola se queda visible
# siempre. En uso normal la consola se oculta por completo (SW_HIDE):
# no aparece en la barra de tareas ni en Alt+Tab, igual que el overlay
# del contador. Toda la retroalimentacion normal va por Show-Toast.
$global:DEBUG_MODE = ($env:PO_BOL_DEBUG -eq '1')

function Minimize-Console {
    if ($global:DEBUG_MODE) { return }
    $hwnd = [PoBolWin32]::GetConsoleWindow()
    [PoBolWin32]::ShowWindow($hwnd, 0) | Out-Null   # SW_HIDE
}

function Restore-Console {
    if ($global:DEBUG_MODE) { return }
    # En uso normal nunca se vuelve a mostrar la consola; el estado se
    # comunica con Show-Toast. Esto evita la pantalla grande de PowerShell
    # que aparecia al abrir la ventana de input o al pegar.
}

# -- Toast -----------------------------------------------------
function Show-Toast($title, $msg) {
    $n = New-Object System.Windows.Forms.NotifyIcon
    $n.Icon            = [System.Drawing.SystemIcons]::Application
    $n.Visible         = $true
    $n.BalloonTipTitle = $title
    $n.BalloonTipText  = $msg
    $n.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
    $n.ShowBalloonTip(2500)
    Start-Sleep -Milliseconds 100
    $n.Dispose()
}

# -- Sin procesamiento -------------------------------------------
# El texto se usa tal cual lo entrega el OCR/portapapeles. Lo unico
# que se hace es separar los elementos (por coma, diagonal o salto de
# linea) para armar la cola; no se toca mayusculas/minusculas, no se
# quitan simbolos ni se unen lineas.
function Get-Lista($rawText) {
    $t = $rawText -replace '[,/\r\n]', ' '
    $t = $t -replace '\s+', ' '
    $t = $t.Trim()
    return ($t -split ' ' | Where-Object { $_.Trim() -ne '' })
}

# -- Ventana de input --------------------------------------------
function Show-InputWindow {
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "PO / BOL Filler"
    $form.Size            = New-Object System.Drawing.Size(420, 250)
    $form.StartPosition   = "CenterScreen"
    $form.TopMost         = $true
    $form.BackColor       = [System.Drawing.Color]::FromArgb(12, 12, 28)
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = "Pega aqui (Ctrl+V) - carga automatico:"
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 180, 216)
    $lbl.Font      = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
    $lbl.Location  = New-Object System.Drawing.Point(14, 14)
    $lbl.Size      = New-Object System.Drawing.Size(380, 22)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline  = $true
    $txt.ScrollBars = "Vertical"
    $txt.Location   = New-Object System.Drawing.Point(14, 44)
    $txt.Size       = New-Object System.Drawing.Size(380, 160)
    $txt.BackColor  = [System.Drawing.Color]::FromArgb(22, 22, 45)
    $txt.ForeColor  = [System.Drawing.Color]::White
    $txt.Font       = New-Object System.Drawing.Font("Consolas", 11)

    # Al pegar -> cerrar ventana automaticamente
    $txt.Add_KeyDown({
        param($s, $e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::V) {
            $form.BeginInvoke([System.Action]{
                Start-Sleep -Milliseconds 80
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.Close()
            })
        }
    })

    $form.Controls.AddRange(@($lbl, $txt))

    # Enfocar el textbox al abrir
    $form.Add_Shown({ $txt.Focus() })

    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $txt.Text
    }
    return $null
}

# -- Widget flotante: conversor KG -> LBS ---------------------------
# Caja chiquita siempre visible en la esquina sup. derecha. No usa
# ShowDialog (eso bloquearia todo el script) -> se muestra con Show()
# normal y corre dentro del mismo bucle de mensajes que el motor de
# hotkeys (Application.Run mas abajo). Un solo proceso, un solo .ps1.
$sizeCompactoKG  = New-Object System.Drawing.Size(26, 14)
$sizeExpandidoKG = New-Object System.Drawing.Size(115, 48)

$formKG                 = New-Object System.Windows.Forms.Form
$formKG.TopMost         = $true
$formKG.FormBorderStyle = 'None'
$formKG.BackColor       = [System.Drawing.Color]::FromArgb(45, 45, 45)
$formKG.Opacity         = 0.90
$formKG.StartPosition   = 'Manual'
$formKG.ShowInTaskbar   = $false
$formKG.MinimumSize     = $sizeCompactoKG
$formKG.MaximumSize     = $sizeCompactoKG
$formKG.Size            = $sizeCompactoKG

$screenKG = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formKG.Location = New-Object System.Drawing.Point(($screenKG.Width - 115 - 315), 20)

$txtKG                  = New-Object System.Windows.Forms.TextBox
$txtKG.Location         = New-Object System.Drawing.Point(6, 22)
$txtKG.Width            = 103
$txtKG.Height           = 18
$txtKG.BackColor        = [System.Drawing.Color]::Black
$txtKG.ForeColor        = [System.Drawing.Color]::White
$txtKG.Font             = New-Object System.Drawing.Font('Consolas', 8, [System.Drawing.FontStyle]::Bold)
$txtKG.BorderStyle      = 'FixedSingle'
$txtKG.TextAlign        = 'Center'
$txtKG.Visible          = $false
$formKG.Controls.Add($txtKG)

$lblResultKG            = New-Object System.Windows.Forms.Label
$lblResultKG.Text       = "KG"
$lblResultKG.ForeColor  = [System.Drawing.Color]::Lime
$lblResultKG.BackColor  = [System.Drawing.Color]::Transparent
$lblResultKG.Font       = New-Object System.Drawing.Font('Arial', 6.5, [System.Drawing.FontStyle]::Bold)
$lblResultKG.TextAlign  = 'MiddleCenter'
$lblResultKG.Cursor     = [System.Windows.Forms.Cursors]::Hand
$lblResultKG.Dock       = 'Fill'
$formKG.Controls.Add($lblResultKG)

$script:timerEsperaKG = New-Object System.Windows.Forms.Timer
$script:timerEsperaKG.Interval = 15000 # 15 segundos
$script:timerEsperaKG.Add_Tick({ Encoger-FormularioKG })

$script:estaExpandidoKG = $false

function Expandir-FormularioKG {
    $script:estaExpandidoKG = $true

    $formKG.MinimumSize     = New-Object System.Drawing.Size(0, 0)
    $formKG.MaximumSize     = New-Object System.Drawing.Size(0, 0)
    $formKG.Size            = $sizeExpandidoKG
    $formKG.BackColor       = [System.Drawing.Color]::Black

    $lblResultKG.Dock       = 'None'
    $lblResultKG.Location   = New-Object System.Drawing.Point(0, 2)
    $lblResultKG.Width      = 115
    $lblResultKG.Height     = 18
    $lblResultKG.Font       = New-Object System.Drawing.Font('Consolas', 8, [System.Drawing.FontStyle]::Bold)
    $lblResultKG.Text       = "-- lbs"
    $lblResultKG.ForeColor  = [System.Drawing.Color]::Lime

    $txtKG.Visible          = $true
    $txtKG.Text             = ""
    $txtKG.Focus()
    $formKG.Refresh()
}

function Encoger-FormularioKG {
    $script:timerEsperaKG.Stop()
    $script:estaExpandidoKG = $false
    $txtKG.Visible          = $false

    $formKG.MinimumSize     = $sizeCompactoKG
    $formKG.MaximumSize     = $sizeCompactoKG
    $formKG.Size            = $sizeCompactoKG
    $formKG.BackColor       = [System.Drawing.Color]::FromArgb(45, 45, 45)

    $lblResultKG.Dock       = 'Fill'
    $lblResultKG.Font       = New-Object System.Drawing.Font('Arial', 6.5, [System.Drawing.FontStyle]::Bold)
    $lblResultKG.Text       = "KG"
    $lblResultKG.ForeColor  = [System.Drawing.Color]::Lime
    $formKG.Refresh()
}

$lblResultKG.Add_Click({
    if (-not $script:estaExpandidoKG) { Expandir-FormularioKG }
})

$formKG.Add_Click({
    if (-not $script:estaExpandidoKG) { Expandir-FormularioKG }
})

$txtKG.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Return') {
        $inputKG = $txtKG.Text.Trim()
        if ([string]::IsNullOrEmpty($inputKG)) {
            Encoger-FormularioKG
            $e.SuppressKeyPress = $true
            return
        }
        try {
            $kg  = [int]$inputKG
            $lbs = [Math]::Ceiling($kg * 2.20462)
            $lblResultKG.Text      = "$lbs lbs"
            $lblResultKG.ForeColor = [System.Drawing.Color]::Lime

            $formKG.Refresh()

            # Inicia el contador de 15s, NO se cierra al perder el foco
            $script:timerEsperaKG.Start()
        } catch {
            $lblResultKG.Text      = "?"
            $lblResultKG.ForeColor = [System.Drawing.Color]::OrangeRed
            $formKG.Refresh()
            Start-Sleep -Milliseconds 800
            Encoger-FormularioKG
        }
        $e.SuppressKeyPress = $true
    }
    if ($e.KeyCode -eq 'Escape') {
        Encoger-FormularioKG
        $e.SuppressKeyPress = $true
    }
})

$txtKG.Add_KeyPress({
    param($s, $e)
    $allowed = '0123456789'
    if ($allowed.IndexOf($e.KeyChar) -lt 0 -and [int]$e.KeyChar -ne 8) {
        $e.Handled = $true
    }
})

$formKG.Add_Paint({
    param($sender, $e)
    if (-not $script:estaExpandidoKG) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Lime, 1)
        $e.Graphics.DrawRectangle($pen, 0, 0, ($formKG.Width - 1), ($formKG.Height - 1))
        $pen.Dispose()
    }
})

# Modeless: se muestra y sigue corriendo en el mismo bucle de mensajes
# que el motor de hotkeys (Application.Run $engine, mas abajo). No
# bloquea nada porque NO se usa ShowDialog() aqui.
$formKG.Show()

# -- Estado -------------------------------------------------------
$global:lista = @()
$global:index = 0

$global:pressedCtrlEnter = $false
$global:pressedTab       = $false
$global:pressedCtrlV     = $false
$global:lastCtrlVTime    = [DateTime]::MinValue
$global:CTRLV_DEBOUNCE_MS = 200   # tiempo minimo entre pegados aceptados

# -- Cargar lista y preparar primera PO -------------------------
function Cargar-Lista($lista) {
    $global:lista = $lista
    $global:index = 0

    Restore-Console
    Clear-Host
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "   PO / BOL FILLER - $($lista.Count) elementos" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    for ($i = 0; $i -lt $lista.Count; $i++) {
        Write-Host "  $($i+1).  $($lista[$i])" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  Ctrl+V          -> pega el siguiente" -ForegroundColor Yellow
    Write-Host "  Ctrl+Shift derecho  -> nuevo lote" -ForegroundColor Yellow
    Write-Host ""

    [System.Windows.Forms.Clipboard]::SetText($lista[0])
    Write-Host "  Portapapeles -> " -NoNewline -ForegroundColor Cyan
    Write-Host "$($lista[0])  (1/$($lista.Count))" -ForegroundColor White
    Write-Host ""

    Show-Toast "Cola lista ($($lista.Count))" "Primero: $($lista[0])  - Ctrl+V para pegar"

    # Minimizar para que el ERP quede al frente
    Start-Sleep -Milliseconds 500
    Minimize-Console
}

# -- Accion Ctrl+V -----------------------------------------------
function Procesar-CtrlV {
    if ($global:lista.Count -eq 0) { return }

    $i     = $global:index
    $total = $global:lista.Count
    if ($i -ge $total) { return }

    $pegado       = $global:lista[$i]
    $global:index = $i + 1

    if ($global:index -lt $total) {
        # Cargar siguiente
        [System.Windows.Forms.Clipboard]::SetText($global:lista[$global:index])
        $restantes = $total - $global:index
        Restore-Console
        Write-Host "  OK $pegado  ->  $($global:lista[$global:index])  ($restantes restantes)" -ForegroundColor Green
        Minimize-Console
    } else {
        # Era la ultima -> limpiar y minimizar
        [System.Windows.Forms.Clipboard]::Clear()
        $global:lista  = @()
        $global:index  = 0
        Show-Toast "OK Cola terminada" "Todos los $total elementos pegados. Ctrl+Shift derecho para nuevo lote."
        Restore-Console
        Write-Host "  OK $pegado  ->  ULTIMO" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Cola terminada. Ctrl+Shift derecho para nuevo lote." -ForegroundColor Cyan
        Write-Host ""
        Minimize-Console
    }
}

# -- Accion tecla ` (arriba del Tab) -> 7 tabuladores ------------
function Procesar-TabExtra {
    Start-Sleep -Milliseconds 50
    for ($t = 0; $t -lt 7; $t++) {
        [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
        Start-Sleep -Milliseconds 30
    }
}

# -- Accion Ctrl+Shift derecho -> abrir ventana ----------------------
function Abrir-VentanaInput {
    # No restauramos la consola aqui: el cuadro de input es TopMost y
    # se ve solo con eso. Restaurar la consola antes hacia que se viera
    # una pantalla grande de PowerShell tapando todo hasta hacerle click.
    $raw = Show-InputWindow

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $nuevaLista = Get-Lista $raw
        if ($nuevaLista.Count -gt 0) {
            Cargar-Lista $nuevaLista
        } else {
            Show-Toast "Sin elementos" "No se encontraron POs o BOLs en el texto."
            Minimize-Console
        }
    } else {
        # Cancelo sin escribir nada
        Minimize-Console
    }
}

# -- Motor invisible: timer + GetAsyncKeyState (sin hook global) --
$engine                 = New-Object System.Windows.Forms.Form
$engine.ShowInTaskbar   = $false
$engine.FormBorderStyle = 'FixedToolWindow'
$engine.StartPosition   = 'Manual'
$engine.Location        = New-Object System.Drawing.Point(-2000, -2000)
$engine.Size            = New-Object System.Drawing.Size(1, 1)
$engine.Opacity         = 0
$engine.Add_Shown({ $engine.Hide() })

# Ocultar de Alt+Tab ademas de ShowInTaskbar=false (doble seguro)
$engine.Handle | Out-Null
$GWL_EXSTYLE      = -20
$WS_EX_TOOLWINDOW = 0x00000080
$cur = [PoBolWin32]::GetWindowLong($engine.Handle, $GWL_EXSTYLE)
[void][PoBolWin32]::SetWindowLong($engine.Handle, $GWL_EXSTYLE, ($cur -bor $WS_EX_TOOLWINDOW))

$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 40

$timer.Add_Tick({
    try {
        # -- Ctrl + Shift derecho -> abrir ventana de input --
        $ctrl    = [PoBolWin32]::GetAsyncKeyState(0x11)
        $rshift  = [PoBolWin32]::GetAsyncKeyState(0xA1)
        if (($ctrl -ne 0) -and ($rshift -ne 0)) {
            if (-not $global:pressedCtrlEnter) {
                $global:pressedCtrlEnter = $true
                $timer.Stop()
                Abrir-VentanaInput
                $timer.Start()
            }
        } else {
            $global:pressedCtrlEnter = $false
        }

        # -- Ctrl + V -> avanzar cola (con debounce de tiempo) --
        $ctrl = [PoBolWin32]::GetAsyncKeyState(0x11)
        $vkey = [PoBolWin32]::GetAsyncKeyState(0x56)
        if (($ctrl -ne 0) -and ($vkey -ne 0)) {
            if (-not $global:pressedCtrlV) {
                $ahora  = Get-Date
                $transcurrido = ($ahora - $global:lastCtrlVTime).TotalMilliseconds
                if ($transcurrido -ge $global:CTRLV_DEBOUNCE_MS) {
                    $global:pressedCtrlV  = $true
                    $global:lastCtrlVTime = $ahora
                    Procesar-CtrlV
                }
            }
        } else {
            $global:pressedCtrlV = $false
        }

        # -- Tecla ` (VK_OEM_3, arriba del Tab en teclado EUA) -> 7 tabs extra --
        $backtick = [PoBolWin32]::GetAsyncKeyState(0xC0)
        if ($backtick -ne 0) {
            if (-not $global:pressedTab) {
                $global:pressedTab = $true
                Procesar-TabExtra
            }
        } else {
            $global:pressedTab = $false
        }
    } catch {
        # Cualquier error inesperado -> avisar con notificacion y cerrar
        # limpio en vez de quedar colgado en silencio (consola oculta).
        $timer.Stop()
        Show-Toast "PO/BOL se cerro por un error" "$($_.Exception.Message)"
        Start-Sleep -Milliseconds 300
        $engine.Close()
    }
})

# -- Pantalla inicial ------------------------------------------------
Clear-Host
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "   PO / BOL FILLER - Activo (motor polling)" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Ctrl+Shift derecho  -> abrir ventana de input" -ForegroundColor Yellow
Write-Host "  Ctrl+V          -> pegar siguiente PO/BOL" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Esperando shortcut..." -ForegroundColor DarkGray
Write-Host ""

# Minimizar al inicio - el script corre en background
Start-Sleep -Milliseconds 800
Minimize-Console

# Red de seguridad general: si algo truena fuera del Tick (poco comun,
# pero por si acaso) -> avisar con notificacion y cerrar limpio en vez
# de quedar colgado en silencio con la consola oculta.
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Show-Toast "PO/BOL se cerro por un error" "$($e.Exception.Message)"
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.Application]::Exit()
})

$timer.Start()

try {
    [System.Windows.Forms.Application]::Run($engine)
} finally {
    [System.Windows.Forms.Clipboard]::Clear()
    Remove-Item $lockFile -ErrorAction SilentlyContinue
    if ($script:timerEsperaKG) { $script:timerEsperaKG.Dispose() }
    if ($formKG -and -not $formKG.IsDisposed) { $formKG.Close() }
}
