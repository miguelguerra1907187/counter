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

function Save-HourLog($hour, $count, $mins, $isOT = $false) {
    try {
        if (-not (Test-Path $REG_PATH)) { New-Item -Path $REG_PATH -Force | Out-Null }
        Set-ItemProperty -Path $REG_PATH -Name "Hora$hour" -Value $count
        Set-ItemProperty -Path $REG_PATH -Name "Mins$hour" -Value $mins
        if ($isOT) { Set-ItemProperty -Path $REG_PATH -Name "OT$hour" -Value 1 }
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
                Where-Object { $_.Name -match '^(Hora|Mins|Closed|OT)\w+$' } |
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
                        IsOT  = $reg.PSObject.Properties["OT$h"] -ne $null
                    }
                }
            # Leer hora MEDIA si existe
            if ($reg.PSObject.Properties["HoraMEDIA"]) {
                $log["MEDIA"] = @{
                    Bills = [int]$reg.HoraMEDIA
                    Mins  = 30
                    IsOT  = $false
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

# ── Reset a las 4am del dia siguiente ──
# Reset si ya paso las 4am del dia siguiente (cubre suspension y reinicios tardios)
$resetPorCuatroAm = ($global:lastHour -ge 4) -and ($saved.Day -ne $global:lastDay)
if ($resetPorCuatroAm) {
    $global:buffer = 0
    $global:count  = 0
    Clear-HourLog
    Save-State 0 0 $global:lastDay $global:lastHour
} elseif ($saved.Hour -eq $global:lastHour) {
    $global:buffer = $saved.Buffer
    $global:count  = $saved.Count
} else {
    # Hora guardada != hora actual: el programa estuvo cerrado y cambio de hora
    $savedEsOT = ($saved.Hour -lt $SHIFT_START) -or ($saved.Hour -ge $SHIFT_END)
    if ($saved.Hour -in $LUNCH_HOURS) {
        # Lunch: no toca buffer, no guarda
        $global:buffer = $saved.Buffer
    } elseif ($savedEsOT -and $saved.Count -eq 0) {
        # OT sin trabajo: descartar silenciosamente
        $global:buffer = $saved.Buffer
    } elseif ($savedEsOT) {
        # OT con trabajo: guardar como OT, afecta buffer igual que hora normal
        $global:buffer = $saved.Buffer + ($saved.Count - $GOAL)
        Save-HourLog $saved.Hour $saved.Count 60 $true
        Mark-HourClosed $saved.Hour
    } else {
        # Hora dentro del turno
        $meta          = if ($saved.Hour -in $BREAK_HOURS) { $GOAL_BREAK } else { $GOAL }
        $global:buffer = $saved.Buffer + ($saved.Count - $meta)
        $missedMins    = if ($saved.Hour -in $BREAK_HOURS) { 45 } else { 60 }
        Save-HourLog $saved.Hour $saved.Count $missedMins
        Mark-HourClosed $saved.Hour
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
    # Redondeo simetrico al cuarto de hora mas cercano:
    #   0-7   -> 0   (la hora apenas comenzo, redondea HACIA ABAJO)
    #   8-22  -> 15
    #   23-37 -> 30  (media hora exacta -> penalizacion)
    #   38-52 -> 45
    #   53-59 -> 60  (la hora ya casi termino, redondea HACIA ARRIBA)
    if ($minutos -le 7)      { return 0,  $false }
    elseif ($minutos -le 22) { return 15, $false }
    elseif ($minutos -le 37) { return 30, $true  }
    elseif ($minutos -le 52) { return 45, $false }
    else                     { return 60, $false }
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
    foreach ($k in $log.Keys) {
        # Excluir entradas sin minutos activos reales (lunch, o una hora que
        # apenas comenzo cuando se genero el reporte) — no deben afectar
        # AVG, TOTAL, TIME ni BUFFER. (MEDIA siempre tiene 30 min, no se filtra)
        if ((Mins-DeClave $k $log) -eq 0) { continue }
        $bills[$k] = $log[$k].Bills
    }
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

        # Etiqueta
        $label  = Formato-12h $k
        $isOT   = if ($log[$k].IsOT) { $log[$k].IsOT } else { $false }
        $sufijo = if ($isBreak) { " BREAK" } elseif ($isMEDIA) { " [!]" } elseif ($isOT) { " OT" } else { "" }

        $pad  = "{0,-7}" -f $label
        $lines.Add(@{ text = "  $pad $v$sufijo"; color = $clr })
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

    $horaEnTurno = ($hora -ge $SHIFT_START) -and ($hora -lt $SHIFT_END)
    $horaEsOT    = (-not $horaEnTurno) -and ($hora -notin $LUNCH_HOURS)

    if ($horaEnTurno) {
        # ── Hora dentro del turno oficial ──
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
        $claveParaCheck = if ($esMedia) { "MEDIA" } else { "$hora" }
        if (-not (Is-HourClosed $claveParaCheck)) {
            Save-HourLog $clave $global:count $minsActivos
        }
    } elseif ($horaEsOT -and $global:count -gt 0) {
        # ── Hora OT con trabajo: guardar si no esta cerrada ──
        # Aplica logica de cuartos igual que horas normales
        if ($esMedia) {
            $clave = "MEDIA"
        } else {
            $clave       = "$hora"
            $minsActivos = $minsActivos   # ya calculado por Redondear-AcuartO
        }
        $claveParaCheck = if ($esMedia) { "MEDIA" } else { "$hora" }
        if (-not (Is-HourClosed $claveParaCheck)) {
            Save-HourLog $clave $global:count $minsActivos $true
        }
    }

    $log = Load-HourLog
    # Si es MEDIA fuera de turno con trabajo, agregar en memoria
    if ($horaEsOT -and $esMedia -and $global:count -gt 0 -and -not $log.ContainsKey("MEDIA")) {
        $log["MEDIA"] = @{ Bills = $global:count; Mins = 30; IsOT = $true }
    }
    # Si es MEDIA dentro del turno, agregar en memoria
    if ($horaEnTurno -and $esMedia -and -not $log.ContainsKey("MEDIA")) {
        $log["MEDIA"] = @{ Bills = $global:count; Mins = 30; IsOT = $false }
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

    # ── Accion de cierre: resetea todo y overlay sigue corriendo ──
    $closeAction = {
        $rForm.Close()
        $global:count    = 0
        $global:buffer   = 0
        $global:lastHour = (Get-Date).Hour
        $global:lastDay  = (Get-Date).Day
        Clear-HourLog
        Save-State 0 0 $global:lastDay $global:lastHour
        Update-Display
    }

    # Click en cualquier parte del reporte → cierra y resetea
    $rForm.Add_Click($closeAction)
    $rRtb.Add_Click($closeAction)

    # F11 estando el reporte visible → cierra y resetea
    $rForm.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F11) {
            & $closeAction
        }
    })
    $rRtb.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F11) {
            & $closeAction
        }
    })
    $rForm.KeyPreview = $true

    [void]$rForm.ShowDialog()
}

