# videoStitchWinCLIGUI

Cantum (stitch / concat) banyak klip video jadi **satu fail** — GUI WinForms ringkas + CLI PowerShell, untuk **Windows 11**. Sifar dependency selain `ffmpeg`.

> GUI dan CLI ialah dua alat berasingan. GUI **tidak** memerlukan CLI untuk drag-drop, susun, pilih kualiti — tetapi bila tekan **Mula**, GUI menjana arahan CLI dan menjalankannya dalam tetingkap PowerShell **berasingan**, jadi GUI boleh terus ditutup.

---

## 1. Apa ia buat

| | |
|---|---|
| Drag & drop | Lepas banyak fail (atau folder) terus ke dalam senarai |
| Susunan | Senarai = susunan cantuman; default **susun ikut nama** (natural: `clip2` sebelum `clip10`) |
| Folder target | Butang pilih folder output, atau pilih nama fail |
| Mod output | `Copy` (sifar encode) · `HEVC/H.265` · `H.264` |
| Kualiti | CRF 20 / 23 / 28 + preset x264/x265 |
| Progress | Progress bar dari fail `-progress` ffmpeg |
| Tutup GUI | Job diteruskan oleh proses PowerShell sendiri (detached) |

---

## 2. Syarat

- Windows 11 (PowerShell 5.1 sudah ada — tiada install tambahan)
- **ffmpeg** dalam `PATH`

```powershell
winget install -e --id Gyan.FFmpeg
# tutup & buka semula terminal, kemudian:
ffmpeg -version
```

Kalau ffmpeg tak masuk PATH, letak `ffmpeg.exe` + `ffprobe.exe` dalam folder `bin\` repo, atau guna `-FFmpeg 'C:\...\ffmpeg.exe'`.

---

## 3. Mula pantas — GUI

1. Double-click **`gui.cmd`**
2. Drag & drop klip ke senarai (default susun ikut nama)
3. Betulkan susunan: **Naik / Turun / Buang / Susun ikut nama**
4. Output: **Folder target...** atau **Nama fail...** → default `out.mp4`
5. Mod: `Copy` (laju) atau `HEVC` + kualiti
6. Tekan **Mula** → tetingkap PowerShell terbuka, job berjalan, progress bar hidup
7. **GUI boleh ditutup** — job tak mati. Fail job/log: `%TEMP%\VideoStitch\<masa>-<id>\`

---

## 4. Mula pantas — CLI

```powershell
# copy lossless (semua klip mesti sama codec/resolusi/fps)
.\stitch.cmd -Files 'C:\v\a.mp4','C:\v\b.mp4','C:\v\c.mp4' -Out 'C:\v\out.mp4' -Mode copy

# HEVC, kualiti seimbang (CRF 23)
.\stitch.cmd -Files (Get-ChildItem C:\v\*.mp4 | Sort-Object Name | % FullName) `
             -Out 'C:\v\out.mp4' -Mode hevc -Quality balanced
```

