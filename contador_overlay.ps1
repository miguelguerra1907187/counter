# ── Single instance: solo una copia a la vez ──
$lockFile = "$env:TEMP\ContadorOverlay.lock"
if (Test-Path $lockFile) {
    $pid_guardado = Get-Content $lockFile -ErrorAction SilentlyContinue
    $sigue_vivo   = Get-Process -Id $pid_guardado -ErrorAction SilentlyContinue
    if ($sigue_vivo) { exit }
}
$PID | Set-Content $lockFile

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@

# ════════════════════════════════════════
#         CONFIGURACION  ← edita aqui
# ════════════════════════════════════════

# Meta normal (horas sin break ni comida)
$GOAL          = 32

# Umbral morado en horas normales
$PURPLE_NORMAL = 35

# Horas CON break (formato 24h, solo el inicio de la hora)
$BREAK_HOURS   = @(16, 18)

# Meta reducida en horas de break
$GOAL_BREAK    = 24

# Umbral morado en horas de break
$PURPLE_BREAK  = 28

# Hora de comida (formato 24h) — no cuenta contra el buffer
$LUNCH_HOURS   = @(19)

# Inicio y fin de turno (formato 24h)
$SHIFT_START   = 14   # 2pm
$SHIFT_END     = 23   # 11pm

# Segundos minimos entre dos Alt+S para que el segundo cuente
# Sube este valor si tu flujo de reintento tarda mas de 10 seg
$DEBOUNCE_SECS = 10

# ════════════════════════════════════════
#         (no editar de aqui para abajo)
# ════════════════════════════════════════
$REG_PATH = "HKCU:\Software\ContadorOverlay"

# ── Form overlay ──
$form                 = New-Object System.Windows.Forms.Form
$form.TopMost         = $true
$form.FormBorderStyle = 'None'
$form.BackColor       = [System.Drawing.Color]::Black
$form.Opacity         = 0.75
$form.Width           = 145
$form.Height          = 38
$form.StartPosition   = 'Manual'
$form.ShowInTaskbar   = $false

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($screen.Width - $form.Width - 130), 20)

$rtb                  = New-Object System.Windows.Forms.RichTextBox
$rtb.Dock             = 'Fill'
$rtb.BackColor        = [System.Drawing.Color]::Black
$rtb.Font             = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
$rtb.ReadOnly         = $true
$rtb.BorderStyle      = 'None'
$rtb.ScrollBars       = 'None'
$rtb.WordWrap         = $false
$rtb.Multiline        = $false
$rtb.TabStop          = $false
$rtb.ShortcutsEnabled = $false
$form.Controls.Add($rtb)

# ── Persistencia ──
function Load-State {
    $now   = Get-Date
    $state = @{ Buffer = 0; Count = 0; Day = $now.Day; Hour = $now.Hour }
    try {
        if (Test-Path $REG_PATH) {
            $reg = Get-ItemProperty -Path $REG_PATH -ErrorAction Stop
            if ($reg.PSObject.Properties["Buffer"]) { $state.Buffer = [int]$reg.Buffer }
            if ($reg.PSObject.Properties["Count"])  { $state.Count  = [int]$reg.Count  }
            if ($reg.PSObject.Properties["Day"])    { $state.Day    = [int]$reg.Day    }
            if ($reg.PSObject.Properties["Hour"])   { $state.Hour   = [int]$reg.Hour   }
        }
    } catch {}
    return $state
}

function Save-State($buffer, $count, $day, $hour) {
    try {
        if (-not (Test-Path $REG_PATH)) {
            New-Item -Path $REG_PATH -Force | Out-Null
        }
        Set-ItemProperty -Path $REG_PATH -Name "Buffer" -Value $buffer
        Set-ItemProperty -Path $REG_PATH -Name "Count"  -Value $count
        Set-ItemProperty -Path $REG_PATH -Name "Day"    -Value $day
        Set-ItemProperty -Path $REG_PATH -Name "Hour"   -Value $hour
    } catch {}
}

function Save-HourLog($hour, $count, $mins) {
    try {
        if (-not (Test-Path $REG_PATH)) { New-Item -Path $REG_PATH -Force | Out-Null }
        Set-ItemProperty -Path $REG_PATH -Name "Hora$hour" -Value $count
        Set-ItemProperty -Path $REG_PATH -Name "Mins$hour" -Value $mins
    } catch {}
}

