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
    Write-Host 'videoStitch GUI - semakan persekitaran' -ForegroundColor Cyan
    Write-Host ("PowerShell : {0}" -f $PSVersionTable.PSVersion)
    Write-Host ("Windows    : {0}" -f ([bool]($env:OS -eq 'Windows_NT')))
    $wf = $true
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { $wf = $false }
    Write-Host ("WinForms   : {0}" -f $wf)
    $ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($ff) {
        $ver = (& $ff.Source -version 2>$null | Select-Object -First 1)
        Write-Host ("ffmpeg     : {0} ({1})" -f $ff.Source, $ver) -ForegroundColor Green
    } else { Write-Host 'ffmpeg     : TIDAK DIJUMPAI - winget install -e --id Gyan.FFmpeg' -ForegroundColor Red }
    $cli = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\stitch.ps1'
    if (-not (Test-Path -LiteralPath $cli)) { $cli = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/stitch.ps1' }
    Write-Host ("CLI        : {0} ({1})" -f $cli, (Test-Path -LiteralPath $cli))
    $tmp = [IO.Path]::GetTempPath()
    $w = $true
    try { $f = Join-Path $tmp '.vs-write-test'; Set-Content -LiteralPath $f 'x'; Remove-Item -LiteralPath $f -Force } catch { $w = $false }
    Write-Host ("TEMP tulis : {0} ({1})" -f $w, $tmp)
    if ($wf -and $ff -and $w) { Write-Host 'STATUS: sedia' -ForegroundColor Green; exit 0 }
    Write-Host 'STATUS: ada masalah di atas' -ForegroundColor Yellow
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

function Quote-PS { param([string] $s) return "'" + $s.Replace("'", "''") + "'" }

# --------------------------------------------------------------- keadaan ----

$script:RepoRoot = Split-Path -Parent $PSScriptRoot          # .../videoStichWinCLIGUI
$script:CliPath  = Join-Path $script:RepoRoot 'bin\stitch.ps1'
$script:Files    = [System.Collections.Generic.List[string]]::new()
$script:JobDir   = $null
$script:Running  = $false
$script:Total    = 0.0
$script:Timer    = New-Object System.Windows.Forms.Timer

$script:Modes = @(
    [pscustomobject]@{ Label = 'Copy (sifar encode, paling laju)'; Value = 'copy' },
    [pscustomobject]@{ Label = 'HEVC / H.265 (x265)';              Value = 'hevc' },
    [pscustomobject]@{ Label = 'H.264 (x264, fallback)';           Value = 'h264' }
)
$script:Qualities = @(
    [pscustomobject]@{ Label = 'Tinggi (CRF 20)';    Value = 'high' },
    [pscustomobject]@{ Label = 'Seimbang (CRF 23)';  Value = 'balanced' },
    [pscustomobject]@{ Label = 'Kecil (CRF 28)';     Value = 'small' }
)

# --------------------------------------------------------------- kawalan ----

$form = New-Object System.Windows.Forms.Form
$form.Text = 'videoStitch - cantum video (Windows)'
$form.Size = New-Object System.Drawing.Size(1040, 760)
$form.MinimumSize = New-Object System.Drawing.Size(880, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AllowDrop = $true

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = 'Lepas (drag & drop) fail video di sini. Susunan senarai = susunan cantuman.'
$lblHint.Location = New-Object System.Drawing.Point(12, 10)
$lblHint.Size = New-Object System.Drawing.Size(760, 20)
$form.Controls.Add($lblHint)

$list = New-Object System.Windows.Forms.ListBox
$list.Location = New-Object System.Drawing.Point(12, 34)
$list.Size = New-Object System.Drawing.Size(700, 300)
$list.SelectionMode = 'Extended'
$list.AllowDrop = $true
$list.HorizontalScrollbar = $true
$list.IntegralHeight = $false
$form.Controls.Add($list)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = 'Tambah fail...'
$btnAdd.Location = New-Object System.Drawing.Point(724, 34)
$btnAdd.Size = New-Object System.Drawing.Size(292, 30)
$form.Controls.Add($btnAdd)

$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = 'Naik'
$btnUp.Location = New-Object System.Drawing.Point(724, 70)
$btnUp.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($btnUp)

$btnDown = New-Object System.Windows.Forms.Button
$btnDown.Text = 'Turun'
$btnDown.Location = New-Object System.Drawing.Point(800, 70)
$btnDown.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($btnDown)

$btnDel = New-Object System.Windows.Forms.Button
$btnDel.Text = 'Buang'
$btnDel.Location = New-Object System.Drawing.Point(876, 70)
$btnDel.Size = New-Object System.Drawing.Size(60, 28)
$form.Controls.Add($btnDel)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Kosong'
$btnClear.Location = New-Object System.Drawing.Point(942, 70)
$btnClear.Size = New-Object System.Drawing.Size(74, 28)
$form.Controls.Add($btnClear)

$btnSort = New-Object System.Windows.Forms.Button
$btnSort.Text = 'Susun ikut nama'
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
$btnFolder.Text = 'Folder target...'
$btnFolder.Location = New-Object System.Drawing.Point(778, 22)
$btnFolder.Size = New-Object System.Drawing.Size(110, 28)
$grpOut.Controls.Add($btnFolder)

$btnName = New-Object System.Windows.Forms.Button
$btnName.Text = 'Nama fail...'
$btnName.Location = New-Object System.Drawing.Point(894, 22)
$btnName.Size = New-Object System.Drawing.Size(100, 28)
$grpOut.Controls.Add($btnName)

$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = 'Mod & kualiti'
$grpMode.Location = New-Object System.Drawing.Point(12, 414)
$grpMode.Size = New-Object System.Drawing.Size(1004, 64)
$form.Controls.Add($grpMode)

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.DropDownStyle = 'DropDownList'
$cmbMode.Location = New-Object System.Drawing.Point(10, 24)
$cmbMode.Size = New-Object System.Drawing.Size(300, 24)
foreach ($m in $script:Modes) { [void] $cmbMode.Items.Add($m.Label) }
$cmbMode.SelectedIndex = 0
$grpMode.Controls.Add($cmbMode)

$cmbQuality = New-Object System.Windows.Forms.ComboBox
$cmbQuality.DropDownStyle = 'DropDownList'
$cmbQuality.Location = New-Object System.Drawing.Point(320, 24)
$cmbQuality.Size = New-Object System.Drawing.Size(200, 24)
foreach ($q in $script:Qualities) { [void] $cmbQuality.Items.Add($q.Label) }
$cmbQuality.SelectedIndex = 1
$grpMode.Controls.Add($cmbQuality)

$cmbPreset = New-Object System.Windows.Forms.ComboBox
$cmbPreset.DropDownStyle = 'DropDownList'
$cmbPreset.Location = New-Object System.Drawing.Point(530, 24)
$cmbPreset.Size = New-Object System.Drawing.Size(150, 24)
foreach ($p in @('veryfast', 'medium', 'slow')) { [void] $cmbPreset.Items.Add($p) }
$cmbPreset.SelectedIndex = 1
$grpMode.Controls.Add($cmbPreset)

$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Location = New-Object System.Drawing.Point(690, 27)
$lblNote.Size = New-Object System.Drawing.Size(310, 22)
$lblNote.ForeColor = [System.Drawing.Color]::DimGray
$lblNote.Text = 'Kualiti/preset hanya untuk encode.'
$grpMode.Controls.Add($lblNote)

$lblCmd = New-Object System.Windows.Forms.Label
$lblCmd.Text = 'Arahan CLI (boleh salin & jalankan sendiri)'
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
$btnCmd.Text = 'Jana arahan'
$btnCmd.Location = New-Object System.Drawing.Point(12, 574)
$btnCmd.Size = New-Object System.Drawing.Size(130, 30)
$form.Controls.Add($btnCmd)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Mula  (buka PowerShell & jalankan)'
$btnRun.Location = New-Object System.Drawing.Point(150, 574)
$btnRun.Size = New-Object System.Drawing.Size(300, 30)
$btnRun.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnRun)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = 'Buka folder job'
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
$lblStatus.Text = 'Sedia.'
$form.Controls.Add($lblStatus)

$lblFoot = New-Object System.Windows.Forms.Label
$lblFoot.Location = New-Object System.Drawing.Point(12, 672)
$lblFoot.Size = New-Object System.Drawing.Size(1004, 40)
$lblFoot.ForeColor = [System.Drawing.Color]::DimGray
$lblFoot.Text = "GUI boleh ditutup selepas tekan Mula; job diteruskan dalam tetingkap PowerShell. Log job di %TEMP%\VideoStitch."
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
        if (-not $script:Files.Contains($full)) { [void] $script:Files.Add($full); $added++ }
    }
    if ($added -gt 0) {
        $script:Files = [System.Collections.Generic.List[string]]::new([string[]] (Sort-FilesNatural -Paths $script:Files.ToArray()))
        Update-List
        $lblStatus.Text = "Tambah $added fail. Jumlah: $($script:Files.Count)."
        if (-not $txtOut.Text.Trim()) {
            $dir = Split-Path -Parent $script:Files[0]
            $txtOut.Text = Join-Path $dir 'out.mp4'
        }
    }
}

