# osmo-pocket-nas-sync

[English](README.en.md) | **中文**

> 把大疆 Osmo Pocket 4 插上电脑就自动备份到 NAS，并把「实况照片」（3 秒片段）自动转成手机相册能识别的实况图。

---

## 这是什么

这是我在自己家里用的一套自动化脚本，解决三个很具体的问题：

1. **每次拍完要手动拷素材** —— 插上相机，自动备份到 NAS，备份完自动安全卸载
2. **重复素材会反复拷贝** —— 用清单去重，插多少次都不会重复
3. **大疆的「实况照片」在 NAS 相册里显示成视频** —— 自动转成单文件 Motion Photo，手机相册里就能当照片看

全部用 `bash` + `ffmpeg` + `exiftool` + `udev` + `systemd` 实现，**零依赖服务端**，不需要装任何 App。

---

## 功能特性

| 功能 | 说明 |
|---|---|
| 🔌 **插入即备份** | udev 检测 USB 插入，systemd 自动执行 |
| 🔁 **清单去重** | 清单记录每个文件，重复插入不会重复拷贝 |
| 📅 **按日期分目录** | 自动解析 `DJI_YYYYMMDD...` 放进 `YYYY-MM-DD/` |
| 💿 **安全卸载** | 备份完自动卸载，避免拔线损坏文件 |
| 📸 **实况照片转换** | 3 秒片段 → 单文件 Motion Photo（无损） |
| 🗂️ **原片归档** | 转换后原片移入 `pocket4_raw`，随时可回滚/提取 |
| ⏱️ **定时兜底** | 每 90 分钟扫一遍，防止漏转 |
| 🔊 **可选语音播报** | 接入 Home Assistant 后可在小爱音箱播报进度 |
| 🧪 **幂等 + 安全** | 三重校验通过才移动原片，失败原片不动 |

---

## 工作原理

```
┌──────────────┐
│  Osmo Pocket │  USB-C 插入
└──────┬───────┘
       │
       ▼
┌─────────────────────────────────────────────┐
│  udev: ACTION=="add", idVendor=="2ca3"      │
└──────┬──────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────┐
│  dji-import.sh（systemd oneshot）            │
│  ① 等相机挂载（≤90s，失败则手动 mount）       │
│  ② 检查 NAS 挂载（未挂载则自动 mount）        │
│  ③ 清单去重 → 复制到 /mnt/pocket4/日期/       │
│  ④ 逐文件校验大小                             │
│  ⑤ 播报结果（可选）                           │
│  ⑥ 等待 → 安全卸载                           │
│  ⑦ 后台启动实况照片转换                       │
└──────┬──────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────┐
│  dji-livephoto-convert.sh（后台静默）        │
│  ① 判据: 时长 2.5-4.0s + 无镜头标记           │
│  ② 提取关键帧 → JPEG（4K q=1）                │
│  ③ 封面 + 原 MP4 原样拼接（视频零改动）       │
│  ④ 写 XMP（MicroVideo / Offset / Version）    │
│  ⑤ 三重校验：大小 / 偏移 / 提取比对 MD5       │
│  ⑥ 通过 → 落位 .JPG                           │
│  ⑦ 原片 MP4 + LRF 移入 /mnt/pocket4_raw/     │
└─────────────────────────────────────────────┘
```

### 目录变化

```
备份前（相机里）:
  DCIM/DJI_001/
    ├─ DJI_20261107111324_0032_D.MP4   ← 3秒片段（实况素材）
    ├─ DJI_20261107111324_0032_D.LRF   ← 剪辑代理
    └─ DJI_20261107111931_0038_D.MP4   ← 22秒长视频

备份 + 转换后:
  /mnt/pocket4/2026-11-07/            ← 成品区（只放结果）
    ├─ DJI_20261107111324_0032_D.JPG   ← 实况照片（无损，内含原视频）
    └─ DJI_20261107111931_0038_D.MP4   ← 长视频原样保留

  /mnt/pocket4_raw/2026-11-07/        ← 归档区
    ├─ DJI_20261107111324_0032_D.MP4   ← 已转换的原片
    └─ DJI_20261107111324_0032_D.LRF
```

---

## 环境要求

- **Linux**（已在 Ubuntu 24.04 / Linux Mint 22 测试）
- 相机：**DJI Osmo Pocket 4**（`idVendor=2ca3`，其他大疆机型理论上通用）
- NAS：支持 **SMB/CIFS** 即可（群晖、绿联、威联通均可）
- 依赖：`ffmpeg`、`ffprobe`、`exiftool`、`curl`、`cifs-utils`

```bash
# Ubuntu / Debian
sudo apt update
sudo apt install -y ffmpeg libimage-exiftool-perl curl cifs-utils
```

---

## 安装

