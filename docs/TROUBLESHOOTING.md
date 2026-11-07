# 故障排查

按「现象 → 排查 → 修复」组织。

---

## 一、插入相机没反应

### 排查

```bash
# 1. 相机被识别了吗
lsusb | grep 2ca3
# 期望: Bus 001 Device 005: ID 2ca3:xxxx DJI ...

# 2. udev 规则装了吗
ls -l /etc/udev/rules.d/99-dji-import.rules

# 3. 服务跑过吗
systemctl status dji-import.service
sudo journalctl -u dji-import.service -n 50 --no-pager

# 4. 实时看 udev 事件
sudo udevadm monitor --udev --subsystem-match=usb
# 然后拔插相机，看有没有 add 事件
```

### 常见原因

| 原因 | 修复 |
|---|---|
| udev 规则没装 | `sudo ./install.sh` 重装 |
| 规则装了但没 reload | `sudo udevadm control --reload-rules` |
| 相机已经处于触发前的连接状态 | 拔掉重插（udev 只响应 add 事件）|
| `idVendor` 不是 2ca3 | `lsusb` 确认后改规则里的 vendor ID |

> ⚠️ `udevadm trigger` **不能**模拟真实插入 —— 它不会启动 `SYSTEMD_WANTS` 指定的服务。
> 必须真的拔插一次。

---

## 二、备份了但没转换

### 排查

```bash
# 1. 转换脚本存在且可执行吗
ls -l /usr/local/bin/dji-livephoto-convert.sh

# 2. 看转换日志
sudo tail -100 /var/log/dji-livephoto.log

# 3. 手动跑一次（先演练）
sudo dji-livephoto-convert.sh --dry-run

# 4. 定时器状态
systemctl status dji-livephoto-scan.timer
systemctl list-timers dji-livephoto-scan.timer
```

### 常见原因

| 日志关键字 | 原因 | 修复 |
|---|---|---|
| `未配置... 跳过` | 配置里 `AUTO_CONVERT=0` | 改为 1 |
| `归档区不是挂载点` | `/mnt/pocket4_raw` 没挂载 | `sudo mount /mnt/pocket4_raw` |
| `跳过(非实况)` | 判据不匹配 | 见下方「判据调优」|
| `已有转换任务在运行` | 上一个任务还没结束 | 等它结束，或 `pkill -f dji-livephoto-convert` |
| `缺少 ffmpeg` | 依赖没装 | `sudo apt install ffmpeg` |

---

## 三、判据不对（该转的没转 / 不该转的转了）

### 先看它怎么判断的

```bash
# 演练模式会打印每个文件的时长和镜头标记
sudo dji-livephoto-convert.sh --dry-run
sudo grep -E '跳过\(非实况\)|会转换' /var/log/dji-livephoto.log | tail -20
```

日志里会显示：

```
跳过(非实况): DJI_xxx.MP4  dur=36.760000  lens=有
[dry-run] 会转换: DJI_yyy.MP4  (3.036367s, 15989566 字节)
```

### 手动查单个文件

```bash
# 时长
ffprobe -v error -show_entries format=duration -of csv=p=0 文件.MP4

# 有没有镜头标记
exiftool -s3 -DjiCameraLensType 文件.MP4
# 有输出（如 "20mm F2"）= 普通视频
# 无输出 = 可能是实况
```

### 判据调优

编辑 `/etc/dji-import/config`：

```bash
# 放宽时长范围
LIVEPHOTO_MIN_DUR=2.0
LIVEPHOTO_MAX_DUR=6.0

# 关掉镜头标记检查（不推荐，可能误转真视频）
LIVEPHOTO_REQUIRE_NO_LENSTAG=0
```

### 手动强制/排除

```bash
# 某个文件强制转换（忽略判据）
echo "DJI_xxx.MP4" | sudo tee -a /mnt/pocket4/.livephoto-force.txt

# 某个文件永远不转
echo "DJI_yyy.MP4" | sudo tee -a /mnt/pocket4/.livephoto-skip.txt
```

---

## 四、原片被重新拷贝

**症状**：每次插相机都重新拷一遍已经备份过的文件。

### 排查

```bash
# 1. 清单格式是 v2 吗（应该是 4 列）
head -1 /mnt/pocket4/.dji-manifest.tsv | awk -F'\t' '{print "列数: " NF}'

# 2. 文件在清单里吗
grep "DJI_xxx.MP4" /mnt/pocket4/.dji-manifest.tsv

# 3. 状态是什么
awk -F'\t' '$1=="DJI_xxx.MP4"{print $4}' /mnt/pocket4/.dji-manifest.tsv
```

### 修复

