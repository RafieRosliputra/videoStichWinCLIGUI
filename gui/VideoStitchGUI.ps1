<#
.SYNOPSIS
    videoStitchWinCLIGUI - GUI ringkas (WinForms) untuk cantum video.

.DESCRIPTION
    GUI ini BERDIRI SENDIRI:
      - drag-drop banyak fail, susunan = susunan cantuman
      - default susun ikut nama (natural)
      - butang folder target
      - pilihan output: Copy / HEVC / H.264 + tahap kualiti
      - butang Mula: jana arahan CLI, buka tetingkap PowerShell BERASINGAN,
        jalankan job; progress bar dikemas kini dari fail progress
      - GUI boleh ditutup sejurus selepas Mula: job diteruskan oleh proses
        powershell sendiri (detached), bukan oleh GUI.

    Tidak menggunakan XAML/assembly luar. Hanya .NET WinForms yang ada pada
    Windows 11 (PowerShell 5.1). Lihat docs/CARA-FIKIR.md untuk sebab reka bentuk.
#>
param([switch] $SelfTest)   # -SelfTest: semak persekitaran tanpa buka tetingkap

if ($SelfTest) {
    Write-Host 'videoStitch GUI - environment check' -ForegroundColor Cyan
    Write-Host ("PowerShell : {0}" -f $PSVersionTable.PSVersion)
    Write-Host ("Windows    : {0}" -f ([bool]($env:OS -eq 'Windows_NT')))
    $wf = $true
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { $wf = $false }
    Write-Host ("WinForms   : {0}" -f $wf)
    $ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($ff) {
        $ver = (& $ff.Source -version 2>$null | Select-Object -First 1)
        Write-Host ("ffmpeg     : {0} ({1})" -f $ff.Source, $ver) -ForegroundColor Green
    } else { Write-Host 'ffmpeg     : NOT FOUND - winget install -e --id Gyan.FFmpeg' -ForegroundColor Red }
    $base = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { Split-Path -Parent ([Environment]::GetCommandLineArgs()[0]) }
    $cli = Join-Path $base 'bin\stitch.ps1'
    if (-not (Test-Path -LiteralPath $cli)) { $cli = Join-Path $base 'bin/stitch.ps1' }
    Write-Host ("CLI        : {0} ({1})" -f $cli, (Test-Path -LiteralPath $cli))
    $tmp = [IO.Path]::GetTempPath()
    $w = $true
    try { $f = Join-Path $tmp '.vs-write-test'; Set-Content -LiteralPath $f 'x'; Remove-Item -LiteralPath $f -Force } catch { $w = $false }
    Write-Host ("TEMP write : {0} ({1})" -f $w, $tmp)
    if ($wf -and $ff -and $w) { Write-Host 'STATUS: ready' -ForegroundColor Green; exit 0 }
    Write-Host 'STATUS: issues above' -ForegroundColor Yellow
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --------------------------------------------------------------- utiliti ----

function Compare-Natural {
    param([string] $A, [string] $B)
    $ta = [regex]::Matches($A, '\d+|\D+') | ForEach-Object { $_.Value }
    $tb = [regex]::Matches($B, '\d+|\D+') | ForEach-Object { $_.Value }
    $n = [Math]::Max($ta.Count, $tb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -ge $ta.Count) { return -1 }
        if ($i -ge $tb.Count) { return 1 }
        $x = $ta[$i]; $y = $tb[$i]
        $nx = 0L; $ny = 0L
        if ([int64]::TryParse($x, [ref] $nx) -and [int64]::TryParse($y, [ref] $ny)) {
            if ($nx -lt $ny) { return -1 }
            if ($nx -gt $ny) { return 1 }
            continue
        }
        $c = [string]::Compare($x.ToLowerInvariant(), $y.ToLowerInvariant(), [StringComparison]::Ordinal)
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    $c2 = [string]::Compare($A, $B, [StringComparison]::Ordinal)
    return [Math]::Sign($c2)
}

function Sort-FilesNatural {
    param([string[]] $Paths)
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Paths) { [void] $list.Add($p) }
    $list.Sort([System.Comparison[string]] { param($a, $b) Compare-Natural -A (Split-Path -Leaf $a) -B (Split-Path -Leaf $b) })
    return , $list.ToArray()
}

function Test-VideoFile {
    param([string] $p)
    $ext = [IO.Path]::GetExtension($p).ToLowerInvariant()
    return $ext -in @('.mp4', '.mov', '.mkv', '.m4v', '.avi', '.ts', '.mts', '.m2ts', '.webm', '.wmv', '.flv', '.mpg', '.mpeg')
}