function Get-Mode { $script:Modes[$cmbMode.SelectedIndex].Value }
function Get-Quality { $script:Qualities[$cmbQuality.SelectedIndex].Value }

function Get-CliArgs {
    param([string[]] $Files, [string] $Out)
    $parts = @('-Files')
    $parts += (($Files | ForEach-Object { Quote-PS $_ }) -join ',')
    $parts += @('-Out', (Quote-PS $Out), '-Mode', (Get-Mode))
    if ((Get-Mode) -ne 'copy') {
        $parts += @('-Quality', (Get-Quality), '-Preset', $cmbPreset.SelectedItem.ToString())
    }
    if ($script:Running -and $script:JobDir) {
        $parts += @('-Progress', (Quote-PS (Join-Path $script:JobDir 'ffprogress.txt')))
        $parts += @('-Log',      (Quote-PS (Join-Path $script:JobDir 'ffmpeg.log')))
        $parts += @('-State',    (Quote-PS (Join-Path $script:JobDir 'state.txt')))
    }
    return $parts
}

function Get-CommandPreview {
    if ($script:Files.Count -eq 0) { return '(tiada fail)' }
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
    $dlg.Filter = 'Video|*.mp4;*.mov;*.mkv;*.m4v;*.avi;*.ts;*.m2ts;*.webm;*.wmv;*.flv;*.mpg;*.mpeg|Semua fail|*.*'
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

$btnClear.Add_Click({ $script:Files.Clear(); Update-List; Update-Preview; $lblStatus.Text = 'Senarai kosong.' })

$btnSort.Add_Click({
    $script:Files = [System.Collections.Generic.List[string]]::new([string[]] (Sort-FilesNatural -Paths $script:Files.ToArray()))
    Update-List; Update-Preview; $lblStatus.Text = 'Disusun ikut nama (natural).'
})

$btnFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pilih folder target output'
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
    $dlg.Filter = 'MP4|*.mp4|Semua fail|*.*'
    $dlg.FileName = 'out.mp4'
    if ($txtOut.Text.Trim()) { $dlg.InitialDirectory = Split-Path -Parent $txtOut.Text.Trim(); $dlg.FileName = Split-Path -Leaf $txtOut.Text.Trim() }
    if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.FileName; Update-Preview }
})