# ── FIX PUNTO 5: marca una hora como "cerrada" para que F11 no la pise ──
function Mark-HourClosed($hour) {
    try {
        if (-not (Test-Path $REG_PATH)) { New-Item -Path $REG_PATH -Force | Out-Null }
        Set-ItemProperty -Path $REG_PATH -Name "Closed$hour" -Value 1
    } catch {}
}

function Is-HourClosed($hour) {
    try {
        if (Test-Path $REG_PATH) {
            $reg = Get-ItemProperty -Path $REG_PATH -ErrorAction Stop
            if ($reg.PSObject.Properties["Closed$hour"]) { return [int]$reg."Closed$hour" -eq 1 }
        }
    } catch {}
    return $false
}

function Clear-HourLog {
    try {
        if (Test-Path $REG_PATH) {
            $reg = Get-ItemProperty -Path $REG_PATH -ErrorAction Stop
            $reg.PSObject.Properties |
                Where-Object { $_.Name -match '^(Hora|Mins|Closed)\w+$' } |
                ForEach-Object { Remove-ItemProperty -Path $REG_PATH -Name $_.Name -ErrorAction SilentlyContinue }
        }
    } catch {}
}

function Load-HourLog {
    $log = @{}
    try {
        if (Test-Path $REG_PATH) {
            $reg = Get-ItemProperty -Path $REG_PATH -ErrorAction Stop
            # Leer horas numericas
            $reg.PSObject.Properties |
                Where-Object { $_.Name -match '^Hora\d+$' } |
                ForEach-Object {
                    $h = $_.Name -replace 'Hora', ''
                    $log[$h] = @{
                        Bills = [int]$_.Value
                        Mins  = if ($reg.PSObject.Properties["Mins$h"]) { [int]$reg."Mins$h" } else { 60 }
                    }
                }
            # Leer hora MEDIA si existe
            if ($reg.PSObject.Properties["HoraMEDIA"]) {
                $log["MEDIA"] = @{
                    Bills = [int]$reg.HoraMEDIA
                    Mins  = 30
                }
            }
        }
    } catch {}
    return $log
}

# ── Estado ──
$saved           = Load-State
$now             = Get-Date
$global:lastDay  = $now.Day
$global:lastHour = $now.Hour

if ($saved.Day -ne $global:lastDay) {
    $global:buffer = 0
    $global:count  = 0
    Clear-HourLog
    Save-State 0 0 $global:lastDay $global:lastHour
} elseif ($saved.Hour -eq $global:lastHour) {
    $global:buffer = $saved.Buffer
    $global:count  = $saved.Count
} else {
    # Hora guardada != hora actual: el programa estuvo cerrado y cambio de hora
    $savedHoraEnTurno = ($saved.Hour -ge $SHIFT_START) -and ($saved.Hour -lt $SHIFT_END)
    if ($savedHoraEnTurno) {
        if ($saved.Hour -in $LUNCH_HOURS) {
            $global:buffer = $saved.Buffer
        } else {
            $meta          = if ($saved.Hour -in $BREAK_HOURS) { $GOAL_BREAK } else { $GOAL }
            $global:buffer = $saved.Buffer + ($saved.Count - $meta)
        }
        $missedMins = if ($saved.Hour -in $BREAK_HOURS) { 45 } elseif ($saved.Hour -in $LUNCH_HOURS) { 0 } else { 60 }
        Save-HourLog $saved.Hour $saved.Count $missedMins
        Mark-HourClosed $saved.Hour   # marca la hora anterior como cerrada al arrancar en hora nueva
    } else {
        # Hora guardada fuera de turno (ej: se abrio antes de las 2pm) -- ignorar, no tocar buffer
        $global:buffer = $saved.Buffer
    }
    $global:count  = 0
    Save-State $global:buffer 0 $global:lastDay $global:lastHour
}

$global:pressedAltS  = $false
$global:pressedF11   = $false
$global:pressedF12   = $false
# ── DEBOUNCE: timestamp del ultimo Alt+S aceptado ──
$global:lastAltSTime = [DateTime]::MinValue

