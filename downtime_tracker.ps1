# ── Single instance ──
$lockFile = "$env:TEMP\DowntimeTracker.lock"
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
public class Win32b {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@

# ════════════════════════════════════════
#         CONFIGURACION
# ════════════════════════════════════════
$DATA_FILE = "$PSScriptRoot\downtime_log.txt"

# ════════════════════════════════════════
#         FORM
# ════════════════════════════════════════
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
$form.Location = New-Object System.Drawing.Point(($screen.Width - $form.Width - 130), 62)

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

# ════════════════════════════════════════
#         ESTADO
# ════════════════════════════════════════
$global:corriendo    = $false
$global:inicioActual = $null
$global:totalSecs    = 0
$global:pressedF9    = $false

# Cargar total del dia
if (Test-Path $DATA_FILE) {
    try {
        $lines = Get-Content $DATA_FILE
        $firstLine = $lines | Select-Object -First 1
        if ($firstLine -match '^DATE:(.+)$') {
            [cite_start]$savedDate = [datetime]::Parse($Matches[1].Trim())
            if ($savedDate.Date -eq (Get-Date).Date) {
                $totalLine = $lines | Where-Object { $_ -match '^TOTAL_SECS:' }
                if ($totalLine -match '^TOTAL_SECS:(\d+)$') {
                    [cite_start]$global:totalSecs = [int]$Matches[1]
                }
            } else {
                Remove-Item $DATA_FILE -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

# ════════════════════════════════════════
#         HELPERS
# ════════════════════════════════════════
function Format-Time($secs) {
    $m = [Math]::Floor($secs / 60)
    $s = $secs % 60
    return ("$m".PadLeft(2,'0') + ":" + "$s".PadLeft(2,'0'))
}

function Save-Data($totalSecs, $entry) {
    try {
        $today = (Get-Date).ToString("yyyy-MM-dd")
        if (-not (Test-Path $DATA_FILE)) {
            "DATE:$today" | Set-Content $DATA_FILE
            "TOTAL_SECS:0" | Add-Content $DATA_FILE
            "---" | Add-Content $DATA_FILE
        }
        $lines = Get-Content $DATA_FILE
        $lines = $lines | ForEach-Object {
            if ($_ -match '^TOTAL_SECS:') { "TOTAL_SECS:$totalSecs" } else { $_ }
        }
        $lines | Set-Content $DATA_FILE
        if ($entry) { $entry | Add-Content $DATA_FILE }
    } catch {}
}

function Update-Display {
    $secs = $global:totalSecs
    if ($global:corriendo -and $global:inicioActual) {
        $secs += [int]((Get-Date) - $global:inicioActual).TotalSeconds
    }

    $txt   = Format-Time $secs
    $color = if ($global:corriendo) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::DimGray }

    $rtb.Clear()
    $rtb.SelectionStart  = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor  = $color
    $rtb.AppendText($txt)
    $rtb.SelectAll()
    $rtb.SelectionAlignment = 'Center'
}

# ════════════════════════════════════════
#         TIMER
# ════════════════════════════════════════
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

$timer.Add_Tick({
    $hoy = (Get-Date).Date
    if ($global:corriendo -and $global:inicioActual -and $global:inicioActual.Date -ne $hoy) {
        $global:corriendo    = $false
        $global:inicioActual = $null
        $global:totalSecs    = 0
        Remove-Item $DATA_FILE -ErrorAction SilentlyContinue
        Update-Display
        return
    }

    # ── F9 → toggle downtime tracking ──
    $f9 = [Win32b]::GetAsyncKeyState(0x78)
    if ($f9 -ne 0) {
        if (-not $global:pressedF9) {
            $global:pressedF9 = $true
            $now = Get-Date

            if (-not $global:corriendo) {
                $global:corriendo    = $true
                $global:inicioActual = $now
                if (-not (Test-Path $DATA_FILE)) {
                    $today = $now.ToString("yyyy-MM-dd")
                    "DATE:$today"    | Set-Content $DATA_FILE
                    "TOTAL_SECS:0"   | Add-Content $DATA_FILE
                    "---"            | Add-Content $DATA_FILE
                }
            } else {
                $durSecs             = [int]($now - $global:inicioActual).TotalSeconds
                $global:totalSecs   += $durSecs
                $global:corriendo    = $false
                $inicio_str = $global:inicioActual.ToString("HH:mm")
                $fin_str    = $now.ToString("HH:mm")
                $entry = "[$inicio_str - $fin_str]  duration: $(Format-Time $durSecs)  (total acc: $(Format-Time $global:totalSecs))"
                Save-Data $global:totalSecs $entry
                $global:inicioActual = $null
            }
            Update-Display
        }
    } else { $global:pressedF9 = $false }

    if ($global:corriendo) { Update-Display }
})

$form.Add_Shown({ Update-Display })
$timer.Start()
try { [void]$form.ShowDialog() } finally {
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}