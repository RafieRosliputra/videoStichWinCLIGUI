# Ujian videoStitch.
# Boleh dijalankan di Windows (PowerShell 5.1+) atau macOS/Linux (PowerShell 7)
# asalkan ffmpeg + ffprobe ada dalam PATH.
#
#   pwsh -File tests/run-tests.ps1
#   powershell -File tests/run-tests.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $root 'bin\stitch.ps1'
if (-not (Test-Path -LiteralPath $cli)) { $cli = Join-Path $root 'bin/stitch.ps1' }

. $cli    # dot-source: muat fungsi tanpa jalankan main

$TmpBase = [IO.Path]::GetTempPath()

$pass = 0; $fail = 0
function Check {
    param([string] $Name, [scriptblock] $Body)
    try {
        & $Body
        Write-Host ("  PASS  $Name") -ForegroundColor Green
        $script:pass++
    }
    catch {
        Write-Host ("  FAIL  $Name  -> $($_.Exception.Message)") -ForegroundColor Red
        $script:fail++
    }
}

function Assert-Equal { param($A, $B, [string] $Msg = '')
    if ($A -ne $B) { throw ("dijangka '{0}' tetapi '{1}' {2}" -f $B, $A, $Msg) }
}
function Assert-True { param($Cond, [string] $Msg = '')
    if (-not $Cond) { throw "syarat gagal $Msg" }
}

# ---- 1. natural sort --------------------------------------------------------
Check 'natural sort: clip1, clip2, clip10' {
    $sorted = Sort-FilesNatural -Paths @(
        (Join-Path $TmpBase 'clip10.mp4'),
        (Join-Path $TmpBase 'clip2.mp4'),
        (Join-Path $TmpBase 'clip1.mp4'))
    $names = $sorted | ForEach-Object { Split-Path -Leaf $_ }
    Assert-Equal ($names -join ',') 'clip1.mp4,clip2.mp4,clip10.mp4'
}

Check 'natural sort: nama bercampur' {
    $sorted = Sort-FilesNatural -Paths @('B 2.mp4', 'B 10.mp4', 'B 1.mp4', 'A.mp4')
    $names = $sorted | ForEach-Object { Split-Path -Leaf $_ }
    Assert-Equal ($names -join ',') 'A.mp4,B 1.mp4,B 2.mp4,B 10.mp4'
}

Check 'natural sort: leading zero dikira nombor' {
    $sorted = Sort-FilesNatural -Paths @('part-03.mp4', 'part-1.mp4', 'part-02.mp4')
    $names = $sorted | ForEach-Object { Split-Path -Leaf $_ }
    Assert-Equal ($names -join ',') 'part-1.mp4,part-02.mp4,part-03.mp4'
}

# ---- 2. concat list escaping ------------------------------------------------
Check 'concat line: backslash jadi slash' {
    $line = ConvertTo-ConcatLine -Path 'C:\Videos\a b\clip 1.mp4'
    Assert-Equal $line "file 'C:/Videos/a b/clip 1.mp4'"
}

Check 'concat line: apostrof di-escape gaya shell' {
    $line = ConvertTo-ConcatLine -Path "C:\Videos\it's.mp4"
    Assert-Equal $line "file 'C:/Videos/it'\''s.mp4'"
}

Check 'concat line: petikan double kekal literal' {
    $line = ConvertTo-ConcatLine -Path 'C:\Videos\a"b.mp4'
    Assert-Equal $line 'file ''C:/Videos/a"b.mp4'''
}

# ---- 3. uniformiti ----------------------------------------------------------
function New-Info {
    param([string] $P, [string] $Vc = 'h264', [int] $W = 1920, [int] $H = 1080,
          [double] $Fps = 30, [string] $Pix = 'yuv420p', [string] $Ac = 'aac',
          [int] $Sr = 48000, [int] $Ch = 2, [double] $Dur = 10)
    [pscustomobject] @{ Path = $P; VCodec = $Vc; Width = $W; Height = $H; Fps = $Fps
        PixFmt = $Pix; HasVideo = $true; ACodec = $Ac; SampleRate = $Sr; Channels = $Ch
        HasAudio = [bool] $Ac; Duration = $Dur }
}