Panggil `bin\stitch.ps1` terus pun sama:

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\bin\stitch.ps1 -Files a.mp4,b.mp4 -Out out.mp4 -Mode hevc
```

| Parameter | Maksud |
|---|---|
| `-Files` | Senarai input, **ikut susunan**. Boleh: `'a.mp4','b.mp4'` (array PowerShell), `"a.mp4,b.mp4"` (satu argumen koma), atau `"a.mp4;b.mp4"` |
| `-Out` | Fail output `.mp4` |
| `-Mode` | `copy` (default) · `hevc` · `h264` |
| `-Quality` | `high` (CRF 20) · `balanced` (CRF 23, default) · `small` (CRF 28) |
| `-Preset` | x264/x265 preset, default `medium` |
| `-Crf` | Override CRF terus (menang atas `-Quality`) |
| `-Progress` `-Log` `-State` | Fail kerja (GUI guna ini) |
| `-FFmpeg` | Laluan `ffmpeg.exe` |

---

## 5. Mod & kualiti

| Mod | Enjin | Bila guna | Kelajuan |
|---|---|---|---|
| `copy` | `-c copy` | Semua klip **seragam** (codec, resolusi, fps, pix_fmt, audio) | ~had disk (GB/s) |
| `hevc` | `libx265` + CRF | Nak fail kecil, klip tak seragam | re-encode, 10–30× lebih lambat |
| `h264` | `libx264` + CRF | Keserasian maksimum (player lama) | re-encode |

**Tahap kualiti (CRF, lebih kecil = lebih bagus & lebih besar):**

| Tahap | CRF | Nota |
|---|---|---|
| Tinggi | 20 | visual ~indistinguishable untuk kebanyakan klip |
| Seimbang | 23 | default; nisbah saiz/kualiti terbaik untuk umun |
| Kecil | 28 | jelas lebih kecil, sedikit soft pada detail halus |

Pada re-encode, GUI/CLI **normalisasi** automatik: `scale` + `pad` (aspect kekal, bar hitam), `setsar=1`, `fps` ikut yang tertinggi. Audio → AAC 192k (atau `-an` kalau tiada audio).

> Kalau mod `copy` tapi klip tak seragam, CLI **berhenti** dengan senarai perbezaan dan cadangan guna `-Mode hevc`. Tiada encode senyap-senyap.

---

## 6. Struktur

```
videoStichWinCLIGUI/
├─ gui.cmd                 # launcher GUI
├─ stitch.cmd              # launcher CLI
├─ bin/stitch.ps1          # enjin + CLI (probe, sahkan, bina arahan, progress)
├─ gui/VideoStitchGUI.ps1  # WinForms GUI (drag-drop, susunan, kualiti, progress)
├─ tests/run-tests.ps1     # ujian (natural sort, uniformiti, list, merge sebenar)
└─ docs/CARA-FIKIR.md      # kenapa ia direka begini (keputusan + tradeoff)
```

Aliran data:

```
GUI ──(jana job.ps1)──► powershell.exe (tetingkap baru, detached)
                                  │
                                  ▼
                        bin/stitch.ps1 ──► ffmpeg ──► out.mp4
                                  │
                     state.txt (TOTAL, STATUS)  ◄── GUI poll 400ms
                     ffprogress.txt (out_time_us)◄── progress bar
```

---

## 7. Ujian

```powershell
.\tests\run-tests.ps1
```

Ujian merangkumi: natural sort (`clip2 < clip10`), escaping laluan concat, pengesanan klip tak seragam, pengiraan saiz normalisasi, dan cantuman sebenar (copy + HEVC) dengan semakan durasi output.

Keputusan pada mesin pembangunan (macOS arm64, PowerShell 7.7.0, ffmpeg 9.0.2):

```
Keputusan: 16 lulus, 0 gagal
```

GUI WinForms tidak boleh dijalankan pada macOS — semak pada Windows:

```powershell
powershell -NoProfile -STA -File gui\VideoStitchGUI.ps1 -SelfTest
```

Ia cetak versi PowerShell, ketersediaan WinForms, laluan ffmpeg, laluan CLI, dan kebolehtulisan `%TEMP%`, tanpa buka tetingkap.

---

## 8. Masalah lazim

| Gejala | Sebab / ubat |
|---|---|
| `ffmpeg tidak dijumpai` | Pasang `winget install -e --id Gyan.FFmpeg`, buka semula terminal |
| `Mod copy tidak selamat` | Klip berbeza codec/resolusi/fps → guna `-Mode hevc` |
| Progress bar tak bergerak | Fail `ffprogress.txt` hanya ditulis selepas ffmpeg mula encode; `copy` sangat laju jadi bar mungkin terus 100% |
| GUI tak buka (tiada tetingkap) | Jalankan `gui.cmd`; jika masih gagal, jalankan `powershell -STA -File gui\VideoStitchGUI.ps1` dan baca ralat, atau `-SelfTest` untuk semakan persekitaran |
| Job tamat bila GUI ditutup | Tidak sepatutnya: job dalam proses `powershell.exe` sendiri. Semak `%TEMP%\VideoStitch\...\state.txt` |
| Output tak main di iPhone/QuickTime | Pastikan mod HEVC (tag `hvc1`) — sudah default |

---

## 9. Lesen

MIT — lihat [LICENSE](LICENSE).

FFmpeg dilesenkan di bawah LGPL/GPL bergantung build; repo ini hanya memanggil executable, tidak mengedar semula.
