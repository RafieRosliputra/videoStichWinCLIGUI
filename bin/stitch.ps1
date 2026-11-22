<#
.SYNOPSIS
    videoStitchWinCLIGUI - CLI: cantum banyak video jadi satu fail.

.DESCRIPTION
    CLI ini berdiri sendiri. GUI TIDAK memerlukan CLI untuk berfungsi, tetapi
    GUI menjana arahan CLI ini dan menjalankannya dalam tetingkap PowerShell
    berasingan (lihat docs/CARA-FIKIR.md).

    Mod:
      copy   - stream copy (sifar encode). Syarat: semua klip sama codec,
               resolusi, fps, pix_fmt, audio codec/sample rate/channels.
      hevc   - encode H.265 (libx265) dengan CRF ikut tahap kualiti.
      h264   - encode H.264 (libx264) sebagai fallback selamat.

    Progress: ffmpeg menulis fail -progress (out_time_us=...) yang dibaca GUI.
    Status: fail -State mengandungi TOTAL=, STATUS=RUNNING|DONE|ERROR.

.PARAMETER Files
    Senarai fail, IKUT SUSUNAN cantuman. GUI yang tentukan susunan.

.PARAMETER Out
    Laluan fail output (.mp4).

.PARAMETER Mode
    copy | hevc | h264

.PARAMETER Quality
    high (CRF 20) | balanced (CRF 23) | small (CRF 28). Diabaikan untuk copy.

.PARAMETER Preset
    Preset x264/x265 (ultrafast..placebo). Default: medium.

.PARAMETER Crf
    Override CRF terus (menang atas -Quality).

.PARAMETER FFmpeg
    Laluan ffmpeg.exe pilihan. Default: dari PATH.

.PARAMETER Progress
    Fail progress mentah ffmpeg. Default: <temp>\video-stitch.progress

.PARAMETER Log
    Fail log ralat ffmpeg. Default: <temp>\video-stitch.log

.PARAMETER State
    Fail status kerja. Default: <temp>\video-stitch.state

.EXAMPLE
    .\stitch.ps1 -Files a.mp4,b.mp4,c.mp4 -Out out.mp4 -Mode copy