function Get-FFmpegPath {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe",
                     'C:\ProgramData\chocolatey\bin\ffmpeg.exe',
                     "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Install-FFmpeg {
    # Opt-in: tanya dulu. Tidak memasang senyap.
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "ffmpeg was not found.`n`nInstall it now with winget (Gyan.FFmpeg)?`n`nA PowerShell window will open to run the install.",
        'ffmpeg missing', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show('winget is not available. Install "App Installer" from the Microsoft Store first.', 'winget missing', 'OK', 'Warning') | Out-Null
        return
    }
    $arg = '-NoLogo -NoProfile -NoExit -Command "winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements"'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arg | Out-Null
    [System.Windows.Forms.MessageBox]::Show('Install window opened. When it finishes, press Run again.', 'Installing ffmpeg', 'OK', 'Information') | Out-Null
}

function Quote-PS { param([string] $s) return "'" + $s.Replace("'", "''") + "'" }

# --------------------------------------------------------------- keadaan ----

# Cari folder repo/instalasi. Bila dikompil jadi .exe (ps2exe), $PSScriptRoot
# menunjuk ke folder sementara - jadi turutan carian bermula dari exe/ENV.
function Get-BaseDir {
    # $PSScriptRoot KOSONG bila dikompil jadi exe (ps2exe) - jangan Split-Path
    # pada nilai kosong (itu punca "Cannot bind argument to parameter 'Path'").
    $candidates = @()
    if ($env:VIDEOSTITCH_ROOT) { $candidates += $env:VIDEOSTITCH_ROOT }
    if ($PSScriptRoot) { $candidates += (Split-Path -Parent $PSScriptRoot) }
    try {
        $exe = [Environment]::GetCommandLineArgs()[0]
        if ($exe) { $candidates += (Split-Path -Parent $exe) }
    }
    catch { }
    try { $candidates += (Get-Location).Path } catch { }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (Test-Path -LiteralPath (Join-Path $c 'bin\stitch.ps1')) { return $c }
    }
    foreach ($c in $candidates) { if ($c) { return $c } }
    return $null
}
$script:RepoRoot = Get-BaseDir
if (-not $script:RepoRoot) {
    [System.Windows.Forms.MessageBox]::Show("Cannot locate the videoStitch folder (bin\stitch.ps1).`n`nSet %VIDEOSTITCH_ROOT% or run Setup again.", 'videoStitch', 'OK', 'Error') | Out-Null
    exit 1
}
$script:CliPath  = Join-Path $script:RepoRoot 'bin\stitch.ps1'
$script:Files    = [System.Collections.Generic.List[string]]::new()
$script:JobDir   = $null
$script:Running  = $false
$script:Total    = 0.0
$script:Timer    = New-Object System.Windows.Forms.Timer

$script:Modes = @(
    [pscustomobject]@{ Label = 'Copy (no re-encode, fastest)'; Value = 'copy' },
    [pscustomobject]@{ Label = 'HEVC / H.265 (x265)';              Value = 'hevc' },
    [pscustomobject]@{ Label = 'H.264 (x264, fallback)';           Value = 'h264' }
)
# Senarai pilihan enkoder/gpu - dikesan pada mesin ini bila GUI dibuka.
$script:Encoders = [System.Collections.Generic.List[object]]::new()
$script:Encoders.Add([pscustomobject]@{ Label = 'Auto (GPU kalau ada)'; Kind = 'auto'; Device = 0 })
$detected = @()
try {
    $nv = @()
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $nv = @(& nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Where-Object { $_ -and $_.Trim() })
    }
    for ($i = 0; $i -lt $nv.Count; $i++) {
        $script:Encoders.Add([pscustomobject]@{ Label = ("GPU: {0} (NVENC)" -f $nv[$i].Trim()); Kind = 'nvenc'; Device = $i })
        $detected += $nv[$i].Trim()
    }
    foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        if ($v.Name -match 'Intel' -and -not ($script:Encoders | Where-Object { $_.Kind -eq 'qsv' })) {
            $script:Encoders.Add([pscustomobject]@{ Label = ("GPU: {0} (QSV)" -f $v.Name); Kind = 'qsv'; Device = 0 })
            $detected += $v.Name
        }
        elseif ($v.Name -match 'AMD|Radeon' -and -not ($script:Encoders | Where-Object { $_.Kind -eq 'amf' })) {
            $script:Encoders.Add([pscustomobject]@{ Label = ("GPU: {0} (AMF)" -f $v.Name); Kind = 'amf'; Device = 0 })
            $detected += $v.Name
        }
    }
}
catch { }
if (-not ($script:Encoders | Where-Object { $_.Kind -eq 'nvenc' })) {
    $script:Encoders.Add([pscustomobject]@{ Label = 'GPU: NVIDIA (NVENC)'; Kind = 'nvenc'; Device = 0 })
}
if (-not ($script:Encoders | Where-Object { $_.Kind -eq 'qsv' })) {
    $script:Encoders.Add([pscustomobject]@{ Label = 'GPU: Intel (QSV)'; Kind = 'qsv'; Device = 0 })
}
$script:Encoders.Add([pscustomobject]@{ Label = 'CPU (x265/x264)'; Kind = 'cpu'; Device = 0 })
$script:DetectedGpu = ($detected -join ', ')

