<#
  Menu radial local (F1 / F2 / HOLD) para copiar notas al portapapeles.
  100% local: no hace llamadas de red, no guarda nada en disco ni en registro,
  no usa hooks globales de teclado (usa GetAsyncKeyState por polling, igual
  que el resto de tus scripts, para evitar falsos positivos de AV).

  Activacion:
    - Hotkey: Supr (Delete) abre el menu | Insert repite el ultimo texto copiado
      (sin abrir el menu, solo funciona cuando el menu esta cerrado)
    - Widget flotante clickeable (circulo pequeno, esquina inferior derecha)

  Uso:
    - Nivel 1 (mouse o teclado): Izquierda/Insert = F1 | Derecha/Inicio(Home) = F2 |
      Abajo/RePag(Prior) = HOLD AT TERM
    - Nivel 2 y 3: solo teclado. Flechas Arriba/Abajo mueven el resaltado,
      numero (1-9) selecciona directo, Espacio marca/desmarca (listas multi),
      Enter confirma, Esc regresa un nivel / cancela.
    - Al terminar un issue: "A" = agregar otro issue al mismo Force,
      Enter = copiar y cerrar.
#>

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process powershell -ArgumentList "-NoProfile -STA -WindowStyle Hidden -File `"$PSCommandPath`"" | Out-Null
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class LocalKeyState {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private const byte VK_MENU = 0x12;
    private const uint KEYEVENTF_KEYUP = 0x2;

    public static void ForceForeground(IntPtr hWnd) {
        // Truco: Windows solo cede el foreground a un proceso que "acaba de
        // recibir input" propio; simular un Alt fantasma satisface ese chequeo.
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);

        IntPtr fg = GetForegroundWindow();
        uint dummyProcId;
        uint fgThread = GetWindowThreadProcessId(fg, out dummyProcId);
        uint curThread = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != curThread) {
            attached = AttachThreadInput(curThread, fgThread, true);
        }
        ShowWindow(hWnd, 5); // SW_SHOW
        BringWindowToTop(hWnd);
        SetForegroundWindow(hWnd);
        if (attached) {
            AttachThreadInput(curThread, fgThread, false);
        }
    }
}
"@

# ======================= CONFIGURACION DEL MENU =======================

$ReasonesIlegibilidad = @('blurry','faded','too dark','obstructed')
$BadBolFields         = @('shipper','cons','third party','bol','po','ref','quote','breakdown','weight')
$BadBolReasons        = @('cutted','ilegible','faded')
$Campos               = @('address','name','zip','city','state','pro#','weight','other')
$ConsShprList         = @('city/zip dont route') + ($Campos | Where-Object { $_ -notin @('other','pro#','weight') }) + @('name,add,city,state,zip')

$Force1Issues = @(
    [PSCustomObject]@{ Label='bad bol';      Tag='bad bol';      Sub='badbol-field'; SubList=$BadBolFields }
    [PSCustomObject]@{ Label='cons';         Tag='cons';         Sub='reason-multi'; SubList=$ConsShprList }
    [PSCustomObject]@{ Label='shpr';         Tag='shpr';         Sub='reason-multi'; SubList=$ConsShprList }
    [PSCustomObject]@{ Label='missing page'; Tag='missing page'; Sub='none' }
    [PSCustomObject]@{ Label='pro sticker';  Tag='pro sticker';  Sub='pro-sticker' }
)

$Force2Issues = @(
    [PSCustomObject]@{ Label='bad bol / missing pages';   Tag='bad bol/missing pages';      Sub='badbol-field'; SubList=($BadBolFields + 'missing page') }
    [PSCustomObject]@{ Label='cons';                      Tag='cons';                      Sub='reason-multi'; SubList=$ConsShprList }
    [PSCustomObject]@{ Label='shpr';                      Tag='shpr';                      Sub='reason-multi'; SubList=$ConsShprList }
    [PSCustomObject]@{ Label='improper shipping name';   Tag='improper shipping name';   Sub='none' }
    [PSCustomObject]@{ Label='no hazmat info';            Tag='no hazmat info';            Sub='none' }
    [PSCustomObject]@{ Label='missing chemical const.';   Tag='missing chemical const.';   Sub='none' }
    [PSCustomObject]@{ Label='weight breakdown';          Tag='weight breakdown';          Sub='none' }
    [PSCustomObject]@{ Label='missing emergency contact'; Tag='missing emergency contact'; Sub='none' }
    [PSCustomObject]@{ Label='shipper cert not signed';   Tag='shipper cert not signed';   Sub='none' }
    [PSCustomObject]@{ Label='prohibited freight';        Tag='prohibited freight';        Sub='none' }
)

$RazonesAddrIssue  = @('city/zip dont route','city/zip valid-email tac','address incomplete')
$RazonesProSticker = @('covering info','indexed pro mismatch')
$HoldText = 'Hold at term xxx DUE TO'

# ======================= ESTADO GLOBAL (todo $script: para sobrevivir a los eventos) ==

$script:Basket       = New-Object System.Collections.Generic.List[string]
$script:CurrentForce = $null
$script:CurrentIssue = $null
$script:CurrentField = $null
$script:State        = 'hidden'   # hidden | nivel1 | issue | reason-multi-pick | reason | fields | reason-pro | fields-pro | badbol-field | badbol-reason | confirm

$script:LM_Title      = ''
$script:LM_Options    = @()
$script:LM_Multi      = $false
$script:LM_Highlight  = 0
$script:LM_Selected   = New-Object System.Collections.Generic.HashSet[int]
$script:LM_ItemBlocks = @()
$script:LastCopied    = ''

# ======================= VENTANA PRINCIPAL =======================

$Win = New-Object System.Windows.Window
$Win.WindowStyle            = 'None'
$Win.AllowsTransparency     = $true
$Win.Background             = 'Transparent'
$Win.Topmost                = $true
$Win.ShowInTaskbar          = $false
$Win.SizeToContent          = 'WidthAndHeight'
$Win.WindowStartupLocation  = 'CenterScreen'
$Win.Visibility             = 'Hidden'

$RootGrid = New-Object System.Windows.Controls.Grid
$Win.Content = $RootGrid

function New-Brush($hex) { return [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
$BgBrush     = New-Brush '#1E1E1E'
$AccentBrush = New-Brush '#3A7BD5'
$TextBrush   = New-Brush '#FFFFFF'
$DimBrush    = New-Brush '#888888'

function Clear-Root { $RootGrid.Children.Clear() }

function Close-Menu {
    $script:Basket.Clear()
    $script:CurrentForce = $null
    $script:State = 'hidden'
    $Win.Visibility = 'Hidden'
}

function Copy-AndFlash([string]$text) {
    $script:LastCopied = $text
    [System.Windows.Clipboard]::SetText($text)
    Clear-Root
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Background = $BgBrush
    $panel.Margin = '20'
    $msg = New-Object System.Windows.Controls.TextBlock
    $msg.Text = "Copiado: $text"
    $msg.Foreground = $TextBrush
    $msg.FontSize = 16
    $msg.Margin = '10'
    $panel.Children.Add($msg) | Out-Null
    $RootGrid.Children.Add($panel) | Out-Null

    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(700)
    $t.Add_Tick({
        param($s, $e)
        $s.Stop()
        Close-Menu
    })
    $t.Start()
}

# ---------- Motor generico de lista por teclado (nivel 2 / nivel 3) ----------

function Redraw-ListMenu {
    for ($i = 0; $i -lt $script:LM_Options.Count; $i++) {
        $mark = if ($script:LM_Multi) { if ($script:LM_Selected.Contains($i)) { '[x]' } else { '[ ]' } } else { '   ' }
        $pointer = if ($i -eq $script:LM_Highlight) { '>' } else { ' ' }
        $script:LM_ItemBlocks[$i].Text = "$pointer $($i+1). $mark $($script:LM_Options[$i])"
        $script:LM_ItemBlocks[$i].Foreground = if ($i -eq $script:LM_Highlight) { $AccentBrush } else { $TextBrush }
    }
}

function Draw-ListMenu {
    Clear-Root
    $outer = New-Object System.Windows.Controls.Border
    $outer.Background = $BgBrush
    $outer.CornerRadius = '10'
    $outer.Padding = '16'
    $stack = New-Object System.Windows.Controls.StackPanel
    $outer.Child = $stack
    $RootGrid.Children.Add($outer) | Out-Null

    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = $script:LM_Title
    $titleBlock.Foreground = $TextBrush
    $titleBlock.FontSize = 15
    $titleBlock.FontWeight = 'Bold'
    $titleBlock.Margin = '0,0,0,8'
    $stack.Children.Add($titleBlock) | Out-Null

    $script:LM_ItemBlocks = @()
    foreach ($opt in $script:LM_Options) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Foreground = $TextBrush
        $tb.FontSize = 14
        $tb.Margin = '2'
        $script:LM_ItemBlocks += $tb
        $stack.Children.Add($tb) | Out-Null
    }

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = if ($script:LM_Multi) { 'Tab/Flechas: mover  Espacio: marcar  Enter: confirmar  Esc: atras' }
                 else { 'Tab/Flechas: mover  Enter: elegir  Esc: atras' }
    $hint.Foreground = $DimBrush
    $hint.FontSize = 11
    $hint.Margin = '0,8,0,0'
    $stack.Children.Add($hint) | Out-Null

    Redraw-ListMenu
}

function Enter-ListMenu([string]$title, [string[]]$options, [bool]$multi, [string]$state) {
    $script:LM_Title     = $title
    $script:LM_Options   = $options
    $script:LM_Multi     = $multi
    $script:LM_Highlight = 0
    $script:LM_Selected  = New-Object System.Collections.Generic.HashSet[int]
    $script:State        = $state
    Draw-ListMenu
}

# Procesa una tecla dentro de un menu de lista. Devuelve:
#   $null           -> seguimos navegando (ya redibujado)
#   'BACK'          -> el usuario pidio regresar (Esc)
#   string          -> opcion elegida (modo single)
#   string[]        -> opciones elegidas (modo multi, puede ser vacio)
function Process-ListMenuKey($e) {
    $count = $script:LM_Options.Count
    if ($count -eq 0) { return $null }

    switch ($e.Key) {
        'Down' {
            $script:LM_Highlight = ($script:LM_Highlight + 1) % $count
            Redraw-ListMenu
            return $null
        }
        'Up' {
            $script:LM_Highlight = ($script:LM_Highlight - 1 + $count) % $count
            Redraw-ListMenu
            return $null
        }
        'Tab' {
            $shift = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift
            if ($shift) {
                $script:LM_Highlight = ($script:LM_Highlight - 1 + $count) % $count
            } else {
                $script:LM_Highlight = ($script:LM_Highlight + 1) % $count
            }
            Redraw-ListMenu
            return $null
        }
        'Space' {
            if ($script:LM_Multi) {
                if ($script:LM_Selected.Contains($script:LM_Highlight)) {
                    [void]$script:LM_Selected.Remove($script:LM_Highlight)
                } else {
                    [void]$script:LM_Selected.Add($script:LM_Highlight)
                }
                Redraw-ListMenu
            }
            return $null
        }
        'Return' {
            if ($script:LM_Multi) {
                if ($script:LM_Selected.Count -eq 0) {
                    [void]$script:LM_Selected.Add($script:LM_Highlight)
                }
                return ,@($script:LM_Selected | Sort-Object | ForEach-Object { $script:LM_Options[$_] })
            } else {
                return $script:LM_Options[$script:LM_Highlight]
            }
        }
        'Escape' { return 'BACK' }
        'Home'   { return 'BACK' }
        default {
            $keyStr = $e.Key.ToString()
            if ($keyStr -match '^D([1-9])$') {
                $n = [int]$Matches[1] - 1
                if ($n -lt $count) {
                    if ($script:LM_Multi) {
                        $script:LM_Highlight = $n
                        if ($script:LM_Selected.Contains($n)) { [void]$script:LM_Selected.Remove($n) } else { [void]$script:LM_Selected.Add($n) }
                        Redraw-ListMenu
                        return $null
                    } else {
                        return $script:LM_Options[$n]
                    }
                }
            }
            return $null
        }
    }
}

# ---------- Pantallas concretas ----------

function Enter-IssueMenu {
    $issues = if ($script:CurrentForce -eq 'f1') { $Force1Issues } else { $Force2Issues }
    $labels = $issues | ForEach-Object { $_.Label }
    $title = "FORCE $(if ($script:CurrentForce -eq 'f1') {1} else {2}) - elige issue"
    Enter-ListMenu $title $labels $false 'issue'
}

function Enter-Confirm {
    $script:State = 'confirm'
    Draw-Confirm
}

function Draw-Confirm {
    Clear-Root
    $outer = New-Object System.Windows.Controls.Border
    $outer.Background = $BgBrush
    $outer.CornerRadius = '10'
    $outer.Padding = '16'
    $stack = New-Object System.Windows.Controls.StackPanel
    $outer.Child = $stack
    $RootGrid.Children.Add($outer) | Out-Null

    $prefix = if ($script:CurrentForce -eq 'f1') { 'f1' } else { 'haz' }
    $preview = "$prefix-" + ($script:Basket -join ',')

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = "Actual: $preview"
    $tb.Foreground = $TextBrush
    $tb.FontSize = 14
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = '0,0,0,8'
    $stack.Children.Add($tb) | Out-Null

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = 'A/Insert: agregar otro   Enter: copiar y cerrar   Esc: deshacer ultimo   Inicio: cancelar todo'
    $hint.Foreground = $DimBrush
    $hint.FontSize = 11
    $stack.Children.Add($hint) | Out-Null
}

function Show-Nivel1 {
    $script:Basket.Clear()
    $script:CurrentForce = $null
    $script:State = 'nivel1'
    Draw-Nivel1
}

function Draw-Nivel1 {
    Clear-Root
    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = 300
    $canvas.Height = 340

    $left = New-Object System.Windows.Shapes.Path
    $left.Data = [System.Windows.Media.Geometry]::Parse('M150,10 A140,140 0 0 0 150,290 Z')
    $left.Fill = $BgBrush; $left.Stroke = $AccentBrush; $left.StrokeThickness = 1

    $right = New-Object System.Windows.Shapes.Path
    $right.Data = [System.Windows.Media.Geometry]::Parse('M150,10 A140,140 0 0 1 150,290 Z')
    $right.Fill = $BgBrush; $right.Stroke = $AccentBrush; $right.StrokeThickness = 1

    $holdTab = New-Object System.Windows.Shapes.Rectangle
    $holdTab.Width = 220; $holdTab.Height = 40; $holdTab.RadiusX = 8; $holdTab.RadiusY = 8
    $holdTab.Fill = $BgBrush; $holdTab.Stroke = $AccentBrush; $holdTab.StrokeThickness = 1
    [System.Windows.Controls.Canvas]::SetLeft($holdTab, 40)
    [System.Windows.Controls.Canvas]::SetTop($holdTab, 296)

    $lblF1 = New-Object System.Windows.Controls.TextBlock
    $lblF1.Text = "F1"; $lblF1.Foreground = $TextBrush; $lblF1.FontSize = 22; $lblF1.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetLeft($lblF1, 55); [System.Windows.Controls.Canvas]::SetTop($lblF1, 135)

    $lblF2 = New-Object System.Windows.Controls.TextBlock
    $lblF2.Text = "F2"; $lblF2.Foreground = $TextBrush; $lblF2.FontSize = 22; $lblF2.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetLeft($lblF2, 215); [System.Windows.Controls.Canvas]::SetTop($lblF2, 135)

    $lblHold = New-Object System.Windows.Controls.TextBlock
    $lblHold.Text = "HOLD AT TERM"; $lblHold.Foreground = $TextBrush; $lblHold.FontSize = 13; $lblHold.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetLeft($lblHold, 82); [System.Windows.Controls.Canvas]::SetTop($lblHold, 308)

    $left.Add_MouseLeftButtonUp({ $script:CurrentForce = 'f1'; Enter-IssueMenu })
    $right.Add_MouseLeftButtonUp({ $script:CurrentForce = 'haz'; Enter-IssueMenu })
    $holdTab.Add_MouseLeftButtonUp({ Copy-AndFlash $HoldText })

    $canvas.Children.Add($left) | Out-Null
    $canvas.Children.Add($right) | Out-Null
    $canvas.Children.Add($holdTab) | Out-Null
    $canvas.Children.Add($lblF1) | Out-Null
    $canvas.Children.Add($lblF2) | Out-Null
    $canvas.Children.Add($lblHold) | Out-Null

    $RootGrid.Children.Add($canvas) | Out-Null
}

function Open-Menu {
    if ($Win.Visibility -eq 'Visible') { return }
    $Win.Visibility = 'Visible'
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($Win)).Handle
    [LocalKeyState]::ForceForeground($hwnd)
    $Win.Activate() | Out-Null
    $Win.Focus() | Out-Null
    [System.Windows.Input.Keyboard]::Focus($Win) | Out-Null
    Show-Nivel1

    # Reintento por si el primer foco llego antes de que la ventana terminara
    # de renderizarse (Windows a veces ignora el primer intento).
    $retry = New-Object System.Windows.Threading.DispatcherTimer
    $retry.Interval = [TimeSpan]::FromMilliseconds(120)
    $retry.Add_Tick({
        param($s, $e)
        $s.Stop()
        if ($Win.Visibility -eq 'Visible') {
            $hwnd2 = (New-Object System.Windows.Interop.WindowInteropHelper($Win)).Handle
            [LocalKeyState]::ForceForeground($hwnd2)
            $Win.Activate() | Out-Null
            $Win.Focus() | Out-Null
            [System.Windows.Input.Keyboard]::Focus($Win) | Out-Null
        }
    })
    $retry.Start()
}

# ---------- Dispatcher unico de teclado (registrado una sola vez) ----------

function Handle-KeyDown {
    param($s, $e)

    if ($script:State -eq 'hidden') { return }
    $e.Handled = $true

    if ($script:State -eq 'nivel1') {
        switch ($e.Key) {
            'Left'   { $script:CurrentForce = 'f1';  Enter-IssueMenu }
            'Insert' { $script:CurrentForce = 'f1';  Enter-IssueMenu }
            'D1'     { $script:CurrentForce = 'f1';  Enter-IssueMenu }
            'Right'  { $script:CurrentForce = 'haz'; Enter-IssueMenu }
            'Home'   { $script:CurrentForce = 'haz'; Enter-IssueMenu }
            'D3'     { $script:CurrentForce = 'haz'; Enter-IssueMenu }
            'Down'   { Copy-AndFlash $HoldText }
            'Prior'  { Copy-AndFlash $HoldText }
            'PageUp' { Copy-AndFlash $HoldText }
            'D2'     { Copy-AndFlash $HoldText }
            'Escape' { Close-Menu }
        }
        return
    }

    if ($script:State -eq 'confirm') {
        switch ($e.Key) {
            'A'      { Enter-IssueMenu }
            'Insert' { Enter-IssueMenu }
            'Return' {
                $prefix = if ($script:CurrentForce -eq 'f1') { 'f1' } else { 'haz' }
                Copy-AndFlash ("$prefix-" + ($script:Basket -join ','))
            }
            'Escape' {
                if ($script:Basket.Count -gt 0) { $script:Basket.RemoveAt($script:Basket.Count - 1) }
                Enter-IssueMenu
            }
            'Home'   { Close-Menu }
        }
        return
    }

    # Estados de menu-de-lista: issue, reason-multi-pick, reason, fields, reason-pro, fields-pro
    $result = Process-ListMenuKey $e
    if ($null -eq $result) { return }

    if ($result -is [string] -and $result -eq 'BACK') {
        if ($script:State -eq 'issue') { Show-Nivel1 } else { Enter-IssueMenu }
        return
    }

    switch ($script:State) {
        'issue' {
            $issues = if ($script:CurrentForce -eq 'f1') { $Force1Issues } else { $Force2Issues }
            $script:CurrentIssue = $issues | Where-Object { $_.Label -eq $result }
            switch ($script:CurrentIssue.Sub) {
                'none'         { $script:Basket.Add($script:CurrentIssue.Tag); Enter-Confirm }
                'reason-multi' { Enter-ListMenu $script:CurrentIssue.Label $script:CurrentIssue.SubList $true 'reason-multi-pick' }
                'addr-issue'   { Enter-ListMenu $script:CurrentIssue.Label $RazonesAddrIssue $false 'reason' }
                'pro-sticker'  { Enter-ListMenu $script:CurrentIssue.Label $RazonesProSticker $false 'reason-pro' }
                'badbol-field' { Enter-ListMenu $script:CurrentIssue.Label $script:CurrentIssue.SubList $false 'badbol-field' }
            }
        }
        'reason-multi-pick' {
            $picked = $result
            $tag = if ($picked.Count -eq 0) { $script:CurrentIssue.Tag } else { $script:CurrentIssue.Tag + '-' + ($picked -join ',') }
            $script:Basket.Add($tag); Enter-Confirm
        }
        'reason' {
            if ($result -eq 'address incomplete') {
                Enter-ListMenu "$($script:CurrentIssue.Label) - campo" $Campos $true 'fields'
            } else {
                $script:Basket.Add($script:CurrentIssue.Tag + '-' + $result); Enter-Confirm
            }
        }
        'fields' {
            $fields = $result
            $suffix = if ($fields.Count -gt 0) { $fields -join ',' } else { 'address' }
            $script:Basket.Add($script:CurrentIssue.Tag + '-' + $suffix); Enter-Confirm
        }
        'reason-pro' {
            if ($result -eq 'covering info') {
                Enter-ListMenu "$($script:CurrentIssue.Label) - campo" $Campos $true 'fields-pro'
            } else {
                $script:Basket.Add($script:CurrentIssue.Tag + '-mismatch'); Enter-Confirm
            }
        }
        'fields-pro' {
            $fields = $result
            $suffix = if ($fields.Count -gt 0) { $fields -join ',' } else { 'info' }
            $script:Basket.Add($script:CurrentIssue.Tag + '-' + $suffix); Enter-Confirm
        }
        'badbol-field' {
            if ($result -eq 'missing page') {
                $script:Basket.Add($script:CurrentIssue.Tag + '-missing page'); Enter-Confirm
            } else {
                $script:CurrentField = $result
                Enter-ListMenu "$result - razon" $BadBolReasons $true 'badbol-reason'
            }
        }
        'badbol-reason' {
            $reasons = $result
            $suffix = if ($reasons.Count -gt 0) { $script:CurrentField + '-' + ($reasons -join ',') } else { $script:CurrentField }
            $script:Basket.Add($script:CurrentIssue.Tag + '-' + $suffix); Enter-Confirm
        }
    }
}

$Win.Add_KeyDown({ param($s, $e) Handle-KeyDown $s $e })

# ======================= WIDGET FLOTANTE =======================

$Widget = New-Object System.Windows.Window
$Widget.WindowStyle = 'None'
$Widget.AllowsTransparency = $true
$Widget.Background = 'Transparent'
$Widget.Topmost = $true
$Widget.ShowInTaskbar = $false
$Widget.Width = 42
$Widget.Height = 42
$Widget.ResizeMode = 'NoResize'

$screen = [System.Windows.SystemParameters]::WorkArea
$Widget.Left = $screen.Right - 60
$Widget.Top  = $screen.Bottom - 60

$circle = New-Object System.Windows.Shapes.Ellipse
$circle.Width = 42
$circle.Height = 42
$circle.Fill = $AccentBrush
$circle.Opacity = 0.85
$circle.Add_MouseLeftButtonUp({ Open-Menu })
$Widget.Content = $circle
$Widget.Show()

# ======================= HOTKEY: Supr / Delete (polling local) =======================
# Nota: al ser una sola tecla comun, esto intercepta CUALQUIER Supr en cualquier
# ventana mientras el script corre (no solo en el sistema de trabajo). Si borras
# texto con Supr en otro lado, en vez de borrar te abrira este menu.

$VK_DELETE = 0x2E
$VK_INSERT = 0x2D

$script:HotkeyArmed  = $true
$script:InsertArmed  = $true
$hotkeyTimer = New-Object System.Windows.Threading.DispatcherTimer
$hotkeyTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$hotkeyTimer.Add_Tick({
    $del = ([LocalKeyState]::GetAsyncKeyState($VK_DELETE) -band 0x8000) -ne 0
    if ($del) {
        if ($script:HotkeyArmed) { $script:HotkeyArmed = $false; Open-Menu }
    } else {
        $script:HotkeyArmed = $true
    }

    $ins = ([LocalKeyState]::GetAsyncKeyState($VK_INSERT) -band 0x8000) -ne 0
    if ($ins) {
        if ($script:InsertArmed) {
            $script:InsertArmed = $false
            if ($script:State -eq 'hidden' -and $script:LastCopied) {
                [System.Windows.Clipboard]::SetText($script:LastCopied)
            }
        }
    } else {
        $script:InsertArmed = $true
    }
})
$hotkeyTimer.Start()

$Widget.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

[System.Windows.Threading.Dispatcher]::Run()