.EXAMPLE
    .\stitch.ps1 -Files (Get-ChildItem *.mp4 | Sort-Object Name | % FullName) `
                 -Out out.mp4 -Mode hevc -Quality balanced
#>
[CmdletBinding()]
param(
    [string[]] $Files,
    [string]   $Out,
    [ValidateSet('copy', 'hevc', 'h264')] [string] $Mode = 'copy',
    [ValidateSet('high', 'balanced', 'small')] [string] $Quality = 'balanced',
    [ValidateSet('auto', 'cpu', 'nvenc', 'qsv', 'amf', 'mf')] [string] $Encoder = 'auto',
    [int]      $GpuDevice = 0,
    [string]   $Preset = 'medium',
    [int]      $Crf = 0,
    [string]   $FFmpeg,
    [switch]   $Install,
    [string]   $Progress,
    [string]   $Log,
    [string]   $State
)

$ErrorActionPreference = 'Stop'

$script:CrfMap = @{ high = 20; balanced = 23; small = 28 }

# ---------------------------------------------------------------- utiliti ----

function Get-FFmpegPath {
    param([string] $Explicit)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        throw "ffmpeg not found: $Explicit"
    }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($env:FFMPEG_PATH -and (Test-Path -LiteralPath $env:FFMPEG_PATH)) { return $env:FFMPEG_PATH }
    throw "ffmpeg not found in PATH. Windows: winget install -e --id Gyan.FFmpeg"
}

function Install-FFmpeg {
    # Opt-in sahaja (-Install atau butang GUI). Tidak memasang secara senyap.
    if (-not ($env:OS -eq 'Windows_NT')) { throw 'Auto-install is Windows-only (winget).' }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'winget not found. Install "App Installer" from the Microsoft Store.' }
    Write-Host '[ffmpeg] Installing Gyan.FFmpeg via winget...' -ForegroundColor Yellow
    & $winget.Source install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget failed (rc=$LASTEXITCODE). Install manually: winget install -e --id Gyan.FFmpeg" }
    Write-Host '[ffmpeg] Installed.' -ForegroundColor Green
}

function Get-FFprobePath {
    param([string] $FFmpegPath)
    $dir = Split-Path -Parent $FFmpegPath
    $ext = if ($IsWindows -or $env:OS -eq 'Windows_NT') { '.exe' } else { '' }
    $p = Join-Path $dir ("ffprobe" + $ext)
    if (Test-Path -LiteralPath $p) { return $p }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $p
}

function Compare-Natural {
    # Banding nama fail secara "natural": clip2 sebelum clip10.
    param([string] $A, [string] $B)
    $ta = [regex]::Matches((Split-Path -Leaf $A), '\d+|\D+') | ForEach-Object { $_.Value }
    $tb = [regex]::Matches((Split-Path -Leaf $B), '\d+|\D+') | ForEach-Object { $_.Value }
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
    $c2 = [string]::Compare($A.ToLowerInvariant(), $B.ToLowerInvariant(), [StringComparison]::Ordinal)
    return [Math]::Sign($c2)
}

function Sort-FilesNatural {
    param([string[]] $Paths)
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Paths) { [void] $list.Add($p) }
    $list.Sort([System.Comparison[string]] { param($a, $b) Compare-Natural -A $a -B $b })
    return , $list.ToArray()
}

function Expand-Files {
    # Benarkan: array, atau SATU string dipisah koma / koma bertitik / baris baru.
    # (PowerShell -File tidak memecah koma, jadi 'a.mp4,b.mp4' tiba sebagai 1 item.)
    param([string[]] $Inputs)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($i in $Inputs) {
        if (-not $i) { continue }
        if (Test-Path -LiteralPath $i) { [void] $out.Add($i); continue }
        $parts = @($i -split "\r?\n|;")
        if ($parts.Count -eq 1 -and $i.Contains(',')) { $parts = @($i -split ',') }
        foreach ($p in $parts) {
            $t = $p.Trim().Trim('"').Trim("'")
            if ($t) { [void] $out.Add($t) }
        }
    }
    return , $out.ToArray()
}

function Get-MediaInfo {
    param([string] $Path, [string] $FFprobePath)
    $raw = & $FFprobePath -v error -print_format json -show_streams -show_format -i $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "ffprobe could not read: $Path" }
    $o = $raw | ConvertFrom-Json
    $v = @($o.streams | Where-Object { $_.codec_type -eq 'video' })[0]
    $a = @($o.streams | Where-Object { $_.codec_type -eq 'audio' })[0]

    $fps = 0.0
    if ($v -and $v.r_frame_rate -match '^(\d+)/(\d+)$') {
        $num = [double] $Matches[1]; $den = [double] $Matches[2]
        if ($den -gt 0) { $fps = [Math]::Round($num / $den, 3) }
    }
    $dur = 0.0
    if ($o.format.duration) { $dur = [double] $o.format.duration }
    elseif ($v.duration) { $dur = [double] $v.duration }

    [pscustomobject] @{
        Path       = $Path
        VCodec     = if ($v) { $v.codec_name } else { $null }
        Width      = if ($v) { [int] $v.width } else { 0 }
        Height     = if ($v) { [int] $v.height } else { 0 }
        Fps        = $fps
        PixFmt     = if ($v) { $v.pix_fmt } else { $null }
        HasVideo   = [bool] $v
        ACodec     = if ($a) { $a.codec_name } else { $null }
        SampleRate = if ($a) { [int] $a.sample_rate } else { 0 }
        Channels   = if ($a) { [int] $a.channels } else { 0 }
        HasAudio   = [bool] $a
        Duration   = $dur
    }
}

function Test-Uniform {
    # Pulangkan senarai isu. Kosong = selamat untuk -c copy.
    param([object[]] $Infos)
    $issues = [System.Collections.Generic.List[string]]::new()
    $ref = $Infos[0]
    foreach ($i in $Infos | Select-Object -Skip 1) {
        $name = Split-Path -Leaf $i.Path
        if ($i.VCodec -ne $ref.VCodec) { [void] $issues.Add("$name : codec video $($i.VCodec) != $($ref.VCodec)") }
        if ($i.Width -ne $ref.Width -or $i.Height -ne $ref.Height) { [void] $issues.Add("$name : resolusi $($i.Width)x$($i.Height) != $($ref.Width)x$($ref.Height)") }
        if ([Math]::Abs($i.Fps - $ref.Fps) -gt 0.01) { [void] $issues.Add("$name : fps $($i.Fps) != $($ref.Fps)") }
        if ($i.PixFmt -ne $ref.PixFmt) { [void] $issues.Add("$name : pix_fmt $($i.PixFmt) != $($ref.PixFmt)") }
        if ($i.HasAudio -ne $ref.HasAudio) { [void] $issues.Add("$name : audio ada/tidak tak seragam") }
        elseif ($i.HasAudio) {
            if ($i.ACodec -ne $ref.ACodec) { [void] $issues.Add("$name : codec audio $($i.ACodec) != $($ref.ACodec)") }
            if ($i.SampleRate -ne $ref.SampleRate) { [void] $issues.Add("$name : sample rate audio $($i.SampleRate) != $($ref.SampleRate)") }
            if ($i.Channels -ne $ref.Channels) { [void] $issues.Add("$name : bilangan channel audio $($i.Channels) != $($ref.Channels)") }
        }
    }
    return , $issues.ToArray()
}

function ConvertTo-ConcatLine {
    # ffmpeg concat demuxer: "file '<path>'". Tukar \ -> / supaya bukan escape.
    # Apostrof: escape gaya shell ('\''). Disahkan pada ffmpeg 9 - bentuk
    # "file \"...\"" TIDAK berfungsi; 'it'\''s.mp4' dan it\'s.mp4 berfungsi.
    param([string] $Path)
    $p = $Path -replace '\\', '/'
    $p = $p -replace "'", "'\''"
    return "file '" + $p + "'"
}

function New-ConcatList {
    param([string[]] $Paths, [string] $Dir)
    $file = Join-Path $Dir 'concat.txt'
    $lines = foreach ($p in $Paths) { ConvertTo-ConcatLine -Path $p }
    # UTF-8 tanpa BOM; ffmpeg baca bytes mentah.
    [System.IO.File]::WriteAllLines($file, [string[]] $lines, [System.Text.UTF8Encoding]::new($false))
    return $file
}

function Get-EncodeSettings {
    param([string] $Q, [int] $CrfOverride, [string] $Preset, [string] $Mode)
    $crf = if ($CrfOverride -gt 0) { $CrfOverride } else { $script:CrfMap[$Q] }
    $codec = if ($Mode -eq 'hevc') { 'libx265' } else { 'libx264' }
    [pscustomobject] @{ Codec = $codec; Crf = $crf; Preset = $Preset; Mode = $Mode }
}

function Get-EncoderPlan {
    # Pulangkan hashtable: Codec + Args. Kualiti dipetakan ikut enjin:
    #   cpu   -> -crf        (libx265/libx264)
    #   nvenc -> -cq         (CQ, skala sedikit lebih rendah dari CRF)
    #   qsv   -> -global_quality
    #   amf   -> -qp_i/-qp_p
    #   mf    -> -b:v (Media Foundation tak sokong CRF)
    param([string] $Encoder, [string] $Mode, [string] $Q, [int] $CrfOverride, [string] $Preset, [int] $GpuDevice = 0)

    $crf = if ($CrfOverride -gt 0) { $CrfOverride } else { $script:CrfMap[$Q] }
    $nvencCq = if ($CrfOverride -gt 0) { [Math]::Max(1, $CrfOverride - 1) } else { @{ high = 19; balanced = 22; small = 27 }[$Q] }

    switch ($Encoder) {
        'nvenc' {
            $codec = if ($Mode -eq 'hevc') { 'hevc_nvenc' } else { 'h264_nvenc' }
            $p = @{ veryfast = 'p3'; medium = 'p5'; slow = 'p7' }[$Preset]
            if (-not $p) { $p = 'p5' }
            return @{ Codec = $codec; Args = @('-c:v', $codec, '-gpu', "$GpuDevice", '-preset', $p, '-rc', 'vbr', '-cq', "$nvencCq", '-b:v', '0') }
        }
        'qsv' {
            $codec = if ($Mode -eq 'hevc') { 'hevc_qsv' } else { 'h264_qsv' }
            return @{ Codec = $codec; Args = @('-c:v', $codec, '-global_quality', "$crf", '-preset', $Preset) }
        }
        'amf' {
            $codec = if ($Mode -eq 'hevc') { 'hevc_amf' } else { 'h264_amf' }
            $q = @{ veryfast = 'speed'; medium = 'balanced'; slow = 'quality' }[$Preset]
            if (-not $q) { $q = 'balanced' }
            return @{ Codec = $codec; Args = @('-c:v', $codec, '-rc', 'cqp', '-qp_i', "$crf", '-qp_p', "$crf", '-quality', $q) }
        }
        'mf' {
            $codec = if ($Mode -eq 'hevc') { 'hevc_mf' } else { 'h264_mf' }
            $b = @{ high = '10M'; balanced = '6M'; small = '3M' }[$Q]
            return @{ Codec = $codec; Args = @('-c:v', $codec, '-b:v', $b) }
        }
        default {
            $codec = if ($Mode -eq 'hevc') { 'libx265' } else { 'libx264' }
            return @{ Codec = $codec; Args = @('-c:v', $codec, '-preset', $Preset, '-crf', "$crf") }
        }
    }
}

function Get-EncoderCodec {
    param([string] $Encoder, [string] $Mode)
    $hevc = ($Mode -eq 'hevc')
    switch ($Encoder) {
        'nvenc' { if ($hevc) { return 'hevc_nvenc' } else { return 'h264_nvenc' } }
        'qsv'   { if ($hevc) { return 'hevc_qsv' }   else { return 'h264_qsv' } }
        'amf'   { if ($hevc) { return 'hevc_amf' }   else { return 'h264_amf' } }
        'mf'    { if ($hevc) { return 'hevc_mf' }    else { return 'h264_mf' } }
        default { if ($hevc) { return 'libx265' }    else { return 'libx264' } }
    }
}

function Test-EncoderUsable {
    # 1) codec wujud dalam build ffmpeg  2) ujian encode 0.2s pada peranti sebenar
    param([string] $Encoder, [string] $Mode, [string] $FFmpegPath)
    if ($Encoder -eq 'cpu') { return $true }
    $codec = Get-EncoderCodec -Encoder $Encoder -Mode $Mode
    $list = & $FFmpegPath -hide_banner -encoders 2>&1 | Out-String
    if ($list -notmatch ('(?m)^\s*V[.\w]+\s+' + [regex]::Escape($codec) + '\s')) { return $false }
    try {
        $probe = & $FFmpegPath -hide_banner -loglevel error -f lavfi -i 'color=c=black:s=256x144:d=0.2' -c:v $codec -f null - 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
}

function Resolve-Encoder {
    param([string] $Requested, [string] $Mode, [string] $FFmpegPath)
    if ($Requested -eq 'cpu') { return 'cpu' }
    $order = if ($Requested -eq 'auto') { @('nvenc', 'qsv', 'amf', 'mf') } else { @($Requested) }
    foreach ($c in $order) {
        if (Test-EncoderUsable -Encoder $c -Mode $Mode -FFmpegPath $FFmpegPath) { return $c }
    }
    if ($Requested -ne 'auto') { throw "Encoder '$Requested' is not available on this machine (codec missing or device failed). Try -Encoder auto or cpu." }
    Write-Warning 'No GPU encoder found; using CPU.'
    return 'cpu'
}

function Get-NormalizeFilter {
    # Semua input -> saiz/fps yang sama; aspect kekal (pad hitam).
    param([object[]] $Infos)
    $w = ($Infos | Measure-Object -Property Width  -Maximum).Maximum
    $h = ($Infos | Measure-Object -Property Height -Maximum).Maximum
    $fps = ($Infos | Measure-Object -Property Fps    -Maximum).Maximum
    $w = [int]([Math]::Floor($w / 2) * 2); $h = [int]([Math]::Floor($h / 2) * 2)
    if ($w -lt 2) { $w = 2 }; if ($h -lt 2) { $h = 2 }
    if (-not $fps -or $fps -lt 1) { $fps = 30 }
    $f = ("{0:0.###}" -f $fps)
    return "scale=${w}:${h}:force_original_aspect_ratio=decrease:force_divisible_by=2," +
           "pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$f"
}

function Quote-Arg {
    param([string] $Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

# ---------------------------------------------------------------- utama -----

function Invoke-Stitch {
    param(
        [string[]] $Files, [string] $Out, [string] $Mode, [string] $Quality,
        [string] $Encoder = 'auto', [int] $GpuDevice = 0, [string] $Preset, [int] $Crf, [string] $FFmpeg,
        [switch] $Install, [string] $Progress, [string] $Log, [string] $State
    )

    $Files = Expand-Files -Inputs $Files
    if (-not $Files -or $Files.Count -lt 1) { throw 'No input files (-Files).' }
    if (-not $Out) { throw 'No output path (-Out).' }
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f)) { throw "Input file not found: $f" }
        if ($f -eq $Out) { throw "Output file is also listed as input: $Out" }
    }
    if ($Files.Count -eq 1) { Write-Warning 'Only one input file: this is a remux, not a stitch.' }

    try { $ff = Get-FFmpegPath -Explicit $FFmpeg }
    catch {
        if ($Install) {
            Install-FFmpeg
            $ff = Get-FFmpegPath -Explicit $FFmpeg
        }
        else {
            throw "$($_.Exception.Message)`nTry: -Install (auto winget) or 'winget install -e --id Gyan.FFmpeg'."
        }
    }
    $fp = Get-FFprobePath -FFmpegPath $ff
    $tmp = [System.IO.Path]::GetTempPath()
    if (-not $Progress) { $Progress = Join-Path $tmp 'video-stitch.progress' }
    if (-not $Log)      { $Log      = Join-Path $tmp 'video-stitch.log' }
    if (-not $State)    { $State    = Join-Path $tmp 'video-stitch.state' }

    $outDir = Split-Path -Parent $Out
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

    Remove-Item -LiteralPath $Progress, $Log, $State -ErrorAction SilentlyContinue

    $encName = 'cpu'
    if ($Mode -ne 'copy') {
        $encName = Resolve-Encoder -Requested $Encoder -Mode $Mode -FFmpegPath $ff
    }

    # 1) probe
    $setState = {
        param([string] $status, [double] $total)
        $lines = @()
        if ($total -gt 0) { $lines += ('TOTAL=' + $total.ToString([Globalization.CultureInfo]::InvariantCulture)) }
        $lines += ('MODE=' + $Mode)
        if ($Mode -ne 'copy') { $lines += ('ENCODER=' + $encName) }
        if ($status -like 'ERROR*') {
            $lines += 'STATUS=ERROR'
            $lines += ('DETAIL=' + ($status -replace '^ERROR ?', ''))
        }
        else { $lines += ('STATUS=' + $status) }
        [System.IO.File]::WriteAllLines($State, [string[]] $lines, [System.Text.UTF8Encoding]::new($false))
    }
    & $setState 'PROBE' 0

    Write-Host "[1/4] Probing $($Files.Count) file(s)..." -ForegroundColor Cyan
    $infos = @(foreach ($f in $Files) { Get-MediaInfo -Path $f -FFprobePath $fp })
    $total = ($infos | Measure-Object -Property Duration -Sum).Sum

    # 2) sahkan
    $issues = Test-Uniform -Infos $infos
    if ($Mode -eq 'copy' -and $issues.Count -gt 0) {
        $msg = "Copy mode is not safe, clips are not uniform:`n  " + ($issues -join "`n  ") + "`n`nUse -Mode hevc or -Mode h264."
        & $setState ('ERROR ' + ($issues -join '; ')) $total
        throw $msg
    }
    if ($Mode -eq 'copy') { Write-Host '[2/4] All clips uniform: stream copy is safe.' -ForegroundColor Green }
    else {
        $label = switch ($encName) { 'cpu' { 'CPU' } 'nvenc' { 'GPU NVENC' } 'qsv' { 'GPU QSV' } 'amf' { 'GPU AMF' } 'mf' { 'GPU MediaFoundation' } }
        $crfShown = if ($Crf -gt 0) { $Crf } else { $script:CrfMap[$Quality] }
        Write-Host "[2/4] Encoding $Mode with $label (quality $Quality = $crfShown, preset $Preset)." -ForegroundColor Green
    }

    # 3) arahan
    $listDir = Split-Path -Parent $Progress
    if (-not $listDir -or -not (Test-Path -LiteralPath $listDir)) { $listDir = $tmp }
    $list = New-ConcatList -Paths $Files -Dir $listDir

    $enc = Get-EncodeSettings -Q $Quality -CrfOverride $Crf -Preset $Preset -Mode $Mode
    $ffArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error',
                     '-f', 'concat', '-safe', '0', '-i', (Quote-Arg $list),
                     '-progress', (Quote-Arg $Progress))) { $ffArgs.Add($a) }

    $hasAudio = ($infos | Where-Object { $_.HasAudio }).Count -gt 0
    if ($Mode -eq 'copy') {
        foreach ($a in @('-c', 'copy', '-movflags', '+faststart', '-avoid_negative_ts', 'make_zero')) { $ffArgs.Add($a) }
    }
    else {
        $filter = Get-NormalizeFilter -Infos $infos
        $plan = Get-EncoderPlan -Encoder $encName -Mode $Mode -Q $Quality -CrfOverride $Crf -Preset $Preset -GpuDevice $GpuDevice
        foreach ($a in @($plan.Args)) { $ffArgs.Add($a) }
        foreach ($a in @('-pix_fmt', 'yuv420p', '-vf', (Quote-Arg $filter))) { $ffArgs.Add($a) }
        if ($Mode -eq 'hevc') { $ffArgs.Add('-tag:v'); $ffArgs.Add('hvc1') }
        if ($hasAudio) { foreach ($a in @('-c:a', 'aac', '-b:a', '192k')) { $ffArgs.Add($a) } }
        else { $ffArgs.Add('-an') }
        foreach ($a in @('-movflags', '+faststart')) { $ffArgs.Add($a) }
    }
    $ffArgs.Add((Quote-Arg $Out))

    Write-Host "[3/4] ffmpeg $($Mode) -> $Out" -ForegroundColor Cyan
    $argLine = ($ffArgs -join ' ')
    Write-Verbose "ARAHAN: $ff $argLine"

    & $setState 'RUNNING' $total
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $ff -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardError $Log
    $lastShown = -1
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 400
        $us = 0L
        if (Test-Path -LiteralPath $Progress) {
            $m = Select-String -LiteralPath $Progress -Pattern '^out_time_us=(\d+)$' | Select-Object -Last 1
            if ($m) { [void] [int64]::TryParse($m.Matches[0].Groups[1].Value, [ref] $us) }
        }
        if ($total -gt 0) {
            $pct = [Math]::Min(100, [Math]::Round(($us / 1000000) / $total * 100, 1))
            if ($pct -ne $lastShown) {
                $lastShown = $pct
                Write-Host -NoNewline ("`r[4/4] {0,5:0.0}%  {1} / {2}   " -f $pct,
                    [TimeSpan]::FromSeconds($us / 1000000).ToString('hh\:mm\:ss'),
                    [TimeSpan]::FromSeconds($total).ToString('hh\:mm\:ss'))
            }
        }
        else { Write-Host -NoNewline "`r[4/4] working...  " }
    }
    $sw.Stop()
    Write-Host ''

    $code = $proc.ExitCode
    if ($code -ne 0) {
        $err = if (Test-Path -LiteralPath $Log) { (Get-Content -LiteralPath $Log -Tail 15) -join "`n" } else { '' }
        & $setState "ERROR rc=$code" $total
        throw "ffmpeg failed (rc=$code).`n$err"
    }
    & $setState 'DONE' $total

    $size = if (Test-Path -LiteralPath $Out) { (Get-Item -LiteralPath $Out).Length } else { 0 }
    Write-Host ("[OK] {0}  ({1:N1} MB, {2:0.0}s)" -f $Out, ($size / 1MB), $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    return $Out
}

# Jalankan hanya bila dipanggil sebagai skrip (bukan dot-source oleh test).
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-Stitch -Files $Files -Out $Out -Mode $Mode -Quality $Quality -Encoder $Encoder -GpuDevice $GpuDevice -Preset $Preset `
                      -Crf $Crf -FFmpeg $FFmpeg -Install:$Install -Progress $Progress -Log $Log -State $State | Out-Null
        exit 0
    }
    catch {
        Write-Host ''
        Write-Host "[X] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