$script:FpsOptions = @(
    [pscustomobject]@{ Label = 'Auto fps'; Value = 0 },
    [pscustomobject]@{ Label = '23.976';   Value = 23.976 },
    [pscustomobject]@{ Label = '24';       Value = 24 },
    [pscustomobject]@{ Label = '25';       Value = 25 },
    [pscustomobject]@{ Label = '29.97';    Value = 29.97 },
    [pscustomobject]@{ Label = '30';       Value = 30 },
    [pscustomobject]@{ Label = '50';       Value = 50 },
    [pscustomobject]@{ Label = '59.94';    Value = 59.94 },
    [pscustomobject]@{ Label = '60';       Value = 60 }
)
$script:Qualities = @(
    [pscustomobject]@{ Label = 'High (CRF 20)';      Value = 'high' },
    [pscustomobject]@{ Label = 'Balanced (CRF 23)';  Value = 'balanced' },
    [pscustomobject]@{ Label = 'Small (CRF 28)';     Value = 'small' }
)

# --------------------------------------------------------------- kawalan ----

$form = New-Object System.Windows.Forms.Form
$form.Text = 'videoStitch v0.2.2 - video stitcher (Windows)'
$form.Size = New-Object System.Drawing.Size(1040, 760)
$form.MinimumSize = New-Object System.Drawing.Size(880, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AllowDrop = $true

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = 'Drag & drop video files here. List order = stitch order.'
$lblHint.Location = New-Object System.Drawing.Point(12, 10)
$lblHint.Size = New-Object System.Drawing.Size(760, 20)
$form.Controls.Add($lblHint)

$list = New-Object System.Windows.Forms.ListBox
$list.Location = New-Object System.Drawing.Point(12, 34)
$list.Size = New-Object System.Drawing.Size(700, 300)
$list.SelectionMode = 'MultiExtended'
$list.AllowDrop = $true
$list.HorizontalScrollbar = $true
$list.IntegralHeight = $false
$form.Controls.Add($list)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = 'Add files...'
$btnAdd.Location = New-Object System.Drawing.Point(724, 34)
$btnAdd.Size = New-Object System.Drawing.Size(292, 30)
$form.Controls.Add($btnAdd)

$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = 'Up'
$btnUp.Location = New-Object System.Drawing.Point(724, 70)
$btnUp.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($btnUp)

$btnDown = New-Object System.Windows.Forms.Button
$btnDown.Text = 'Down'
$btnDown.Location = New-Object System.Drawing.Point(800, 70)
$btnDown.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($btnDown)

$btnDel = New-Object System.Windows.Forms.Button
$btnDel.Text = 'Remove'
$btnDel.Location = New-Object System.Drawing.Point(876, 70)
$btnDel.Size = New-Object System.Drawing.Size(60, 28)
$form.Controls.Add($btnDel)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear'
$btnClear.Location = New-Object System.Drawing.Point(942, 70)
$btnClear.Size = New-Object System.Drawing.Size(74, 28)
$form.Controls.Add($btnClear)

$btnSort = New-Object System.Windows.Forms.Button
$btnSort.Text = 'Sort by name'
$btnSort.Location = New-Object System.Drawing.Point(724, 104)
$btnSort.Size = New-Object System.Drawing.Size(292, 28)
$form.Controls.Add($btnSort)

$grpOut = New-Object System.Windows.Forms.GroupBox
$grpOut.Text = 'Output'
$grpOut.Location = New-Object System.Drawing.Point(12, 344)
$grpOut.Size = New-Object System.Drawing.Size(1004, 64)
$form.Controls.Add($grpOut)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(10, 24)
$txtOut.Size = New-Object System.Drawing.Size(760, 24)
$grpOut.Controls.Add($txtOut)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = 'Output folder...'
$btnFolder.Location = New-Object System.Drawing.Point(778, 22)
$btnFolder.Size = New-Object System.Drawing.Size(110, 28)
$grpOut.Controls.Add($btnFolder)

$btnName = New-Object System.Windows.Forms.Button
$btnName.Text = 'File name...'
$btnName.Location = New-Object System.Drawing.Point(894, 22)
$btnName.Size = New-Object System.Drawing.Size(100, 28)
$grpOut.Controls.Add($btnName)

$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = 'Mode & quality'
$grpMode.Location = New-Object System.Drawing.Point(12, 414)
$grpMode.Size = New-Object System.Drawing.Size(1004, 64)
$form.Controls.Add($grpMode)

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.DropDownStyle = 'DropDownList'
$cmbMode.Location = New-Object System.Drawing.Point(10, 24)
$cmbMode.Size = New-Object System.Drawing.Size(200, 24)
foreach ($m in $script:Modes) { [void] $cmbMode.Items.Add($m.Label) }
$cmbMode.SelectedIndex = 0
$grpMode.Controls.Add($cmbMode)

$cmbQuality = New-Object System.Windows.Forms.ComboBox
$cmbQuality.DropDownStyle = 'DropDownList'
$cmbQuality.Location = New-Object System.Drawing.Point(214, 24)
$cmbQuality.Size = New-Object System.Drawing.Size(140, 24)
foreach ($q in $script:Qualities) { [void] $cmbQuality.Items.Add($q.Label) }
$cmbQuality.SelectedIndex = 1
$grpMode.Controls.Add($cmbQuality)

$cmbPreset = New-Object System.Windows.Forms.ComboBox
$cmbPreset.DropDownStyle = 'DropDownList'
$cmbPreset.Location = New-Object System.Drawing.Point(358, 24)
$cmbPreset.Size = New-Object System.Drawing.Size(100, 24)
foreach ($p in @('veryfast', 'medium', 'slow')) { [void] $cmbPreset.Items.Add($p) }
$cmbPreset.SelectedIndex = 1
$grpMode.Controls.Add($cmbPreset)

$cmbEncoder = New-Object System.Windows.Forms.ComboBox
$cmbEncoder.DropDownStyle = 'DropDownList'
$cmbEncoder.Location = New-Object System.Drawing.Point(462, 24)
$cmbEncoder.Size = New-Object System.Drawing.Size(170, 24)
foreach ($e in $script:Encoders) { [void] $cmbEncoder.Items.Add($e.Label) }
$cmbEncoder.SelectedIndex = 0
$grpMode.Controls.Add($cmbEncoder)

$cmbFps = New-Object System.Windows.Forms.ComboBox
$cmbFps.DropDownStyle = 'DropDownList'
$cmbFps.Location = New-Object System.Drawing.Point(636, 24)
$cmbFps.Size = New-Object System.Drawing.Size(90, 24)
foreach ($fp in $script:FpsOptions) { [void] $cmbFps.Items.Add($fp.Label) }
$cmbFps.SelectedIndex = 0
$grpMode.Controls.Add($cmbFps)

$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Location = New-Object System.Drawing.Point(734, 27)
$lblNote.Size = New-Object System.Drawing.Size(260, 22)
$lblNote.ForeColor = [System.Drawing.Color]::DimGray
$lblNote.Text = 'Quality/preset apply when encoding only.'
$grpMode.Controls.Add($lblNote)

$lblCmd = New-Object System.Windows.Forms.Label
$lblCmd.Text = 'CLI command (copy & run it yourself)'
$lblCmd.Location = New-Object System.Drawing.Point(12, 486)
$lblCmd.Size = New-Object System.Drawing.Size(400, 20)
$form.Controls.Add($lblCmd)

$txtCmd = New-Object System.Windows.Forms.TextBox
$txtCmd.Location = New-Object System.Drawing.Point(12, 508)
$txtCmd.Size = New-Object System.Drawing.Size(1004, 60)
$txtCmd.Multiline = $true
$txtCmd.ReadOnly = $true
$txtCmd.ScrollBars = 'Vertical'
$txtCmd.Font = New-Object System.Drawing.Font('Consolas', 8)
$txtCmd.BackColor = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($txtCmd)

$btnCmd = New-Object System.Windows.Forms.Button
$btnCmd.Text = 'Build command'
$btnCmd.Location = New-Object System.Drawing.Point(12, 574)
$btnCmd.Size = New-Object System.Drawing.Size(130, 30)
$form.Controls.Add($btnCmd)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Run  (open PowerShell & start)'
$btnRun.Location = New-Object System.Drawing.Point(150, 574)
$btnRun.Size = New-Object System.Drawing.Size(300, 30)
$btnRun.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnRun)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = 'Open job folder'
$btnLog.Location = New-Object System.Drawing.Point(458, 574)
$btnLog.Size = New-Object System.Drawing.Size(150, 30)
$btnLog.Enabled = $false
$form.Controls.Add($btnLog)