# ── Helpers overlay ──
function Get-Meta {
    $h = (Get-Date).Hour
    if ($h -in $LUNCH_HOURS) { return $GOAL }
    if ($h -in $BREAK_HOURS) { return $GOAL_BREAK }
    return $GOAL
}

function Get-CountColor($c, $meta) {
    $purple = if ($meta -eq $GOAL_BREAK) { $PURPLE_BREAK } else { $PURPLE_NORMAL }
    if ($c -ge $purple)        { return [System.Drawing.Color]::MediumOrchid }
    if (($c / $meta) -ge 1.0) { return [System.Drawing.Color]::Lime }
    if (($c / $meta) -ge 0.5) { return [System.Drawing.Color]::Yellow }
    return [System.Drawing.Color]::Red
}

function Get-BufferColor($b) {
    if ($b -ge 16) { return [System.Drawing.Color]::MediumOrchid }
    if ($b -ge 8)  { return [System.Drawing.Color]::Lime }
    if ($b -ge 1)  { return [System.Drawing.Color]::Yellow }
    return [System.Drawing.Color]::Red
}

function Update-Display {
    $meta       = Get-Meta
    $countTxt   = "$($global:count)"
    $bufTxt     = if ($global:buffer -ge 0) { "+$($global:buffer)" } else { "$($global:buffer)" }
    $countColor = Get-CountColor $global:count $meta
    $bufColor   = Get-BufferColor $global:buffer
    $sepColor   = [System.Drawing.Color]::DimGray

    $rtb.Clear()
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.SelectionColor = $countColor;     $rtb.AppendText($countTxt)
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.SelectionColor = $sepColor;       $rtb.AppendText('|')
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.SelectionColor = $bufColor;       $rtb.AppendText($bufTxt)
    $rtb.SelectAll()
    $rtb.SelectionAlignment = 'Center'
}

Update-Display

# ════════════════════════════════════════
#         LOGICA DE REPORTE (F11)
# ════════════════════════════════════════

function Redondear-AcuartO($minutos) {
    # Devuelve [mins_activos, es_media]
    if ($minutos -le 7 -or $minutos -ge 53) { return 60, $false }
    elseif ($minutos -le 22)                { return 15, $false }
    elseif ($minutos -le 37)               { return 30, $true  }
    else                                    { return 45, $false }
}

function Formato-12h($clave) {
    if ($clave -eq "MEDIA") { return "Half hr" }
    $h     = [int]$clave
    $sufx  = if ($h -lt 12) { "am" } else { "pm" }
    $h12   = $h % 12; if ($h12 -eq 0) { $h12 = 12 }
    return "$h12$sufx"
}

function Mins-DeClave($clave, $log) {
    if ($clave -eq "MEDIA")                     { return 30 }
    if ([string]$clave -in ($LUNCH_HOURS | ForEach-Object { "$_" })) { return 0 }
    if ([string]$clave -in ($BREAK_HOURS | ForEach-Object { "$_" })) {
        $m = if ($log.ContainsKey($clave)) { $log[$clave].Mins } else { 45 }
        return [Math]::Min($m, 45)
    }
    if ($log.ContainsKey($clave)) { return [int]$log[$clave].Mins } else { return 60 }
}