Check 'uniform: semua sama = tiada isu' {
    $infos = @((New-Info 'a.mp4'), (New-Info 'b.mp4'))
    Assert-Equal (Test-Uniform -Infos $infos).Count 0
}

Check 'fps: avg diutamakan atas r_frame_rate (DJI 100 vs 59.94)' {
    Assert-Equal (Resolve-Fps -Avg '60000/1001' -R '100/1') 59.94
}

Check 'fps: avg 0/0 -> tak diketahui (r tidak dipercayai)' {
    Assert-Equal (Resolve-Fps -Avg '0/0' -R '100/1') 0
    Assert-Equal (Resolve-Fps -Avg '0/0' -R '25/1') 0
}

Check 'fps: tiada nilai = 0' {
    Assert-Equal (Resolve-Fps -Avg '' -R '') 0
}

Check 'uniform: fps tak diketahui tidak dianggap beza' {
    $infos = @((New-Info 'a.mp4' -Fps 59.94), (New-Info 'b.mp4' -Fps 0))
    Assert-Equal (Test-Uniform -Infos $infos).Count 0
}

Check 'uniform: resolusi berbeza dikesan' {
    $infos = @((New-Info 'a.mp4'), (New-Info 'b.mp4' -W 1280 -H 720))
    $issues = Test-Uniform -Infos $infos
    Assert-True ($issues.Count -ge 1)
    Assert-True (($issues -join ' ') -match 'resolusi')
}

Check 'uniform: fps berbeza dikesan' {
    $infos = @((New-Info 'a.mp4'), (New-Info 'b.mp4' -Fps 25))
    Assert-True ((Test-Uniform -Infos $infos) -match 'fps')
}

Check 'uniform: audio mono vs stereo dikesan' {
    $infos = @((New-Info 'a.mp4'), (New-Info 'b.mp4' -Ch 1))
    Assert-True ((Test-Uniform -Infos $infos) -match 'channel')
}

# ---- 4. normalisasi & kualiti ----------------------------------------------
Check 'filter: dimensi maksimum dibundarkan genap' {
    $infos = @((New-Info 'a.mp4' -W 1921 -H 1081), (New-Info 'b.mp4' -W 1280 -H 720 -Fps 24))
    $f = Get-NormalizeFilter -Infos $infos
    Assert-True ($f -match 'scale=1920:1080') "dapat: $f"
    Assert-True ($f -match 'fps=30')
}

Check 'fps sasaran: mode, bukan maksimum' {
    $infos = @()
    for ($i = 0; $i -lt 5; $i++) { $infos += (New-Info "a$i.mp4" -Fps 59.94) }
    $infos += (New-Info 'slowmo.mp4' -Fps 100)
    Assert-Equal (Get-TargetFps -Infos $infos) 59.94
}

Check 'fps sasaran: force menang' {
    $infos = @((New-Info 'a.mp4' -Fps 59.94), (New-Info 'b.mp4' -Fps 100))
    Assert-Equal (Get-TargetFps -Infos $infos -ForceFps 60) 60
}

Check 'filter: force fps 60' {
    $infos = @((New-Info 'a.mp4' -Fps 59.94), (New-Info 'b.mp4' -Fps 59.94))
    $f = Get-NormalizeFilter -Infos $infos -ForceFps 60
    Assert-True ($f -match 'fps=60(,|$)') "filter: $f"
}