$prg = New-Object System.Windows.Forms.ProgressBar
$prg.Location = New-Object System.Drawing.Point(12, 616)
$prg.Size = New-Object System.Drawing.Size(1004, 22)
$prg.Minimum = 0
$prg.Maximum = 1000
$prg.Style = 'Continuous'
$form.Controls.Add($prg)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 646)
$lblStatus.Size = New-Object System.Drawing.Size(1004, 22)
$lblStatus.Text = 'Ready.'
$form.Controls.Add($lblStatus)

$lblFoot = New-Object System.Windows.Forms.Label
$lblFoot.Location = New-Object System.Drawing.Point(12, 672)
$lblFoot.Size = New-Object System.Drawing.Size(1004, 40)
$lblFoot.ForeColor = [System.Drawing.Color]::DimGray
$lblFoot.Text = 'You can close this window after pressing Run; the job keeps running in its own PowerShell window. Job logs: %TEMP%\VideoStitch.'
$form.Controls.Add($lblFoot)

# ---------------------------------------------------------------- fungsi ----

function Update-List {
    $sel = @()
    foreach ($i in $list.SelectedIndices) { $sel += [int] $i }
    $list.BeginUpdate()
    $list.Items.Clear()
    for ($i = 0; $i -lt $script:Files.Count; $i++) {
        [void] $list.Items.Add(('{0,3}. {1}' -f ($i + 1), (Split-Path -Leaf $script:Files[$i])))
    }
    $list.EndUpdate()
    foreach ($i in $sel) { if ($i -lt $list.Items.Count) { $list.SetSelected($i, $true) } }
}