function Generar-Reporte($log) {
    if ($log.Count -eq 0) { return @(@{ text = "BPH REPORT"; color = "White" }, @{ text = "No records for today."; color = "DimGray" }) }

    $breakStrs = $BREAK_HOURS | ForEach-Object { "$_" }
    $lunchStrs = $LUNCH_HOURS | ForEach-Object { "$_" }

    # Penalizacion MEDIA: sus bills se zerean, su tiempo (0.5hr) si cuenta
    $bills    = @{}
    $msjPenal = ""
    foreach ($k in $log.Keys) { $bills[$k] = $log[$k].Bills }
    if ($bills.ContainsKey("MEDIA")) {
        $msjPenal       = "[!] PENALTY: -$($bills['MEDIA']) (Half hour)"
        $bills["MEDIA"] = 0
    }

    # TIME: minutos reales por tipo (igual que Python)
    $totalMins  = 0
    $totalBills = 0
    foreach ($k in $bills.Keys) {
        $totalBills += $bills[$k]
        $totalMins  += Mins-DeClave $k $log
    }

    if ($totalMins -eq 0) { return @(@{ text = "No active time."; color = "DimGray" }) }

    # AVG y BUFFER — exactamente igual que Python:
    # promedio = total_bills / minutos_totales * 60
    # diferencia = total_bills - (minutos_totales / 60 * GOAL)
    $promedio   = ($totalBills / $totalMins) * 60
    $diferencia = $totalBills - (($totalMins / 60) * $GOAL)

    # Mejor hora (excluye breaks, comida y MEDIA)
    $bphPorHora = @{}
    foreach ($k in $bills.Keys) {
        $mBph = Mins-DeClave $k $log
        if ($bills[$k] -gt 0 -and $mBph -gt 0 -and $k -notin $breakStrs -and $k -notin $lunchStrs -and $k -ne "MEDIA") {
            $bphPorHora[$k] = ($bills[$k] / $mBph) * 60
        }
    }
    $mejorClave = if ($bphPorHora.Count -gt 0) { ($bphPorHora.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key } else { $null }
    $efficiency = if ($mejorClave -and $promedio -gt 0) { ($promedio / $bills[$mejorClave] * 100) } else { 0 }

    # Formato TIME (igual que Python)
    $hEnt    = [Math]::Floor($totalMins / 60)
    $hFrac   = @(0, 0.25, 0.5, 0.75, 1)[[Math]::Round(($totalMins % 60) / 15)]
    $tTotal  = $hEnt + $hFrac
    $tDisplay = "${tTotal}hr"

    # ── Construir lineas ──
    $lines   = [System.Collections.Generic.List[object]]::new()
    $onTrack = $promedio -ge $GOAL

    $lines.Add(@{ text = "BPH STATS";      color = "White" })
    $lines.Add(@{ text = "---------------"; color = "DimGray" })
    $lines.Add(@{ text = "$(if($onTrack){'[OK]'}else{'[!!]'}) $(if($onTrack){'ON TRACK'}else{'BELOW GOAL'})"; color = if($onTrack){"Lime"}else{"Red"} })
    $lines.Add(@{ text = "AVG: $([Math]::Round($promedio,2))/hr"; color = if($onTrack){"Lime"}else{"OrangeRed"} })
    $lines.Add(@{ text = "TOTAL: $totalBills bills";              color = "White" })
    $lines.Add(@{ text = "TIME: $tDisplay";                       color = "White" })
    $lines.Add(@{ text = "--------------------"; color = "DimGray" })

    if ($diferencia -ge 0) {
        $lines.Add(@{ text = "[+] BUFFER: +$([int]$diferencia)"; color = "Lime" })
    } else {
        $lines.Add(@{ text = "[-] MISSING: $([int][Math]::Abs($diferencia))"; color = "OrangeRed" })
    }
    if ($msjPenal) { $lines.Add(@{ text = $msjPenal; color = "OrangeRed" }) }

    if ($mejorClave) {
        $lines.Add(@{ text = "--------------------"; color = "DimGray" })
        $lines.Add(@{ text = "BEST: $(Formato-12h $mejorClave) -> $($bills[$mejorClave]) bills"; color = "MediumOrchid" })
        $lines.Add(@{ text = "CONSISTENCY: $([int]$efficiency)%"; color = "Yellow" })
    }

    # ── BREAKDOWN por hora con color individual ──
    $entradas = $bills.GetEnumerator() |
        Sort-Object { if ($_.Key -eq "MEDIA") { 9999 } else { [int]$_.Key } } |
        Where-Object { -not ($_.Key -eq "MEDIA" -and $_.Value -eq 0) } |
        Where-Object { $_.Key -notin $lunchStrs }

    $lines.Add(@{ text = "--------------------"; color = "DimGray" })
    $lines.Add(@{ text = "BREAKDOWN";            color = "White" })

    foreach ($entry in $entradas) {
        $k = $entry.Key
        $v = $entry.Value
        $isBreak = $k -in $breakStrs
        $isMEDIA = $k -eq "MEDIA"
        $meta_k  = if ($isBreak) { $GOAL_BREAK } else { $GOAL }
        $purp_k  = if ($isBreak) { $PURPLE_BREAK } else { $PURPLE_NORMAL }

        # Color segun rendimiento
        $clr = if ($isMEDIA) {
            "OrangeRed"   # MEDIA siempre penalizado
        } elseif ($v -ge $purp_k) {
            "MediumOrchid"
        } elseif ($v -ge $meta_k) {
            "Lime"
        } elseif ($v -ge [int]($meta_k * 0.5)) {
            "Yellow"
        } else {
            "OrangeRed"
        }

        # Etiqueta y simbolo
        $label = Formato-12h $k
        $sym   = if ($isMEDIA) { " [!]" } elseif ($v -ge $purp_k) { " [*]" } elseif ($v -ge $meta_k) { " [+]" } else { " [-]" }
        if ($isBreak) { $label = "$label*" }   # asterisco para indicar break

        $pad  = "{0,-7}" -f $label
        $lines.Add(@{ text = "  $pad $v$sym"; color = $clr })
    }

    return $lines
}

function Show-Report {
    $now     = Get-Date
    $minutos = $now.Minute
    $hora    = $now.Hour

    # Redondear la hora actual
    $minsActivos, $esMedia = Redondear-AcuartO $minutos
    $breakStrsR = $BREAK_HOURS | ForEach-Object { "$_" }
    $lunchStrsR = $LUNCH_HOURS | ForEach-Object { "$_" }

    # Solo incluir la hora en curso si está dentro del turno
    $horaEnTurno = ($hora -ge $SHIFT_START) -and ($hora -lt $SHIFT_END)

    if ($horaEnTurno) {
        if ($esMedia) {
            $clave = "MEDIA"
        } elseif ("$hora" -in $breakStrsR) {
            $clave       = "$hora"
            $minsActivos = 45
        } elseif ("$hora" -in $lunchStrsR) {
            $clave       = "$hora"
            $minsActivos = 0
        } else {
            $clave = "$hora"
        }

        # ── FIX PUNTO 5: solo guardar la hora actual si NO esta cerrada ──
        # Las horas anteriores ya fueron cerradas por el timer al cambiar de hora,
        # asi que F11 solo sobreescribe la hora/fraccion en curso.
        $claveParaCheck = if ($esMedia) { "MEDIA" } else { "$hora" }
        if (-not (Is-HourClosed $claveParaCheck)) {
            Save-HourLog $clave $global:count $minsActivos
        }
    }

    $log = Load-HourLog
    # Si es MEDIA y todavia no estaba en el log, agregarlo en memoria para el reporte
    if ($horaEnTurno -and $esMedia -and -not $log.ContainsKey("MEDIA")) {
        $log["MEDIA"] = @{ Bills = $global:count; Mins = 30 }
    }

    $lines = Generar-Reporte $log

    # ── Ventana de reporte ──
    $rForm                 = New-Object System.Windows.Forms.Form
    $rForm.TopMost         = $true
    $rForm.FormBorderStyle = 'None'
    $rForm.BackColor       = [System.Drawing.Color]::Black
    $rForm.Opacity         = 0.92
    $rForm.StartPosition   = 'Manual'
    $rForm.ShowInTaskbar   = $false
    $rForm.Width           = 340
    $rForm.Height          = 20 + ($lines.Count * 26)

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $rForm.Location = New-Object System.Drawing.Point(
        ($screen.Width - $rForm.Width - 20),
        20
    )

    $rRtb                  = New-Object System.Windows.Forms.RichTextBox
    $rRtb.Dock             = 'Fill'
    $rRtb.BackColor        = [System.Drawing.Color]::Black
    $rRtb.Font             = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold)
    $rRtb.ReadOnly         = $true
    $rRtb.BorderStyle      = 'None'
    $rRtb.ScrollBars       = 'None'
    $rRtb.WordWrap         = $false
    $rRtb.ShortcutsEnabled = $false
    $rForm.Controls.Add($rRtb)

    foreach ($line in $lines) {
        $colorName = if ($line -is [hashtable]) { $line.color } else { "White" }
        $txt       = if ($line -is [hashtable]) { $line.text  } else { $line   }
        $color     = try { [System.Drawing.Color]::$colorName } catch { [System.Drawing.Color]::White }
        $rRtb.SelectionStart  = $rRtb.TextLength
        $rRtb.SelectionLength = 0
        $rRtb.SelectionColor  = $color
        $rRtb.AppendText("$txt`n")
    }

    # Click en cualquier parte cierra
    $rForm.Add_Click({ $rForm.Close() })
    $rRtb.Add_Click({ $rForm.Close() })

    [void]$rForm.ShowDialog()
}