```bash
git clone https://github.com/hagen666/osmo-pocket-nas-sync.git
cd osmo-pocket-nas-sync
sudo ./install.sh
```

安装脚本会：
1. 检查依赖（缺什么会提示安装命令）
2. 装 6 个脚本到 `/usr/local/bin/`
3. 创建 `/etc/dji-import/config`（含默认值）
4. 装 systemd 服务 + 定时器
5. 装 udev 规则
6. 跑一次自检

---

## 配置

### 1. NAS 挂载（必须手动做一次）

先确认 NAS 上的共享目录已创建，然后写进 `/etc/fstab`：

```bash
# 创建挂载点和凭据文件
sudo mkdir -p /mnt/pocket4 /mnt/pocket4_raw

# 凭据文件（600 权限）
sudo tee /etc/cifs-pocket4.cred > /dev/null <<'EOF'
username=your_nas_user
password=your_nas_password
EOF
sudo chmod 600 /etc/cifs-pocket4.cred

# fstab 追加两行（注意改成你的 NAS 地址和共享名）
sudo tee -a /etc/fstab > /dev/null <<'EOF'
//192.168.1.100/pocket4     /mnt/pocket4     cifs credentials=/etc/cifs-pocket4.cred,vers=3.0,uid=1000,gid=1000,file_mode=0775,dir_mode=0775,iocharset=utf8,nounix,nofail,_netdev 0 0
//192.168.1.100/pocket4_raw /mnt/pocket4_raw cifs credentials=/etc/cifs-pocket4.cred,vers=3.0,uid=1000,gid=1000,file_mode=0775,dir_mode=0775,iocharset=utf8,nounix,nofail,_netdev 0 0
EOF

sudo systemctl daemon-reload
sudo mount -a
```

> ⚠️ **`pocket4_raw` 必须是独立的挂载点**。转换脚本会检查这一点，如果不是挂载点会拒绝执行 —— 这是为了防止原片被写到本机磁盘而不是 NAS。

### 2. 编辑参数

```bash
sudo nano /etc/dji-import/config
```

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `LIVEPHOTO_MIN_DUR` | `2.5` | 判定实况的最短时长（秒）|
| `LIVEPHOTO_MAX_DUR` | `4.0` | 判定实况的最长时长（秒）|
| `LIVEPHOTO_REQUIRE_NO_LENSTAG` | `1` | 是否要求「无镜头标记」|
| `AUTO_EJECT` | `1` | 备份后是否自动卸载 |
| `AUTO_CONVERT` | `1` | 是否自动转换实况照片 |
| `HA_URL` | 空 | Home Assistant 地址（留空=不播报）|
| `NOTIFY_ENTITY` | 空 | 播报目标实体（留空=不播报）|

### 3. 验证

```bash
sudo dji-check
```

期望输出：

```
======== 大疆备份 + 实况转换 自检 ========
   ✅ udev 规则
   ✅ 备份服务
   ✅ 备份脚本
   ✅ 转换脚本
   ✅ 定时转换器（90分钟）
   ✅ 成品区已挂载 (/mnt/pocket4)
   ✅ 归档区已挂载 (/mnt/pocket4_raw)
   ✅ 清单 v2（155 条）
   ℹ️  imported=29  converted=126
   ✅ 成品区 JPG=72 ≥ 归档 MP4=63
==========================================
```

---

## 实况照片是怎么识别的

这是整个项目里最有意思的部分。

### 问题

大疆的「实况照片」本质是 **约 3 秒的 4K 视频**。NAS 相册只按扩展名判断，所以它显示成"视频"。

### 怎么认出哪些 3 秒视频是实况

**双条件判据**：

```
① 时长在 2.5 – 4.0 秒
② 且没有 DjiCameraLensType 标记
→ 两条都满足才算实况素材
```

### 为什么是这个判据

实际测了 73 个 MP4：

| 类别 | 数量 | 有 `DjiCameraLensType` |
|---|---|---|
| 短片段 2.5–4.0s | **63** | **0 个** |
| 超短 <2.5s（0.30 / 0.88 / 1.58s）| 3 | **3 个** |
| 长视频 >4.0s（11–137s）| **7** | **7 个** |

**63 vs 10，零误判。**

关键控制实验 —— 确认不是"按日期/固件"区分：

| 日期 | 实况 | 非实况 |
|---|---|---|
| 2026-11-01 | 3 | 1 ← 混合 |
| 2026-11-04 | 2 | 2 ← 混合 |
| 2026-11-06 | 8 | 2 ← 混合 |
| 2026-11-07 | 50 | 3 ← 混合 |

5 天里 4 天同一天既有实况又有非实况 → 标记跟的是**内容类型**，不是固件版本或拍摄日期。

**推测原因**：实况照片走的是「快速抓拍」管线，不写完整镜头元数据。

### 为什么双条件比纯时长安全