```bash
# 如果还是 v1（3 列）→ 迁移
sudo dji-manifest-migrate

# 如果清单里没有该文件 → 手动补一条
printf '%s\t%s\t%s\t%s\n' "DJI_xxx.MP4" "文件字节数" "$(date '+%F %T')" "imported" \
  | sudo tee -a /mnt/pocket4/.dji-manifest.tsv
```

### 原理

v2 清单按状态决定去哪找文件：

```
状态 = imported  → 去 /mnt/pocket4/日期/ 找
状态 = converted → 去 /mnt/pocket4_raw/日期/ 找
```

所以原片移到归档区后仍然能被正确识别为"已备份"。

---

## 五、播报没声音

### 排查

```bash
# 1. 配置齐了吗
sudo grep -E 'HA_URL|NOTIFY_ENTITY' /etc/dji-import/config

# 2. 令牌有吗
sudo wc -c /etc/dji-import/ha_token

# 3. 令牌有效吗
TOKEN=$(sudo cat /etc/dji-import/ha_token)
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" \
  "$(sudo grep '^HA_URL' /etc/dji-import/config | cut -d'"' -f2)/api/"
# 期望 200
```

### 修复

| 问题 | 修复 |
|---|---|
| `HA_URL` 为空 | 填上 `http://你的HA地址:8123` |
| `NOTIFY_ENTITY` 为空 | 填上播报实体，如 `notify.xiaomi_cn_XXX_x8f_play_text_a_7_3` |
| 令牌为空 | 在 HA 里创建长期访问令牌，写入 `/etc/dji-import/ha_token` |

> 播报是完全可选的。不配置也能正常备份和转换，只是没有语音提示。

---

## 六、转换脚本拒绝执行

**症状**：

```
❌ 归档区不是挂载点，拒绝执行: /mnt/pocket4_raw
```

### 原因

这是**保护机制**。如果 `/mnt/pocket4_raw` 不是挂载点，脚本会把原片写到本机磁盘，
而不是 NAS —— 这样你在 NAS 上就看不到文件了。

### 排查

```bash
mountpoint /mnt/pocket4_raw
df -h /mnt/pocket4_raw
```

### 修复

```bash
# 写入 fstab 并挂载
sudo grep pocket4_raw /etc/fstab
sudo mount /mnt/pocket4_raw
```

确认 `df -h` 显示的是 NAS（如 `//192.168.1.100/pocket4_raw`），而不是本机磁盘。

---

## 七、转换后视频打不开 / 不是无损

### 校验方法

```bash
sudo dji-extract-video --verify /mnt/pocket4/2026-11-07/DJI_xxx.JPG
```

正常输出会包含：

```
--- 与原片比对 ---
   原片 MD5: a0cda2dacccb89128d35351d1d283422
   提取 MD5: a0cda2dacccb89128d35351d1d283422
   🎉 完全无损
```

### 如果不一致

| 可能原因 | 说明 |
|---|---|
| 对比的是不同文件 | 检查路径 |
| 转换时原片已被修改 | 不太可能，转换是只读的 |
| 存储损坏 | `md5sum` 重算几次，看是否稳定 |

---

## 八、磁盘/NAS 空间不足

```bash
df -h /mnt/pocket4 /mnt/pocket4_raw
du -sh /mnt/pocket4/* | sort -h | tail
```

转换本身**不会显著增加空间**（省掉 LRF，多出封面，基本持平）。
如果空间紧张，可以：

```bash
# 查看回收站（回滚时产生的）
du -sh /mnt/pocket4_raw/.trash

# 清理回收站（确认不需要后）
sudo rm -rf /mnt/pocket4_raw/.trash
```

---

## 九、重置（从头再来）

```bash
# 1. 停服务
sudo systemctl disable --now dji-livephoto-scan.timer
sudo systemctl stop dji-import.service

# 2. 备份清单
sudo cp /mnt/pocket4/.dji-manifest.tsv /tmp/manifest.bak

# 3. 全部回滚（可选，把实况照片还原成原片）
sudo dji-restore --all

# 4. 删除清单
sudo rm /mnt/pocket4/.dji-manifest.tsv

# 5. 重新安装
sudo ./install.sh
```

---

## 十、收集诊断信息

出问题时跑这个，把结果贴到 issue：

```bash
sudo dji-check
echo "---"
lsusb | grep -i dji
echo "---"
sudo tail -30 /var/log/dji-import.log
echo "---"
sudo tail -30 /var/log/dji-livephoto.log
echo "---"
systemctl status dji-import.service --no-pager | head -10
systemctl status dji-livephoto-scan.timer --no-pager | head -10
echo "---"
df -h /mnt/pocket4 /mnt/pocket4_raw
echo "---"
ffmpeg -version | head -1
exiftool -ver
```
