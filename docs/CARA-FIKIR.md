# CARA FIKIR — kenapa videoStitch direka begini

Dokumen ini rekod keputusan reka bentuk + tradeoff. Bukan tutorial; ini sebab di sebalik setiap pilihan.

---

## 0. Masalah

Rafi perlukan alat **ringkas** untuk cantum banyak klip video pada Windows 11:

1. Drag & drop banyak fail
2. Susunan fail = susunan cantuman, default ikut nama
3. Butang folder target
4. Pilihan output **HEVC** + tahap kualiti
5. Tekan **Run** → ia buat arahan CLI, buka PowerShell, jalankan
6. Ada **progress bar**
7. GUI **boleh terus ditutup** — job mesti diteruskan

Kekangan tambahan: mesin sasaran Windows 11, tiada install Python/Node/.NET SDK, dan Rafi nak repo GitHub lengkap dengan markdown.

---

## 1. Prinsip: CLI enjin, GUI pembalut — tetapi dua-dua boleh berdiri sendiri

Tiga pilihan seni bina:

| Pilihan | Baik | Buruk |
|---|---|---|
| A. Semua logik dalam GUI | satu fail | tak boleh skrip/automate; GUI kena buka untuk apa-apa kerja |
| B. GUI jadi wrapper nipis: terus panggil ffmpeg | kurang lapisan | GUI = enjin; tiada CLI; progress/log sukar dikongsi |
| C. **CLI = enjin, GUI = penjana arahan** ✅ | skrip + GUI kongsi satu enjin; arahan boleh disalin & dijalankan manual; audit mudah | dua fail perlu diselaraskan (kontrak parameter) |

Pilih **C**. GUI tak "terikat" pada CLI dalam erti kata ia tetap berfungsi untuk drag-drop, susunan, pilih kualiti, dan papar arahan walaupun job tak dijalankan. CLI pula boleh dipakai tanpa GUI langsung. Titik sentuh cuma satu: GUI menulis `job.ps1` yang memanggil `bin/stitch.ps1` dengan parameter tetap.

Kontrak itu didokumenkan (`README.md` §4) supaya perubahan parameter tak senyap-senyap merosakkan GUI.

---

## 2. Kenapa PowerShell + WinForms, bukan Electron / Python / .NET