Check 'crf default ikut tahap' {
    Assert-Equal (Get-EncodeSettings -Q 'high' -CrfOverride 0 -Preset medium -Mode hevc).Crf 20
    Assert-Equal (Get-EncodeSettings -Q 'balanced' -CrfOverride 0 -Preset medium -Mode hevc).Crf 23
    Assert-Equal (Get-EncodeSettings -Q 'small' -CrfOverride 0 -Preset medium -Mode hevc).Crf 28
    Assert-Equal (Get-EncodeSettings -Q 'small' -CrfOverride 18 -Preset medium -Mode hevc).Crf 18
}

# ---- 4b. enkoder GPU/CPU -----------------------------------------------------
Check 'encoder plan: cpu guna crf' {
    $p = Get-EncoderPlan -Encoder 'cpu' -Mode 'hevc' -Q 'balanced' -CrfOverride 0 -Preset 'medium'
    Assert-Equal $p.Codec 'libx265'
    Assert-True (($p.Args -join ' ') -match '-crf 23') "args: $($p.Args -join ' ')"
}

Check 'encoder plan: nvenc guna cq + preset p5' {
    $p = Get-EncoderPlan -Encoder 'nvenc' -Mode 'hevc' -Q 'balanced' -CrfOverride 0 -Preset 'medium'
    Assert-Equal $p.Codec 'hevc_nvenc'
    $a = $p.Args -join ' '
    Assert-True ($a -match '-cq 22') "args: $a"
    Assert-True ($a -match '-preset p5') "args: $a"
    Assert-True ($a -match '-b:v 0') "args: $a"
}

Check 'encoder plan: nvenc gpu index' {
    $p = Get-EncoderPlan -Encoder 'nvenc' -Mode 'hevc' -Q 'balanced' -CrfOverride 0 -Preset 'medium' -GpuDevice 1
    Assert-True (($p.Args -join ' ') -match '-gpu 1') "args: $($p.Args -join ' ')"
}

Check 'encoder plan: qsv guna global_quality' {
    $p = Get-EncoderPlan -Encoder 'qsv' -Mode 'h264' -Q 'high' -CrfOverride 0 -Preset 'slow'
    Assert-Equal $p.Codec 'h264_qsv'
    Assert-True (($p.Args -join ' ') -match '-global_quality 20')
}

Check 'encoder plan: amf guna cqp' {
    $p = Get-EncoderPlan -Encoder 'amf' -Mode 'hevc' -Q 'small' -CrfOverride 0 -Preset 'medium'
    Assert-Equal $p.Codec 'hevc_amf'
    Assert-True (($p.Args -join ' ') -match '-qp_i 28')
}

Check 'encoder codec mapping' {
    Assert-Equal (Get-EncoderCodec -Encoder 'nvenc' -Mode 'hevc') 'hevc_nvenc'
    Assert-Equal (Get-EncoderCodec -Encoder 'nvenc' -Mode 'h264') 'h264_nvenc'
    Assert-Equal (Get-EncoderCodec -Encoder 'cpu' -Mode 'hevc') 'libx265'
}

Check 'Resolve-Encoder: cpu sentiasa berfungsi' {
    $ff = (Get-Command ffmpeg).Source
    Assert-Equal (Resolve-Encoder -Requested 'cpu' -Mode 'hevc' -FFmpegPath $ff) 'cpu'
}

Check 'Resolve-Encoder: nvenc ikut ketersediaan mesin' {
    $ff = (Get-Command ffmpeg).Source
    $usable = Test-EncoderUsable -Encoder 'nvenc' -Mode 'hevc' -FFmpegPath $ff
    if ($usable) {
        Assert-Equal (Resolve-Encoder -Requested 'nvenc' -Mode 'hevc' -FFmpegPath $ff) 'nvenc'
    }
    else {
        $threw = $false
        try { [void] (Resolve-Encoder -Requested 'nvenc' -Mode 'hevc' -FFmpegPath $ff) } catch { $threw = $true }
        Assert-True $threw 'patut gagal bila NVENC tiada'
    }
}