$cmbMode.Add_SelectedIndexChanged({
    $isCopy = (Get-Mode) -eq 'copy'
    $cmbQuality.Enabled = -not $isCopy
    $cmbPreset.Enabled = -not $isCopy
    $lblNote.Text = if ($isCopy) { 'Copy: semua klip mesti codec/resolusi/fps sama.' } else { 'Kualiti/preset hanya untuk encode.' }
    Update-Preview
})
$cmbQuality.Add_SelectedIndexChanged({ Update-Preview })
$cmbPreset.Add_SelectedIndexChanged({ Update-Preview })
$txtOut.Add_TextChanged({ Update-Preview })

$btnCmd.Add_Click({ Update-Preview; $lblStatus.Text = 'Arahan dijana (lihat kotak arahan).' })

$btnLog.Add_Click({ if ($script:JobDir -and (Test-Path -LiteralPath $script:JobDir)) { Start-Process explorer.exe -ArgumentList ("`"{0}`"" -f $script:JobDir) } })

# ------------------------------------------------------------------- Mula ----

$btnRun.Add_Click({
    try {
        if ($script:Files.Count -lt 1) { throw 'Tambah sekurang-kurangnya 1 fail video.' }
        $out = $txtOut.Text.Trim()
        if (-not $out) { throw 'Tetapkan folder target / nama fail output.' }
        if (-not $out.ToLowerInvariant().EndsWith('.mp4')) { $out += '.mp4'; $txtOut.Text = $out }
        $outDir = Split-Path -Parent $out
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

        if (-not (Test-Path -LiteralPath $script:CliPath)) { throw "CLI tidak dijumpai: $script:CliPath" }
        $ff = Get-FFmpegPath
        if (-not $ff) { throw 'ffmpeg tidak dijumpai. Pasang: winget install -e --id Gyan.FFmpeg' }

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
if (`$code -ne 0) { Write-Host "Job TAMAT dengan ralat (rc=`$code). Log: $($script:JobDir)\ffmpeg.log" -ForegroundColor Red }
else { Write-Host "Job SIAP: $out" -ForegroundColor Green }
# 'exit' dalam skrip yang dipanggil (&) hanya tamatkan skrip itu, bukan sesi -
# jadi exit code mesti dihantar secara eksplisit.
exit `$code
"@
        [System.IO.File]::WriteAllText($jobFile, $jobBody, [System.Text.UTF8Encoding]::new($true))

        $txtCmd.Text = Get-CommandPreview
        $prg.Value = 0
        $lblStatus.Text = 'Menjalankan job dalam tetingkap PowerShell baru...'

        $psArgs = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $jobFile
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WorkingDirectory $script:JobDir | Out-Null

        $btnLog.Enabled = $true
        $script:Timer.Start()
    }
    catch {
        $script:Running = $false
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ralat', 'OK', 'Warning') | Out-Null
        $lblStatus.Text = 'Ralat: ' + $_.Exception.Message
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
        'PROBE'   { $lblStatus.Text = 'Probe klip...' }
        'RUNNING' { $lblStatus.Text = ('Bekerja... {0:0.0}%  (GUI boleh ditutup)' -f $pct) }
        'DONE'    {
            $script:Running = $false
            $script:Timer.Stop()
            $prg.Value = 1000
            $lblStatus.Text = 'Siap. Fail: ' + $txtOut.Text
        }
        'ERROR'   {
            $script:Running = $false
            $script:Timer.Stop()
            $lblStatus.Text = 'Ralat: ' + ($(if ($state.ContainsKey('DETAIL')) { $state['DETAIL'] } else { 'lihat tetingkap PowerShell' }))
        }
    }
})

$form.Add_FormClosing({ $script:Timer.Stop(); $script:Timer.Dispose() })

$cmbMode.SelectedIndex = 0
Update-Preview
[void] $form.ShowDialog()