function Add-FilesTo-List {
    param([string[]] $Paths)
    $added = 0
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (-not (Test-VideoFile $p)) { continue }
        $full = (Resolve-Path -LiteralPath $p).Path
        # jangan masukkan fail output semasa sebagai input
        if ($txtOut.Text.Trim() -and $full -eq $txtOut.Text.Trim()) { continue }
        if (-not $script:Files.Contains($full)) { [void] $script:Files.Add($full); $added++ }
    }
    if ($added -gt 0) {
        $script:Files = [System.Collections.Generic.List[string]]::new([string[]] (Sort-FilesNatural -Paths $script:Files.ToArray()))
        Update-List
        $lblStatus.Text = "Added $added file(s). Total: $($script:Files.Count)."
        if (-not $txtOut.Text.Trim()) {
            $dir = Split-Path -Parent $script:Files[0]
            $txtOut.Text = Join-Path $dir 'out.mp4'
        }
    }
}

function Get-Mode { $script:Modes[$cmbMode.SelectedIndex].Value }
function Get-Quality { $script:Qualities[$cmbQuality.SelectedIndex].Value }
function Get-Encoder { return $script:Encoders[$cmbEncoder.SelectedIndex] }
function Get-Fps { return [double] $script:FpsOptions[$cmbFps.SelectedIndex].Value }

function Get-CliArgs {
    param([string[]] $Files, [string] $Out)
    $parts = @('-Files')
    $parts += (($Files | ForEach-Object { Quote-PS $_ }) -join ',')
    $parts += @('-Out', (Quote-PS $Out), '-Mode', (Get-Mode))
    if ((Get-Mode) -ne 'copy') {
        $enc = Get-Encoder
        $parts += @('-Quality', (Get-Quality), '-Encoder', $enc.Kind)
        if ($enc.Kind -eq 'nvenc') { $parts += @('-GpuDevice', "$($enc.Device)") }
        $parts += @('-Preset', $cmbPreset.SelectedItem.ToString())
        $fps = Get-Fps
        if ($fps -gt 0) { $parts += @('-Fps', $fps.ToString([Globalization.CultureInfo]::InvariantCulture)) }
    }
    if ($script:Running -and $script:JobDir) {
        $parts += @('-Progress', (Quote-PS (Join-Path $script:JobDir 'ffprogress.txt')))
        $parts += @('-Log',      (Quote-PS (Join-Path $script:JobDir 'ffmpeg.log')))
        $parts += @('-State',    (Quote-PS (Join-Path $script:JobDir 'state.txt')))
    }
    return $parts
}