Check 'ruang disk: tolak bila tak cukup' {
    $tmp = Join-Path $TmpBase ('vs-space-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $threw = $false
        try { Assert-FreeSpace -OutPath (Join-Path $tmp 'o.mp4') -NeedBytes 100TB } catch { $threw = $true }
        Assert-True $threw 'patut tolak 100TB'
        Assert-FreeSpace -OutPath (Join-Path $tmp 'o.mp4') -NeedBytes 1KB
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'saiz input dijumlah' {
    $tmp = Join-Path $TmpBase ('vs-sum-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.bin'; $b = Join-Path $tmp 'b.bin'
        [System.IO.File]::WriteAllBytes($a, [byte[]]::new(1000))
        [System.IO.File]::WriteAllBytes($b, [byte[]]::new(2345))
        Assert-Equal (Get-TotalInputBytes -Paths @($a, $b)) 3345
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- 5. cantuman sebenar (ffmpeg) -------------------------------------------
# CLI dijalankan melalui fail job .ps1 (sama macam GUI buat) supaya binding
# parameter betul dan exit code sebenar diuji.
$psExe = (Get-Process -Id $PID).Path
function Quote-PS { param([string] $s) return "'" + $s.Replace("'", "''") + "'" }

function Invoke-Cli {
    param(
        [string[]] $Files, [string] $Out, [string] $Mode = 'copy',
        [string] $Quality = 'balanced', [string] $Preset = 'medium',
        [double] $Fps = 0, [switch] $StrictFps, [string] $State, [string] $Progress, [string] $Log
    )
    $fileList = ($Files | ForEach-Object { Quote-PS $_ }) -join ','
    $cmd = "& " + (Quote-PS $cli) + " -Files $fileList -Out " + (Quote-PS $Out) + " -Mode $Mode"
    if ($Mode -ne 'copy') { $cmd += " -Quality $Quality -Preset $Preset" }
    if ($Fps -gt 0) { $cmd += " -Fps $Fps" }
    if ($StrictFps) { $cmd += ' -StrictFps' }
    if ($State)    { $cmd += " -State " + (Quote-PS $State) }
    if ($Progress) { $cmd += " -Progress " + (Quote-PS $Progress) }
    if ($Log)      { $cmd += " -Log " + (Quote-PS $Log) }
    $job = Join-Path $TmpBase ('vs-job-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    $cmd = $cmd + "`nexit `$LASTEXITCODE`n"
    [System.IO.File]::WriteAllText($job, $cmd, [System.Text.UTF8Encoding]::new($false))
    try { return (& $psExe -NoProfile -File $job 2>&1) }
    finally { Remove-Item -LiteralPath $job -Force -ErrorAction SilentlyContinue }
}

function New-TestClip {
    param([string] $Path, [string] $Color = 'red', [int] $Seconds = 2)
    $o = & ffmpeg -v error -y -f lavfi -i "color=c=${Color}:s=320x240:r=30:d=$Seconds" `
             -f lavfi -i "sine=f=440:d=$Seconds" -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gagal jana klip: $Path :: $($o -join ' | ')" }
}

Check 'copy + force fps ditolak' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-fps-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.mp4'; $b = Join-Path $tmp 'b.mp4'
        New-TestClip -Path $a -Color red -Seconds 1
        New-TestClip -Path $b -Color blue -Seconds 1
        $r = Invoke-Cli -Files @($a, $b) -Out (Join-Path $tmp 'o.mp4') -Mode copy -Fps 60
        $txt = ($r -join "`n")
        Assert-True ($LASTEXITCODE -ne 0) 'sepatutnya gagal'
        Assert-True ($txt -match 'cannot change frame rate') "message: $txt"
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'cantuman copy + hevc pada klip sebenar' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $clips = @()
        for ($i = 1; $i -le 3; $i++) {
            $c = Join-Path $tmp ("clip{0}.mp4" -f $i)
            New-TestClip -Path $c -Color @('red', 'green', 'blue')[$i - 1]
            $clips += $c
        }
        $out = Join-Path $tmp 'out.mp4'
        $r = Invoke-Cli -Files $clips -Out $out -Mode copy `
              -State (Join-Path $tmp 'state.txt') -Progress (Join-Path $tmp 'p.txt') -Log (Join-Path $tmp 'l.txt')
        Assert-Equal $LASTEXITCODE 0 ($r -join ' | ')

        $probe = & ffprobe -v error -show_entries format=duration -of csv=p=0 $out
        Assert-True ([double] $probe -gt 5.8) "durasi $probe"
        Assert-True ((Get-Content (Join-Path $tmp 'state.txt') -Raw) -match 'STATUS=DONE')

        $out2 = Join-Path $tmp 'out-hevc.mp4'
        $r2 = Invoke-Cli -Files $clips -Out $out2 -Mode hevc -Quality small -Preset ultrafast `
               -State (Join-Path $tmp 'state2.txt') -Progress (Join-Path $tmp 'p2.txt') -Log (Join-Path $tmp 'l2.txt')
        Assert-Equal $LASTEXITCODE 0 ($r2 -join ' | ')
        $codec = & ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 $out2
        Assert-Equal $codec 'hevc'
        Assert-True (Test-Path (Join-Path $tmp 'p2.txt')) 'fail progress tak ditulis'
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'cantuman dengan apostrof dalam nama fail' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-quote-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp "it's a.mp4"
        $b = Join-Path $tmp 'b"c.mp4'
        New-TestClip -Path $a -Color red -Seconds 1
        New-TestClip -Path $b -Color blue -Seconds 1
        $out = Join-Path $tmp 'o.mp4'
        $r = Invoke-Cli -Files @($a, $b) -Out $out -Mode copy `
              -State (Join-Path $tmp 's.txt') -Progress (Join-Path $tmp 'p.txt') -Log (Join-Path $tmp 'l.txt')
        Assert-Equal $LASTEXITCODE 0 ($r -join ' | ')
        $dur = & ffprobe -v error -show_entries format=duration -of csv=p=0 $out
        Assert-True ([double] $dur -gt 1.8) "durasi $dur"
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'CLI -Version cetak versi' {
    $r = & $psExe -NoProfile -File $cli -Version
    Assert-Equal ($r -join '').Trim() '0.3.1'
}

Check 'senarai fail dalam satu argumen koma (-File)' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-comma-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.mp4'; $b = Join-Path $tmp 'b.mp4'
        New-TestClip -Path $a -Color red -Seconds 1
        New-TestClip -Path $b -Color blue -Seconds 1
        $out = Join-Path $tmp 'o.mp4'
        # & $psExe -File TIDAK memecah koma; CLI mesti uruskan sendiri.
        $r = & $psExe -NoProfile -File $cli -Files ($a + ',' + $b) -Out $out -Mode copy 2>&1
        Assert-Equal $LASTEXITCODE 0 ($r -join ' | ')
        $dur = & ffprobe -v error -show_entries format=duration -of csv=p=0 $out
        Assert-True ([double] $dur -gt 1.8) "durasi $dur"
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'output tidak boleh sama dengan input' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-same-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.mp4'
        New-TestClip -Path $a -Color red -Seconds 1
        $r = Invoke-Cli -Files @($a) -Out $a -Mode copy
        $txt = ($r -join "`n")
        Assert-True ($LASTEXITCODE -ne 0) 'sepatutnya gagal'
        Assert-True ($txt -match 'also listed as input') "message: $txt"
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'copy: fps beza besar (30 vs 25) ditolak' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-fpsbig-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.mp4'; $b = Join-Path $tmp 'b.mp4'
        New-TestClip -Path $a -Color red -Seconds 1
        & ffmpeg -v error -y -f lavfi -i "color=c=blue:s=320x240:r=25:d=1" -f lavfi -i "sine=f=440:d=1" `
                 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac $b
        $r = Invoke-Cli -Files @($a, $b) -Out (Join-Path $tmp 'o.mp4') -Mode copy
        $txt = ($r -join "`n")
        Assert-True ($LASTEXITCODE -ne 0) 'sepatutnya gagal (fps 30 vs 25)'
        Assert-True ($txt -match 'not safe') "message: $txt"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tmp 'o.mp4'))) 'output tak sepatutnya wujud'
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'copy: fps beza kecil (30 vs 29.97) diteruskan' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-fpssmall-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.mp4'; $b = Join-Path $tmp 'b.mp4'
        New-TestClip -Path $a -Color red -Seconds 1
        & ffmpeg -v error -y -f lavfi -i "color=c=blue:s=320x240:r=30000/1001:d=1" -f lavfi -i "sine=f=440:d=1" `
                 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac $b
        $out = Join-Path $tmp 'o.mp4'
        $r = Invoke-Cli -Files @($a, $b) -Out $out -Mode copy
        $txt = ($r -join "`n")
        Assert-Equal $LASTEXITCODE 0 $txt
        Assert-True (Test-Path -LiteralPath $out) 'output tiada'
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'StrictFps: fps berbeza ditolak' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-strict-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.mp4'; $b = Join-Path $tmp 'b.mp4'
        New-TestClip -Path $a -Color red -Seconds 1
        & ffmpeg -v error -y -f lavfi -i "color=c=blue:s=320x240:r=25:d=1" -f lavfi -i "sine=f=440:d=1" `
                 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac $b
        $r = Invoke-Cli -Files @($a, $b) -Out (Join-Path $tmp 'o.mp4') -Mode copy -StrictFps
        Assert-True ($LASTEXITCODE -ne 0) 'sepatutnya gagal'
        Assert-True (($r -join "`n") -match 'not safe') "message: $($r -join ' | ')"
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'encode: durasi output = jumlah klip (tiada speed-up)' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-fix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.mp4'; $b = Join-Path $tmp 'b.mp4'; $c = Join-Path $tmp 'c.mp4'
        New-TestClip -Path $a -Color red -Seconds 2
        & ffmpeg -v error -y -f lavfi -i "color=c=green:s=640x480:r=25:d=2" -f lavfi -i "sine=f=660:d=2" `
                 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac $b
        New-TestClip -Path $c -Color blue -Seconds 1
        $out = Join-Path $tmp 'o.mp4'
        $r = Invoke-Cli -Files @($a, $b, $c) -Out $out -Mode hevc -Quality small -Preset ultrafast
        Assert-Equal $LASTEXITCODE 0 ($r -join ' | ')
        $dur = [double] (& ffprobe -v error -show_entries format=duration -of csv=p=0 $out)
        Assert-True ($dur -gt 4.7 -and $dur -lt 5.3) "durasi $dur (jangka ~5s)"
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'mod copy menolak klip tak seragam' {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw 'ffmpeg tiada' }
    $tmp = Join-Path $TmpBase ('vs-mix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $a = Join-Path $tmp 'a.mp4'
        $b = Join-Path $tmp 'b.mp4'
        New-TestClip -Path $a -Color red
        & ffmpeg -v error -y -f lavfi -i "color=c=blue:s=640x480:r=25:d=2" -f lavfi -i "sine=f=440:d=2" `
                 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac $b
        $out = Join-Path $tmp 'out.mp4'
        $r = Invoke-Cli -Files @($a, $b) -Out $out -Mode copy `
              -State (Join-Path $tmp 's.txt') -Progress (Join-Path $tmp 'p.txt') -Log (Join-Path $tmp 'l.txt')
        $txt = ($r -join "`n")
        Assert-True ($LASTEXITCODE -ne 0) 'sepatutnya gagal'
        Assert-True ($txt -match 'not safe|not uniform') "message: $txt"
        Assert-True (-not (Test-Path -LiteralPath $out)) 'output tak sepatutnya wujud'
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ("Keputusan: {0} lulus, {1} gagal" -f $pass, $fail) -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 }
exit 0