# ── Timer ──
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 50

$timer.Add_Tick({
    $now     = Get-Date
    $nowHour = $now.Hour
    $nowDay  = $now.Day

    # ── Reset al despertar de suspension si ya paso las 4am del dia siguiente ──
    if ($nowHour -ge 4 -and $nowDay -ne $global:lastDay) {
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
        $esOT    = ($global:lastHour -lt $SHIFT_START) -or ($global:lastHour -ge $SHIFT_END)
        $esLunch = $global:lastHour -in $LUNCH_HOURS
        $esBreak = $global:lastHour -in $BREAK_HOURS

        if ($esLunch) {
            # Lunch: no guarda, no toca buffer
        } elseif ($esOT) {
            # OT: solo guardar si hubo trabajo real
            if ($global:count -gt 0) {
                Save-HourLog $global:lastHour $global:count 60 $true
                Mark-HourClosed $global:lastHour
                $global:buffer += ($global:count - $GOAL)
            }
            # Si count=0: descarte silencioso, sin penalizacion
        } else {
            # Hora normal dentro del turno
            $mins = if ($esBreak) { 45 } else { 60 }
            Save-HourLog $global:lastHour $global:count $mins
            Mark-HourClosed $global:lastHour
            $meta           = if ($esBreak) { $GOAL_BREAK } else { $GOAL }
            $global:buffer += ($global:count - $meta)
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
                # El reset lo hace el closeAction dentro de Show-Report
                # El overlay sigue corriendo — solo reiniciamos el timer
                $timer.Start()
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