function Get-CommandPreview {
    if ($script:Files.Count -eq 0) { return '(no files)' }
    $out = if ($txtOut.Text.Trim()) { $txtOut.Text.Trim() } else { 'out.mp4' }
    $a = (Get-CliArgs -Files $script:Files.ToArray() -Out $out) -join ' '
    return "& '$script:CliPath' $a"
}

function Update-Preview { $txtCmd.Text = Get-CommandPreview }

function Get-StateFile {
    param([string] $Path)
    $h = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
            if ($line -match '^([A-Z_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
            elseif ($line -match '^ERROR (.*)$') { $h['STATUS'] = 'ERROR'; $h['DETAIL'] = $Matches[1] }
        }
    }
    return $h
}

function Get-ProgressPercent {
    param([string] $ProgressPath, [double] $Total)
    if ($Total -le 0 -or -not (Test-Path -LiteralPath $ProgressPath)) { return 0 }
    $m = Select-String -LiteralPath $ProgressPath -Pattern '^out_time_us=(\d+)$' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if (-not $m) { return 0 }
    $us = [int64] $m.Matches[0].Groups[1].Value
    return [Math]::Min(100, ($us / 1000000) / $Total * 100)
}

# ---------------------------------------------------------------- events ----

$onDragEnter = {
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' }
    else { $e.Effect = 'None' }
}
$onDragDrop = {
    param($s, $e)
    $paths = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    $dirs = @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $files = @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    foreach ($d in $dirs) { $files += @(Get-ChildItem -LiteralPath $d -File | Where-Object { Test-VideoFile $_.FullName } | ForEach-Object { $_.FullName }) }
    if ($files.Count -eq 0) { return }
    Add-FilesTo-List -Paths $files
    Update-Preview
}
$list.Add_DragEnter($onDragEnter)
$list.Add_DragDrop($onDragDrop)
$form.Add_DragEnter($onDragEnter)
$form.Add_DragDrop($onDragDrop)

$btnAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Video|*.mp4;*.mov;*.mkv;*.m4v;*.avi;*.ts;*.m2ts;*.webm;*.wmv;*.flv;*.mpg;*.mpeg|All files|*.*'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq 'OK') { Add-FilesTo-List -Paths $dlg.FileNames; Update-Preview }
})

$btnUp.Add_Click({
    $idxs = @($list.SelectedIndices | Sort-Object)
    if ($idxs.Count -eq 0) { return }
    foreach ($i in $idxs) {
        if ($i -le 0) { continue }
        if ($idxs -contains ($i - 1)) { continue }
        $tmp = $script:Files[$i - 1]; $script:Files[$i - 1] = $script:Files[$i]; $script:Files[$i] = $tmp
    }
    Update-List
    foreach ($i in $idxs) { if ($i -gt 0) { $list.SetSelected($i - 1, $true) } }
    Update-Preview
})

$btnDown.Add_Click({
    $idxs = @($list.SelectedIndices | Sort-Object -Descending)
    if ($idxs.Count -eq 0) { return }
    foreach ($i in $idxs) {
        if ($i -ge $script:Files.Count - 1) { continue }
        if ($idxs -contains ($i + 1)) { continue }
        $tmp = $script:Files[$i + 1]; $script:Files[$i + 1] = $script:Files[$i]; $script:Files[$i] = $tmp
    }
    Update-List
    foreach ($i in $idxs) { if ($i -lt $list.Items.Count - 1) { $list.SetSelected($i + 1, $true) } }
    Update-Preview
})

$btnDel.Add_Click({
    $idxs = @($list.SelectedIndices | Sort-Object -Descending)
    foreach ($i in $idxs) { $script:Files.RemoveAt($i) }
    Update-List; Update-Preview
})

$btnClear.Add_Click({ $script:Files.Clear(); Update-List; Update-Preview; $lblStatus.Text = 'List cleared.' })