| 情况 | 纯时长判据 | 双条件 |
|---|---|---|
| 0.3 秒误抓片段 | ⚠️ 靠边界挡 | ✅ 有标记，排除 |
| 将来出现 3 秒真视频 | ⚠️ **会误转** | ✅ 有标记，排除 |
| 实况照片 | ✅ | ✅ |

**失败方向是安全的**：万一真实况带了标记 → 漏转（可用 force 清单补救），
而不是把真视频误转成图片。

### 转换为什么是无损的

实况照片（单文件 Motion Photo）的结构是：

```
┌─────────────────────────┬──────────────────────────┐
│  封面 JPEG（约 0.5MB）   │  原始 MP4（原样拼接）      │
└─────────────────────────┴──────────────────────────┘
                          ↑
              XMP MicroVideoOffset 指向这里
```

**视频部分是逐字节原样拼接的，零转码**。已验证提取出来的 MP4 与原片 MD5 完全一致。

唯一的"有损"是封面那一帧 —— 因为要从视频里抽一帧变成 JPEG，格式必然变（原理决定的）。但用了 **4K q=1 最高质量**，肉眼看不出差别。

---

## 命令速查

| 命令 | 作用 |
|---|---|
| `sudo dji-check` | 一键自检 |
| `sudo tail -f /var/log/dji-import.log` | 备份日志 |
| `sudo tail -f /var/log/dji-livephoto.log` | 转换日志 |
| `sudo dji-import.sh` | 手动跑一次备份 |
| `sudo dji-livephoto-convert.sh --dry-run` | 演练转换（只报告）|
| `sudo dji-livephoto-convert.sh --all` | 全量转换 |
| `sudo dji-livephoto-convert.sh --one <文件名>` | 只转一个 |
| `sudo dji-restore --list` | 列出已转换的 |
| `sudo dji-restore <文件名片段>` | 回滚（原片移回成品区）|
| `sudo dji-restore --all` | 全部回滚 |
| `sudo dji-extract-video <JPG>` | 从实况照片提取原片视频（无损）|
| `sudo dji-extract-video --verify <JPG>` | 校验完整性（含 MD5 比对）|

### 常见操作

**想剪辑某个实况照片的视频**：
```bash
sudo dji-extract-video /mnt/pocket4/2026-11-07/DJI_xxx.JPG ~/Videos/
# → ~/Videos/DJI_xxx.MP4（逐字节无损）
```

**转换错了想还原**：
```bash
sudo dji-restore DJI_20261107111324
```

**某个 3 秒片段想当视频留着**：
```bash
echo "DJI_20261107121149_0070_D.MP4" | sudo tee -a /mnt/pocket4/.livephoto-skip.txt
```

**某个超阈值片段想强制转**：
```bash
echo "DJI_20261201093000_0123_D.MP4" | sudo tee -a /mnt/pocket4/.livephoto-force.txt
```

---

## 故障排查

| 现象 | 排查 |
|---|---|
| 插入相机没反应 | `sudo journalctl -u dji-import.service -n 50`；`lsusb \| grep 2ca3` |
| 备份了但转换没跑 | `sudo tail -50 /var/log/dji-livephoto.log`；`systemctl status dji-livephoto-scan.timer` |
| 转换被拒绝 | 检查 `/mnt/pocket4_raw` 是否是挂载点：`mountpoint /mnt/pocket4_raw` |
| 播报没声音 | 检查 `HA_URL` / `NOTIFY_ENTITY` / `/etc/dji-import/ha_token` |
| 原文被重拷 | 检查清单格式是否为 v2：`head -1 /mnt/pocket4/.dji-manifest.tsv \| awk -F'\t' '{print NF}'`（应为 4）|

更多见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

---

## 已知限制

1. **只测了 Osmo Pocket 4** —— 其他大疆机型理论通用（都是 `idVendor=2ca3`），但实况判据可能需要调整
2. **实况照片是单文件 Motion Photo 格式** —— 安卓/绿联相册能识别，**iOS 相册不识别**（iOS 用的是 JPG+MOV 双文件格式）
3. **需要 NAS 支持 SMB** —— NFS 没测过
4. **转换后的封面帧有损** —— 视频部分无损，封面是一次 JPEG 编码（q=1，视觉无损）

---

## 为什么不用现成方案

| 方案 | 为什么没用 |
|---|---|
| 大疆官方 App | 只能传手机，不能直接进 NAS |
| NAS 自带手机备份 | 只能备份手机，相机素材要先导入手机 |
| Syncthing / rclone | 能做到同步，但不处理"插入即触发"和实况转换 |
| 手动脚本 | 就是我原来干的事，每次都要记命令 |

---

## License

[MIT](LICENSE)

---

## 相关文档

- [实况照片转换原理](docs/实况照片转换原理.md) —— 更详细的技术细节
- [故障排查](docs/TROUBLESHOOTING.md)