| Calon | Saiz install | Nota |
|---|---|---|
| Electron | ~150 MB | berat; satu app untuk kerja 200 baris |
| Python + tkinter | perlu Python | Windows 11 tak ada Python lalai |
| .NET WinForms (C#) | perlu SDK untuk build, atau exe perlu di-sign | build chain tambahan |
| **PowerShell 5.1 + WinForms** ✅ | **0 MB** | sudah ada dalam Windows 11; `Add-Type -AssemblyName System.Windows.Forms` cukup |

Kekurangan PowerShell: strictness kurang, event handler guna scriptblock, error senang senyap. Ditangani dengan `try/catch` + `MessageBox` pada setiap handler dan ujian berasingan.

Alternatif PowerShell + WPF (XAML) lebih cantik tetapi XAML dalam string PowerShell susah dinaik taraf; WinForms kod terus lebih mudah di audit.

---

## 2a. Installer: per-user, tanpa admin

| Keputusan | Pilihan | Sebab |
|---|---|---|
| Lokasi | `%LOCALAPPDATA%\Programs\videoStitch` | tiada UAC; uninstall bersih; user biasa boleh pakai |
| Shortcut | Desktop + Start Menu | orang cari app di dua tempat itu |
| Daftar | HKCU `...\Uninstall\videoStitch` | muncul dalam Settings → Apps tanpa admin |
| Satu fail | `Setup-videoStitch.cmd` → `setup.ps1` | pengguna hanya klik satu fail; logik kekal dalam PS (senang debug) |
| Compile | ps2exe, **fallback** `VideoStitch.cmd` | installer tak boleh gagal hanya kerana PSGallery tak dapat diakses |

Kenapa `Setup-videoStitch.cmd` bukan `.exe` installer (Inno/NSIS)? Membina `.exe` installer perlu Windows + toolchain; repo dibangunkan di macOS. `.cmd` satu-fail memuat turun zip rilis sendiri, jadi tiada build step di sisi kami dan tiada fail tersimpan dalam git.

Risiko yang diterima: `.cmd` boleh disekat oleh polisi organisasi → README sediakan laluan manual (`install.cmd` atau portable).

---

## 2b. Bila perlu .exe: ps2exe vs C# self-contained

| Cara | Masa | Saiz | Keperluan pengguna | Status |
|---|---|---|---|---|
| PowerShell + `gui.cmd` | 0 minit | 0 | PowerShell 5.1 (ada) | ✅ v0.1.2 |
| **ps2exe** (`build-exe.ps1`) | ~2 minit | ~200–400 KB | PowerShell 5.1 + .NET Framework (ada) | ✅ v0.1.2 |
| C# port + `dotnet publish --self-contained` | 1–2 hari | ~70–150 MB | tiada (runtime dibundel) | ❌ belum |

ps2exe dipilih kerana: (a) tak perlu tulis semula 900 baris logik dalam C#, (b) tiada risiko regresi logik yang sudah diuji, (c) Windows 11 sentiasa ada PowerShell 5.1. Kelemahan: exe masih bergantung pada PowerShell, dan AV kadang flag pembalut PowerShell sebagai suspek (false positive).

Bila `-noConsole` dipakai, `$PSScriptRoot` dalam skrip yang dikompil menunjuk folder sementara (ps2exe extract). Sebab itu GUI ada `Get-BaseDir` yang mencuba `$env:VIDEOSTITCH_ROOT` → folder skrip → folder exe (`[Environment]::GetCommandLineArgs()[0]`), dan hanya terima calon yang ada `bin\stitch.ps1`. Tanpa ini, GUI bertukar jadi exe tak jumpa enjin.

---

## 3. Kenapa job dijalankan **detached** dalam tetingkap PowerShell baru

Keperluan "GUI boleh terus tutup" menghalang `Start-Process -Wait` atau `&` dalam GUI (job mati bila GUI mati). Pilihan:

| Cara | Bila GUI tutup | Progress |
|---|---|---|
| `& ffmpeg` dalam GUI | job mati | senang (baca stdout) |
| `Start-Process` tanpa wait, GUI poll fail | job hidup ✅ | perlu fail perantara |
| Windows service / scheduled task | hidup | overkill, susah debug |

Pilih tengah: GUI tulis `job.ps1` → `Start-Process powershell.exe -File job.ps1` → proses itu pemilik job. GUI poll dua fail:

- `state.txt` — ditulis CLI: `TOTAL=`, `MODE=`, `STATUS=PROBE|RUNNING|DONE|ERROR`
- `ffprogress.txt` — ditulis ffmpeg sendiri (`out_time_us=` setiap ~0.5 s)

Kenapa dua fail, bukan satu?

- `ffmpeg -progress <file>` **menulis semula** (truncate) fail itu setiap blok. Kalau CLI tulis `TOTAL=` ke fail sama, ia hilang pada update pertama.
- Jadi: `ffprogress.txt` milik ffmpeg sepenuhnya; `state.txt` milik CLI. GUI baca dua-dua, kira `pct = out_time_us/1e6 / TOTAL`.

Kelebihan sampingan: `state.txt` kekal selepas job tamat → GUI yang dibuka semula (atau dibuka lambat) masih nampak status akhir.

Tradeoff: GUI yang ditutup tak dapat tunjuk notifikasi siap. Diterima — konsol PowerShell kekal terbuka (`-NoExit`) dan tulis "Job SIAP: ...".

---

## 4. Copy vs encode: kenapa ada dua-dua, dan kenapa CRF 20/23/28

Ukuran pada mesin ujian (arm64, SSD, 3 klip 1080p30 ×10 s, 55 MB total):

| Kerja | Masa |
|---|---|
| concat `-c copy` | **0.082 s** |
| concat re-encode (x264 veryfast) | **2.292 s** (~28×) |

Maksudnya: `copy` bukan "sedikit lebih laju" — ia kategori berbeza. Jadi default mesti `copy`, dan encode hanya bila perlu (klip tak seragam atau nak saiz kecil/HEVC).

Syarat `copy` (semua mesti sama) diuji eksplisit: codec video, W×H, fps, pix_fmt, codec audio, sample rate, channel. Kalau tak, CLI **gagal dengan senarai isu** — bukan auto-encode senyap (pengguna mungkin tak perasan kualiti turun / masa habis).

CRF dipilih, bukan bitrate: bitrate tetap memberi kualiti tak sekata antara klip (adegan gelap vs terang). CRF mengekalkan kualiti subjektif merentas kandungan.

| CRF | Sebab |
|---|---|
| 20 | tinggi; mata tak nampak beza pada kebanyakan kandungan, saiz ~1.5–2× CRF 23 |
| 23 | titik seimbang umum (default x265/x264 komuniti) |
| 28 | kecil; jelas pada tekstur halus/gradien tapi memadai untuk arkib |

Preset `medium` default: x265 `medium` sudah ~2× lebih lambat dari x264 `veryfast` tetapi jauh lebih kecil; `slow/placebo` hanya untuk encode akhir sekali-sekala.

`-tag:v hvc1` ditambah untuk HEVC supaya QuickTime/iOS main. Tanpa `hvc1`, sesetengah player Apple menolak.

---

## 4b. GPU vs CPU: pemetaan kualiti, bukan sekadar tukar codec

Nilai CRF tak boleh dipindah terus antara enjin. Setiap enjin ada skala sendiri:

| Enjin | Parameter kualiti | Pemetaan (high/balanced/small) |
|---|---|---|
| libx265/libx264 | `-crf` | 20 / 23 / 28 |
| hevc_nvenc | `-cq` (VBR, `-b:v 0`) | 19 / 22 / 27 |
| hevc_qsv | `-global_quality` | 20 / 23 / 28 |
| hevc_amf | `-qp_i/-qp_p` (CQP) | 20 / 23 / 28 |
| hevc_mf | `-b:v` (tiada CRF) | 10M / 6M / 3M |

Kenapa NVENC CQ = CRF−1? CQ NVENC pada nombor sama menghasilkan kualiti sedikit lebih rendah daripada x265 CRF (NVENC tiada psy-rd/adaptive quant penuh). Offset 1 mata mendekatkan hasil visual tanpa membesarkan fail banyak.

Kenapa `-rc vbr -cq N -b:v 0`? `-b:v 0` mematikan siling bitrate supaya enjin benar-benar mengikut CQ; tanpa itu NVENC boleh clamp pada default bitrate.

Pengesanan: `Test-EncoderUsable` buat dua semakan — (1) codec wujud dalam senarai `ffmpeg -encoders`, (2) encode ujian 0.2 s pada peranti sebenar. Semakan (2) penting sebab driver boleh ada codec tapi tiada peranti (cth. VM, RDP, GPU virtual seperti Parsec — codec nampak ada tapi `Cannot load nvcuda.dll`). Tanpa semakan ini, auto-detect akan pilih GPU yang gagal pada klip pertama.

Preset dipetakan: CPU `veryfast/medium/slow`; NVENC `p3/p5/p7`; AMF `speed/balanced/quality`. Default `medium`→`p5`.

**Pilih GPU tertentu.** GUI bina senarai daripada perkakasan sebenar: `nvidia-smi --query-gpu=name` untuk setiap kad NVIDIA (dengan indeks), WMI `Win32_VideoController` untuk Intel/AMD. Pilihan dihantar sebagai `-Encoder <jenis> -GpuDevice <n>`; untuk NVENC itu jadi `-gpu n` pada ffmpeg. Kekangan: QSV/AMF di Windows tak mendedahkan pemilih peranti yang bersih dalam ffmpeg, jadi satu-satunya kad Intel/AMD digunakan secara lalai — sebab itu GUI menyenaraikan satu baris per vendor, bukan per kad seperti NVENC. GPU maya (Parsec/RDP) sengaja tidak disenaraikan sebagai enkod sebab biasanya tiada permukaan enkod sebenar; `Test-EncoderUsable` akan menolaknya juga.

Tradeoff diterima: GPU encode pada CQ sepadan biasanya 1.2–1.8× lebih besar daripada x265 pada kualiti sama, tetapi 5–25× lebih laju. Untuk kerja arkib sekali-sekala, CPU masih berbaloi; untuk iterasi pantas, GPU.

---

## 4c. Paksa fps: kenapa hanya dalam mod encode

`-c copy` menyalin paket asal; mengubah fps bermakna mengubah PTS setiap frame — itu kerja re-encode. Jadi `-Fps` hanya dipakai dalam `-Mode hevc/h264` (melalui filter `fps=`), dan CLI menolak kombinasi `copy + -Fps` dengan mesej jelas (bukan senyap mengabaikan).

Kesan sampingan yang didokumen: `fps=60` pada sumber 59.94 menduplikasi ~0.06% frame (tak ketara), tetapi `fps=60` pada sumber 30 menduplikasi 50% frame — fail membesar tanpa gerakan lebih licin. Untuk gerakan lebih licin sebenar perlu interpolation (`minterpolate`), yang jauh lebih berat dan belum dimasukkan.

---

## 4d. fps = isu "lembut" untuk stream copy

Klip kamera kerap melaporkan fps bercanggah walaupun kadar sebenar sama (DJI: `r_frame_rate=100/1`, `avg_frame_rate=60000/1001`; ada juga yang `avg_frame_rate=100/1`). Menolak Copy atas dasar fps sahaja menyekat kerja yang sebenarnya selamat.

Keputusan: dalam `Copy`, isu fps dikelaskan **lembut** — beri amaran, teruskan. Isu **keras** (codec, resolusi, pix_fmt, audio) kekal menolak. `-StrictFps` mempromosikan fps ke keras untuk pengguna yang mahu ketat.

Risiko diterima: kalau klip benar-benar 30 vs 60 fps, cantuman copy boleh menghasilkan masa yang ganjil di titik sambung. Dinyatakan dalam amaran: "If playback glitches at a join, re-run with -Mode hevc."

---

## 5. Natural sort, bukan ordinal

Ordinal (`Get-ChildItem | Sort-Object Name`) susun `clip10.mp4` **sebelum** `clip2.mp4` — salah untuk senarai rakaman kamera. Algoritma dipakai:

1. pecah nama kepada siri `\d+` dan `\D+`
2. banding bahagian digit sebagai nombor, bahagian teks sebagai huruf kecil ordinal
3. tie-break: laluan penuh ordinal (deterministik)

Ujian: `clip1,clip2,clip10` → `clip1,clip2,clip10`. Dipakai di GUI (butang "Susun ikut nama" + semasa tambah fail) dan boleh dipanggil di CLI (`Sort-FilesNatural`, didedah untuk test).

Kenapa tak `Sort-Object { [int]($_.BaseName -replace '\D','') }`? Gagal untuk nama bercampur (`Trip 2 Day 3 Part 1`) dan nama tanpa digit. Natural split lebih umum.

---

## 6. Normalisasi klip sebelum encode

Bila encode, klip berlainan resolusi/fps/aspect menyebabkan: output "terlonjak", audio desync, atau ffmpeg gagal (`width not divisible by 2`). Filter dipasang:

```
scale=W:H:force_original_aspect_ratio=decrease:force_divisible_by=2,
pad=W:H:(ow-iw)/2:(oh-ih)/2,
setsar=1,
fps=F
```

- `W,H` = **maksimum** semua input, dibundarkan ke nombor genap (yuv420p perlukan genap)
- `decrease` + `pad` = kekalkan aspect, tambah bar hitam (bukan regang)
- `setsar=1` = elak SAR ganjil dari telefon
- `fps` = fps tertinggi antara klip (tak buang frame)

Untuk `copy`, normalisasi **tidak** digunakan — sebab itu keseragaman wajib.

---

## 6b. ffmpeg auto-install: opt-in, bukan senyap

Klip tak boleh dicantum tanpa ffmpeg. Tiga pilihan:

| Pilihan | Risiko |
|---|---|
| Gagal + tunjuk arahan | pengguna tersekat; ramai tak tahu winget |
| Pasang senyap | menyentuh sistem tanpa izin — tidak boleh diterima |
| **Tanya dulu / flag `-Install`** ✅ | selamat; satu langkah tambahan |

Auto-pasang guna `winget install -e --id Gyan.FFmpeg` (Microsoft, build Gyan). Selepas pasang, `Get-FFmpegPath` juga menyemak `%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe` kerana PATH sesi semasa tidak dikemas kini secara automatik.

Kenapa bukan `choco`/`scoop`? Kedua-duanya perlu dipasang dahulu. Winget ada pada Windows 11 secara lalai — laluan paling sedikit geseran.

---

## 7. Quoting & encoding: dua perangkap yang dibetulkan awal

**(a) Laluan berjalan melalui 3 lapisan shell.** GUI → `job.ps1` → `stitch.ps1` → `Start-Process` → ffmpeg. Setiap lapisan ada quoting sendiri:

- Dalam PowerShell: laluan dibalut `'...'` dengan `'` → `''` (fungsi `Quote-PS`)
- Hantar ke `Start-Process -ArgumentList`: satu **string** arahan dengan `"..."` di sekeliling setiap laluan (Start-Process tak quote sendiri untuk array)
- Fail concat ffmpeg: `file '<path>'`, `\` → `/`, `'` dalam nama → guna `"..."` + escape `\"`

**(b) `-File` tidak memecah koma.** PowerShell `-File skrip.ps1 -Files a.mp4,b.mp4` menghantar **satu** string `a.mp4,b.mp4`; `[string[]]` jadi array 1 elemen, dan `Test-Path` gagal. Ini bukan pilihan reka bentuk — ia had `-File`. Penyelesaian: CLI ada `Expand-Files` yang memecah koma / `;` / baris baru bila elemen tunggal bukan fail sebenar. Tanpa ini, `stitch.cmd -Files a.mp4,b.mp4` mustahil berfungsi.

**(c) Encoding skrip.** PowerShell 5.1 baca fail `.ps1` tanpa BOM sebagai ANSI → aksara BM dalam `MessageBox`/label jadi mojibake. Jadi fail `.ps1` ditulis **UTF-8 dengan BOM** (walaupun sekarang semua aksara ASCII, BOM mengelak kejutan bila teks BM ditambah kemudian). Fail concat ditulis UTF-8 **tanpa** BOM (ffmpeg baca bytes; BOM akan jadi sebahagian nama fail pertama).

---

## 7b. Perangkap exit code: `exit` dalam skrip yang dipanggil TIDAK merebak

Semasa ujian, `job.ps1` lapor rc=0 walaupun `stitch.ps1` gagal. Punca: dalam PowerShell, `exit` di dalam skrip yang dipanggil dengan `&` hanya menamatkan skrip itu dan menetapkan `$LASTEXITCODE`; ia **tidak** menamatkan pemanggil. Jadi setiap pembalut (`job.ps1` GUI dan `job.ps1` ujian) mesti berakhir dengan:

```powershell
exit $LASTEXITCODE
```

Tanpa itu, status akhir job sentiasa 0. Ini dibetulkan dan diuji (ujian `mod copy menolak klip tak seragam` bergantung padanya).

---

## 8. Had yang diketahui

1. **Belum diuji pada Windows 11 sebenar.** Mesin pembangunan macOS. Yang diuji: logik CLI (natural sort, uniformiti, concat copy/HEVC, progress, state) guna PowerShell 7 + ffmpeg; sintaks kedua-dua skrip di-parse. GUI WinForms hanya boleh diuji pada Windows.
2. `<video>` set `copy` memerlukan codec sama **termasuk profil/level**; perbezaan profil kadang lolos semakan struktur tapi output boleh rosak. Langkah seterusnya: banding `codec_tag_string`/profile.
3. Re-encode tak guna hardware (NVENC/QSV/AMF). Untuk HEVC 4K, `hevc_nvenc` ~5–10× lebih laju. Belum dimasukkan sebab kualiti bitrate per-hardware berbeza dan ujian tak lengkap.
4. Progress untuk `copy` hampir tak kelihatan (kerja <1 s); bar terus 100%.
5. Tiada `-map` manual: audio pertama sahaja diambil; multi-track/stream data dibuang.

---

## 9. Data flow penuh

```
[drag-drop] ─► ListBox (susunan)
                 │
         [Mula]  ▼
     job.ps1 = "& '<repo>\bin\stitch.ps1' -Files 'a.mp4','b.mp4' -Out ... -Mode hevc"
                 │
        Start-Process powershell.exe -File job.ps1   (detached, -NoExit)
                 │
                 ├─ probe (ffprobe JSON) → state.txt: TOTAL=..., STATUS=PROBE
                 ├─ sahkan keseragaman
                 ├─ tulis concat.txt (UTF-8 no BOM, "/" path)
                 ├─ Start-Process ffmpeg -progress ffprogress.txt -loglevel error
                 │     └─ tiap 400ms: baca ffprogress → bar konsol CLI
                 └─ tamat → state.txt: STATUS=DONE|ERROR rc=...
                              │
                 GUI poll 400ms: state.txt + ffprogress.txt → ProgressBar
```

---

## 10. Ringkasan keputusan

| # | Keputusan | Sebab utama |
|---|---|---|
| 1 | CLI enjin, GUI penjana arahan | satu enjin, GUI tak terikat, arahan boleh diaudit/salin |
| 2 | PowerShell 5.1 + WinForms | 0 install pada Windows 11 |
| 3 | Job detached + state/ffprogress file | GUI boleh tutup |
| 4 | `copy` default, encode opt-in, CRF 20/23/28 | copy 28× lebih laju; CRF kekal kualiti |
| 5 | Natural sort | `clip2` sebelum `clip10` |
| 6 | scale+pad+setsar+fps | klip heterogen selamat |
| 7 | UTF-8 BOM (.ps1) / no-BOM (concat) | PS5.1 ANSI trap, ffmpeg raw bytes |
| 8 | `-tag:v hvc1` | keserasian Apple |
| 9 | auto-install ffmpeg opt-in | selamat, tak sentuh sistem tanpa izin |