$btnSort.Add_Click({
    $script:Files = [System.Collections.Generic.List[string]]::new([string[]] (Sort-FilesNatural -Paths $script:Files.ToArray()))
    Update-List; Update-Preview; $lblStatus.Text = 'Sorted by name (natural).'
})

$btnFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select output folder'
    if ($dlg.ShowDialog() -eq 'OK') {
        $name = 'out.mp4'
        if ($txtOut.Text.Trim()) { $name = Split-Path -Leaf $txtOut.Text.Trim() }
        if (-not $name) { $name = 'out.mp4' }
        $txtOut.Text = Join-Path $dlg.SelectedPath $name
        Update-Preview
    }
})

$btnName.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'MP4|*.mp4|All files|*.*'
    $dlg.FileName = 'out.mp4'
    if ($txtOut.Text.Trim()) { $dlg.InitialDirectory = Split-Path -Parent $txtOut.Text.Trim(); $dlg.FileName = Split-Path -Leaf $txtOut.Text.Trim() }
    if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.FileName; Update-Preview }
})

$cmbMode.Add_SelectedIndexChanged({
    $isCopy = (Get-Mode) -eq 'copy'
    $cmbQuality.Enabled = -not $isCopy
    $cmbPreset.Enabled = -not $isCopy
    $lblNote.Text = if ($isCopy) { 'Copy: all clips must share codec/resolution/fps.' } else { 'Quality/preset apply when encoding only.' }
    Update-Preview
})
$cmbQuality.Add_SelectedIndexChanged({ Update-Preview })
$cmbPreset.Add_SelectedIndexChanged({ Update-Preview })
$cmbFps.Add_SelectedIndexChanged({ Update-Preview })
$cmbEncoder.Add_SelectedIndexChanged({
    $encSel = Get-Encoder
    $lblNote.Text = if ($encSel.Kind -eq 'cpu') { 'CPU: most compatible, slowest.' }
                    elseif ($encSel.Kind -eq 'auto') { 'Auto: try GPU, fall back to CPU.' }
                    else { 'GPU: fast; quality via CQ/bitrate.' }
    Update-Preview
})
$txtOut.Add_TextChanged({ Update-Preview })

$btnCmd.Add_Click({ Update-Preview; $lblStatus.Text = 'Command generated (see the command box).' })

