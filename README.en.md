# osmo-pocket-nas-sync

**English** | [中文](README.md)

> Plug in your DJI Osmo Pocket 4 → auto-backup to NAS → automatically convert "Live Photos" (3-second clips) into motion photos your phone gallery understands.

---

## What is this

A set of self-hosted scripts that solve three very concrete problems:

1. **Manual copying after every shoot** — plug in the camera, auto-backup to NAS, auto-eject safely when done
2. **Duplicates get re-copied** — manifest-based deduplication; plug in 100 times, no duplicate copies
3. **DJI's "Live Photos" show up as videos in your NAS gallery** — auto-convert them into single-file Motion Photos that phone galleries render as photos

Built with plain `bash` + `ffmpeg` + `exiftool` + `udev` + `systemd`. **No server-side service, no app required.**

**Tested with**: Ubuntu 24.04 host + **UGREEN DH4300 Plus** (UGOS Pro) + Osmo Pocket 4.
Live-photo rendering depends on your NAS gallery — see [Viewing live photos in your NAS gallery](#viewing-live-photos-in-your-nas-gallery).

---

## Features

| Feature | Description |
|---|---|
| 🔌 **Backup on plug-in** | udev detects USB insertion, systemd runs the backup |
| 🔁 **Manifest dedup** | Every file recorded; re-plugging never re-copies |
| 📅 **Date-foldered** | Parses `DJI_YYYYMMDD...` into `YYYY-MM-DD/` |
| 💿 **Safe eject** | Unmounts automatically to avoid corruption |
| 📸 **Live photo conversion** | 3-second clips → single-file Motion Photo (lossless) |
| 🗂️ **Originals archived** | Originals moved to `pocket4_raw`; easy rollback/extract |
| ⏱️ **Periodic sweep** | Scans every 90 minutes as a safety net |
| 🔊 **Optional TTS** | Announce progress via Home Assistant (Xiaomi speakers) |
| 🧪 **Idempotent + safe** | Triple verification before moving originals; failures leave originals untouched |

---

## How it works

```
┌──────────────┐
│  Osmo Pocket │  USB-C plug-in
└──────┬───────┘
       ▼
┌─────────────────────────────────────────────┐
│  udev: ACTION=="add", idVendor=="2ca3"      │
└──────┬──────────────────────────────────────┘
       ▼
┌─────────────────────────────────────────────┐
│  dji-import.sh (systemd oneshot)            │
│  ① Wait for camera mount (≤90s)             │
│  ② Ensure NAS mounted (auto-mount)          │
│  ③ Manifest dedup → copy to /mnt/pocket4/   │
│  ④ Verify file sizes                        │
│  ⑤ Announce result (optional)               │
│  ⑥ Wait → safe unmount                      │
│  ⑦ Launch live-photo conversion in bg       │
└──────┬──────────────────────────────────────┘
       ▼
┌─────────────────────────────────────────────┐
│  dji-livephoto-convert.sh (silent, bg)      │
│  ① Criterion: 2.5-4.0s AND no lens tag      │
│  ② Extract keyframe → JPEG (4K q=1)         │
│  ③ Cover + original MP4 byte-for-byte       │
│  ④ Write XMP (MicroVideo/Offset/Version)    │
│  ⑤ Triple verification incl. MD5 compare    │
│  ⑥ Place .JPG in pocket4                    │
│  ⑦ Move MP4 + LRF to pocket4_raw            │
└─────────────────────────────────────────────┘
```

### Directory layout

```
Before (on camera):
  DCIM/DJI_001/
    ├─ DJI_20261107111324_0032_D.MP4   ← 3-second clip (live photo material)
    ├─ DJI_20261107111324_0032_D.LRF   ← editing proxy
    └─ DJI_20261107111931_0038_D.MP4   ← 22-second regular video

After backup + conversion:
  /mnt/pocket4/2026-11-07/            ← output area (results only)
    ├─ DJI_20261107111324_0032_D.JPG   ← motion photo (lossless, embeds video)
    └─ DJI_20261107111931_0038_D.MP4   ← regular video untouched

  /mnt/pocket4_raw/2026-11-07/        ← archive area
    ├─ DJI_20261107111324_0032_D.MP4   ← original after conversion
    └─ DJI_20261107111324_0032_D.LRF
```

---

## Requirements

- **Linux** (tested on Ubuntu 24.04 / Linux Mint 22)
- Camera: **DJI Osmo Pocket 4** (`idVendor=2ca3`; other DJI cameras likely work)
- NAS: anything supporting **SMB/CIFS**
  - **This implementation was built and tested on a UGREEN DH4300 Plus (UGOS Pro)**
  - Synology / QNAP / others should work for the backup, but live-photo rendering depends on each NAS's gallery — see "NAS gallery compatibility"
- Deps: `ffmpeg`, `ffprobe`, `exiftool`, `curl`, `cifs-utils`

```bash
sudo apt update
sudo apt install -y ffmpeg libimage-exiftool-perl curl cifs-utils
```

---

## Installation

```bash
git clone https://github.com/hagen666/osmo-pocket-nas-sync.git
cd osmo-pocket-nas-sync
sudo ./install.sh
```

The installer will:
1. Check dependencies
2. Install 6 scripts to `/usr/local/bin/`
3. Create `/etc/dji-import/config`
4. Install systemd units + timer + udev rule
5. Run a self-check

---

## Configuration

### 1. NAS mount (one-time manual step)

```bash
sudo mkdir -p /mnt/pocket4 /mnt/pocket4_raw

sudo tee /etc/cifs-pocket4.cred > /dev/null <<'EOF'
username=your_nas_user
password=your_nas_password
EOF
sudo chmod 600 /etc/cifs-pocket4.cred

sudo tee -a /etc/fstab > /dev/null <<'EOF'
//192.168.1.100/pocket4     /mnt/pocket4     cifs credentials=/etc/cifs-pocket4.cred,vers=3.0,uid=1000,gid=1000,file_mode=0775,dir_mode=0775,iocharset=utf8,nounix,nofail,_netdev 0 0
//192.168.1.100/pocket4_raw /mnt/pocket4_raw cifs credentials=/etc/cifs-pocket4.cred,vers=3.0,uid=1000,gid=1000,file_mode=0775,dir_mode=0775,iocharset=utf8,nounix,nofail,_netdev 0 0
EOF

sudo systemctl daemon-reload
sudo mount -a
```

> ⚠️ **`pocket4_raw` must be a separate mount point.** The converter refuses to run otherwise — this guards against silently writing originals to the local disk instead of the NAS.

### 2. Edit settings

```bash
sudo nano /etc/dji-import/config
```

| Key | Default | Meaning |
|---|---|---|
| `LIVEPHOTO_MIN_DUR` | `2.5` | Min duration for live photo (s) |
| `LIVEPHOTO_MAX_DUR` | `4.0` | Max duration for live photo (s) |
| `LIVEPHOTO_REQUIRE_NO_LENSTAG` | `1` | Require absence of lens tag |
| `AUTO_EJECT` | `1` | Auto-unmount after backup |
| `AUTO_CONVERT` | `1` | Auto-convert live photos |
| `HA_URL` | empty | Home Assistant URL (empty = no TTS) |
| `NOTIFY_ENTITY` | empty | TTS target entity (empty = no TTS) |

### 3. Verify

```bash
sudo dji-check
```

---

## Viewing live photos in your NAS gallery

### ⚠️ This matters: whether you can play them depends heavily on the NAS brand

The output is a **single-file Motion Photo**. Whether your NAS gallery renders it as a
live photo (long-press to play) depends entirely on **whether its gallery supports this format**.

| NAS / OS | Live photo support | Notes |
|---|---|---|
| **UGREEN UGOS Pro** | ✅ **Yes** | Our test environment (DH4300 Plus); vendor documents "Android live photo" support |
| Synology DSM | ⚠️ Verify | Synology handles iPhone JPG+MOV pairs; single-file Motion Photo untested |
| QNAP QTS | ⚠️ Verify | Untested |

> 💡 Recommendation: **test with a single converted file first** before batch-converting your library.

### UGREEN NAS steps

Converted files land in `/mnt/pocket4/` (the `pocket4` share on the NAS).
But **the gallery does not scan shared folders by default** — you must add it:

```
1. Open UGREEN NAS app → Photos
2. Go to Photos settings → Shared folders (or "Add folder to library")
3. Check the `pocket4` shared folder
4. Wait for the gallery to finish scanning/indexing
5. Back in the timeline → 3-second clips appear as live photos
   (long-press to play the motion)
```

**Result**:
- ✅ Live photos appear in the photo timeline by capture time
- ✅ Long-press plays the motion
- ✅ Behave like normal photos (view, share, upload)

> After this step, those 3-second clips show up as *photos*, not videos.

### If your NAS gallery doesn't support it

The single-file Motion Photo is also recognized by **Android** phone galleries.
If your NAS gallery can't render it, you can sync the files to an Android phone instead.

**Note**: this format is **not recognized by iOS Photos** (iOS uses a JPG+MOV pair).

---

## How live photos are detected

DJI's "Live Photo" is essentially a **~3-second 4K video**. NAS galleries classify by extension, so it shows up as a video.

**Dual-condition criterion:**

```
① duration between 2.5 and 4.0 seconds
② AND no DjiCameraLensType tag
→ both must hold
```

Measured across 73 MP4 files:

| Category | Count | Has `DjiCameraLensType` |
|---|---|---|
| Clips 2.5–4.0s | **63** | **0** |
| Very short <2.5s | 3 | **3** |
| Regular videos >4.0s | **7** | **7** |

**63 vs 10, zero misclassification.**

Control experiment (same day contains both types → tag correlates with content type, not firmware/date):

| Date | Live | Non-live |
|---|---|---|
| 2026-11-01 | 3 | 1 |
| 2026-11-04 | 2 | 2 |
| 2026-11-06 | 8 | 2 |
| 2026-11-07 | 50 | 3 |

Likely reason: the quick-capture pipeline used for live photos doesn't write full lens metadata.

### Why the conversion is lossless

```
┌─────────────────────────┬──────────────────────────┐
│  Cover JPEG (~0.5 MB)   │  Original MP4 (verbatim)  │
└─────────────────────────┴──────────────────────────┘
                          ↑
              XMP MicroVideoOffset points here
```

The video bytes are appended **verbatim, no transcoding**. Extracting them back yields a byte-identical file (verified by MD5).

Only the cover frame is re-encoded (unavoidable — you're converting a video frame to JPEG), at 4K q=1.

---

## Command reference

| Command | Purpose |
|---|---|
| `sudo dji-check` | Self-check |
| `sudo tail -f /var/log/dji-import.log` | Backup log |
| `sudo tail -f /var/log/dji-livephoto.log` | Conversion log |
| `sudo dji-import.sh` | Run backup manually |
| `sudo dji-livephoto-convert.sh --dry-run` | Dry run |
| `sudo dji-livephoto-convert.sh --all` | Convert everything |
| `sudo dji-livephoto-convert.sh --one <file>` | Convert one file |
| `sudo dji-restore --list` | List converted files |
| `sudo dji-restore <pattern>` | Roll back one |
| `sudo dji-restore --all` | Roll back all |
| `sudo dji-extract-video <JPG>` | Extract original video (lossless) |
| `sudo dji-extract-video --verify <JPG>` | Verify integrity (MD5) |

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing happens on plug-in | `sudo journalctl -u dji-import.service -n 50`; `lsusb \| grep 2ca3` |
| Backup works but no conversion | `sudo tail -50 /var/log/dji-livephoto.log` |
| Conversion refused | `mountpoint /mnt/pocket4_raw` must succeed |
| No TTS | check `HA_URL` / `NOTIFY_ENTITY` / `/etc/dji-import/ha_token` |
| Re-copying originals | manifest must be v2 (4 columns) |

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Known limitations

1. **Only tested with Osmo Pocket 4** — other DJI cameras likely work (`idVendor=2ca3`) but the live-photo heuristic may need tuning
2. **Output is single-file Motion Photo** — Android / UGREEN UGOS Pro galleries recognize it; **iOS Photos does not** (iOS uses a JPG+MOV pair)
   - Support on other NAS brands is unverified — see "NAS gallery compatibility"
3. **Requires SMB** — NFS untested
4. **Cover frame is lossy** — video is lossless; the cover is one JPEG encode at q=1

---

## License

[MIT](LICENSE)