# ── Timer ──
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 50

$timer.Add_Tick({
    $now     = Get-Date
    $nowHour = $now.Hour
    $nowDay  = $now.Day

    # ── Cambio de dia ──
    if ($nowDay -ne $global:lastDay) {
        $global:count    = 0
        $global:buffer   = 0
        $global:lastHour = $nowHour
        $global:lastDay  = $nowDay
        Clear-HourLog
        Save-State 0 0 $nowDay $nowHour
        Update-Display
        return
    }

    # ── Cambio de hora ──
    if ($nowHour -ne $global:lastHour) {
        # Solo procesar horas dentro del turno (SHIFT_START <= hora < SHIFT_END)
        $horaEnTurno = ($global:lastHour -ge $SHIFT_START) -and ($global:lastHour -lt $SHIFT_END)
        if ($horaEnTurno) {
            $mins = if ($global:lastHour -in $BREAK_HOURS) { 45 } elseif ($global:lastHour -in $LUNCH_HOURS) { 0 } else { 60 }
            Save-HourLog $global:lastHour $global:count $mins
            Mark-HourClosed $global:lastHour   # ← sella la hora que acaba de cerrar
            if ($global:lastHour -notin $LUNCH_HOURS) {
                $meta           = if ($global:lastHour -in $BREAK_HOURS) { $GOAL_BREAK } else { $GOAL }
                $global:buffer += ($global:count - $meta)
            }
        }
        $global:count    = 0
        $global:lastHour = $nowHour
        Save-State $global:buffer 0 $nowDay $nowHour
        Update-Display
    }

    # ── Alt + S  →  +1 con debounce ──
    $alt = [Win32]::GetAsyncKeyState(0x12)
    $s   = [Win32]::GetAsyncKeyState(0x53)
    if (($alt -ne 0) -and ($s -ne 0)) {
        if (-not $global:pressedAltS) {
            $ahora = Get-Date
            $segs  = ($ahora - $global:lastAltSTime).TotalSeconds
            if ($segs -ge $DEBOUNCE_SECS) {
                $global:count++
                $global:lastAltSTime = $ahora
                Save-State $global:buffer $global:count $nowDay $nowHour
                Update-Display
            }
            $global:pressedAltS = $true
        }
    } else { $global:pressedAltS = $false }

    # ── F12  →  -1 (min 0) ──
    $f12 = [Win32]::GetAsyncKeyState(0x7B)
    if ($f12 -ne 0) {
        if (-not $global:pressedF12) {
            if ($global:count -gt 0) { $global:count-- }
            $global:pressedF12 = $true
            Save-State $global:buffer $global:count $nowDay $nowHour
            Update-Display
        }
    } else { $global:pressedF12 = $false }

    # ── F11  →  confirmacion + corte + reporte + cerrar ──
    $f11 = [Win32]::GetAsyncKeyState(0x7A)
    if ($f11 -ne 0) {
        if (-not $global:pressedF11) {
            $global:pressedF11 = $true
            $timer.Stop()
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "End shift and generate report?",
                "BPH Counter",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                Show-Report
                $form.Invoke([Action]{ $form.Close() })
            } else {
                $timer.Start()
            }
        }
    } else { $global:pressedF11 = $false }
})

$timer.Start()

# ── Opcion C: excluir overlay del Alt+Tab y taskbar con WS_EX_TOOLWINDOW ──
# Se aplica ANTES de mostrar la ventana forzando la creacion del handle
$form.Handle | Out-Null
$GWL_EXSTYLE      = -20
$WS_EX_TOOLWINDOW = 0x00000080
$WS_EX_APPWINDOW  = 0x00040000
$cur = [Win32]::GetWindowLong($form.Handle, $GWL_EXSTYLE)
[void][Win32]::SetWindowLong($form.Handle, $GWL_EXSTYLE, ($cur -bor $WS_EX_TOOLWINDOW) -band -bnot $WS_EX_APPWINDOW)

try { [void]$form.ShowDialog() } finally {
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}