$btnLog.Add_Click({ if ($script:JobDir -and (Test-Path -LiteralPath $script:JobDir)) { Start-Process explorer.exe -ArgumentList ("`"{0}`"" -f $script:JobDir) } })

# ------------------------------------------------------------------- Mula ----

$btnRun.Add_Click({
    try {
        if ($script:Files.Count -lt 1) { throw 'Add at least one video file.' }

        $missing = @($script:Files | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missing.Count -gt 0) {
            $names = ($missing | ForEach-Object { Split-Path -Leaf $_ }) -join "`n"
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "These files are missing:`n`n$names`n`nRemove them from the list and continue?",
                'Missing files', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { $script:Running = $false; $lblStatus.Text = 'Cancelled: missing files.'; return }
            foreach ($m in $missing) { [void] $script:Files.Remove($m) }
            Update-List
            Update-Preview
            if ($script:Files.Count -lt 1) { throw 'No files left after removing the missing ones.' }
        }

        $out = $txtOut.Text.Trim()
        if (-not $out) { throw 'Set an output folder / file name first.' }
        if (-not $out.ToLowerInvariant().EndsWith('.mp4')) { $out += '.mp4'; $txtOut.Text = $out }
        if ($script:Files -contains $out) { throw 'The output file is also in the input list. Remove it first.' }
        if ((Get-Mode) -eq 'copy' -and (Get-Fps) -gt 0) {
            throw 'Copy mode cannot change frame rate. Switch Mode to HEVC or H.264, or set fps back to Auto.'
        }
        $outDir = Split-Path -Parent $out
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

        if (-not (Test-Path -LiteralPath $script:CliPath)) { throw "CLI not found: $script:CliPath" }
        $ff = Get-FFmpegPath
        if (-not $ff) {
            Install-FFmpeg
            $script:Running = $false
            $lblStatus.Text = 'ffmpeg is still missing. Install it, then press Run again.'
            return
        }

        # folder job berasingan setiap run
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:JobDir = Join-Path $env:TEMP ("VideoStitch\{0}-{1}" -f $stamp, ([guid]::NewGuid().ToString('N').Substring(0, 6)))
        New-Item -ItemType Directory -Force -Path $script:JobDir | Out-Null

        $script:Running = $true
        $argsLine = (Get-CliArgs -Files $script:Files.ToArray() -Out $out) -join ' '
        $jobFile = Join-Path $script:JobDir 'job.ps1'

        $jobBody = @"
# Job dijana oleh videoStitch GUI - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
`$ErrorActionPreference = 'Continue'
& '$script:CliPath' $argsLine
`$code = `$LASTEXITCODE
Write-Host ''
if (`$code -ne 0) { Write-Host "Job FAILED (rc=`$code). Log: $($script:JobDir)\ffmpeg.log" -ForegroundColor Red }
else { Write-Host "Job DONE: $out" -ForegroundColor Green }
# 'exit' dalam skrip yang dipanggil (&) hanya tamatkan skrip itu, bukan sesi -
# jadi exit code mesti dihantar secara eksplisit.
exit `$code
"@
        [System.IO.File]::WriteAllText($jobFile, $jobBody, [System.Text.UTF8Encoding]::new($true))

        $txtCmd.Text = Get-CommandPreview
        $prg.Value = 0
        $lblStatus.Text = 'Starting job in a new PowerShell window...'

        $psArgs = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $jobFile
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WorkingDirectory $script:JobDir | Out-Null

        $btnLog.Enabled = $true
        $script:Timer.Start()
    }
    catch {
        $script:Running = $false
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Warning') | Out-Null
        $lblStatus.Text = 'Error: ' + $_.Exception.Message
    }
})

$script:Timer.Interval = 400
$script:Timer.Add_Tick({
    if (-not $script:Running -or -not $script:JobDir) { return }
    $state = Get-StateFile -Path (Join-Path $script:JobDir 'state.txt')
    if ($state.ContainsKey('TOTAL')) { $script:Total = [double] $state['TOTAL'] }
    $pct = Get-ProgressPercent -ProgressPath (Join-Path $script:JobDir 'ffprogress.txt') -Total $script:Total
    if ($pct -gt 0) { $prg.Value = [int]($pct * 10) }
    $st = if ($state.ContainsKey('STATUS')) { $state['STATUS'] } else { 'PROBE' }
    switch ($st) {
        'PROBE'   { $lblStatus.Text = 'Probing clips...' }
        'RUNNING' { $lblStatus.Text = ('Working... {0:0.0}%  (you can close this window)' -f $pct) }
        'DONE'    {
            $script:Running = $false
            $script:Timer.Stop()
            $prg.Value = 1000
            $lblStatus.Text = 'Done. File: ' + $txtOut.Text
        }
        'ERROR'   {
            $script:Running = $false
            $script:Timer.Stop()
            $lblStatus.Text = 'Error: ' + ($(if ($state.ContainsKey('DETAIL')) { $state['DETAIL'] } else { 'see the PowerShell window' }))
        }
    }
})

$form.Add_FormClosing({ $script:Timer.Stop(); $script:Timer.Dispose() })

$cmbMode.SelectedIndex = 0
$script:EngineVersion = ''
$verFile = Join-Path $script:RepoRoot 'version.txt'
if (Test-Path -LiteralPath $verFile) {
    try { $script:EngineVersion = (Get-Content -LiteralPath $verFile -Raw).Trim() } catch { }
}
if ($script:EngineVersion) {
    $lblStatus.Text = "Engine v$($script:EngineVersion)" + $(if ($script:DetectedGpu) { "  |  GPU detected: $($script:DetectedGpu)" } else { "" })
}
elseif ($script:DetectedGpu) { $lblStatus.Text = "GPU detected: $($script:DetectedGpu)" }
Update-Preview

try {
    [void] $form.ShowDialog()
}
catch {
    # Konsol disembunyikan oleh gui.cmd; jadi ralat mesti ke fail + dialog.
    $log = Join-Path ([IO.Path]::GetTempPath()) 'VideoStitch-gui-error.log'
    $msg = "GUI failed to start.`n`n$($_.Exception.Message)`n`nLog: $log"
    try {
        $detail = "videoStitch GUI error`n$(Get-Date -Format o)`nPS $($PSVersionTable.PSVersion)`n`n$($_ | Out-String)`n$($_.ScriptStackTrace)"
        [System.IO.File]::WriteAllText($log, $detail)
    }
    catch { }
    [System.Windows.Forms.MessageBox]::Show($msg, 'videoStitch', 'OK', 'Error') | Out-Null
}
