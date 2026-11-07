#!/bin/bash
# ============================================================
# 大疆 Pocket 4 自动备份 + 安全卸载
# 位置: /usr/local/bin/dji-import.sh
# 触发: /etc/udev/rules.d/99-dji-import.rules → systemd
# 日志: /var/log/dji-import.log
# ============================================================
set -u

# ============ 默认配置（可被 /etc/dji-import/config 覆盖）============
CAM_MOUNT="${CAM_MOUNT:-/media/$USER/Pocket4}"   # udisks 自动挂载点（默认当前用户）
NAS_MOUNT="/mnt/pocket4"                     # 成品区（只放结果）
RAW_DIR="/mnt/pocket4_raw"                   # 原始归档区（转换后的原片）
MANIFEST="$NAS_MOUNT/.dji-manifest.tsv"      # 去重清单（v2: 4 列）
LOG="/var/log/dji-import.log"
HA_URL="${HA_URL:-}"                       # 例: http://192.168.1.100:8123（留空=不播报）
TOKEN_FILE="/etc/dji-import/ha_token"
NOTIFY_ENTITY="${NOTIFY_ENTITY:-}"         # 例: notify.xiaomi_cn_XXXX_x8f_play_text_a_7_3（留空=不播报）
LOCK="${DJI_IMPORT_LOCK:-/var/lock/dji-import.lock}"

WAIT_MOUNT_MAX=90        # 等相机挂载，最多多少秒
SLEEP_AFTER_BACKUP=10    # 备份播报完成后等多久，再播报"即将卸载"
SLEEP_BEFORE_UMOUNT=15   # 播报"即将卸载"后等多久再卸载
AUTO_EJECT=1             # 1=自动卸载  0=只备份不卸载
SKIP_MOUNT_CHECK=0       # 调试用：1=跳过 NAS 挂载检查（正常生产保持 0）

CONF="${DJI_IMPORT_CONF:-/etc/dji-import/config}"
[ -f "$CONF" ] && . "$CONF"

# 配置可能改了 NAS_MOUNT，依赖它的路径要重新算
MANIFEST="$NAS_MOUNT/.dji-manifest.tsv"

# ============ 工具函数 ============
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

say() {
  local msg="$1"
  # 未配置 HA 播报 → 静默跳过（开源版默认不播报）
  if [ -z "${HA_URL:-}" ] || [ -z "${NOTIFY_ENTITY:-}" ]; then
    log "未配置播报(HA_URL/NOTIFY_ENTITY)，跳过: $msg"; return 0
  fi
  if [ ! -s "$TOKEN_FILE" ]; then log "无令牌，跳过播报: $msg"; return 0; fi
  local tk; tk=$(cat "$TOKEN_FILE")
  local body
  body=$(printf '{"entity_id":"%s","message":"%s"}' "$NOTIFY_ENTITY" "$msg")
  if curl -s -m 12 -X POST "$HA_URL/api/services/notify/send_message" \
        -H "Authorization: Bearer $tk" \
        -H "Content-Type: application/json" \
        --data-binary "$body" >/dev/null 2>&1; then
    log "播报: $msg"
  else
    log "播报失败: $msg"
  fi
}

# 清单写入（存在则更新，不存在则追加）—— 防止重复条目
manifest_upsert() {
  local n="$1" sz="$2" st="$3" tm
  tm=$(date '+%F %T')
  if awk -F'\t' -v n="$n" 'BEGIN{f=0} $1==n{f=1} END{exit !f}' "$MANIFEST" 2>/dev/null; then
    awk -F'\t' -v OFS='\t' -v n="$n" -v sz="$sz" -v st="$st" -v tm="$tm" \
      '{ if ($1==n) { $2=sz; $3=tm; $4=st } print }' "$MANIFEST" > "$MANIFEST.tmp" \
      && mv "$MANIFEST.tmp" "$MANIFEST"
  else
    printf '%s\t%s\t%s\t%s\n' "$n" "$sz" "$tm" "$st" >> "$MANIFEST"
  fi
}

# ============ 主流程 ============
main() {
  log "===== 任务开始 ====="

  # --- 1. 等相机挂载（udisks 未自动挂载时兜底手动挂）---
  local i=0
  while [ ! -d "$CAM_MOUNT/DCIM" ] && [ "$i" -lt $((WAIT_MOUNT_MAX / 2)) ]; do
    sleep 2; i=$((i + 1))
  done

  if [ ! -d "$CAM_MOUNT/DCIM" ]; then
    local dev
    dev=$(blkid -L Pocket4 2>/dev/null || readlink -f /dev/disk/by-label/Pocket4 2>/dev/null)
    if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
      log "udisks 未自动挂载，尝试手动挂载 $dev"
      mkdir -p /mnt/dji-cam
      umount /mnt/dji-cam 2>/dev/null
      if mount -o ro "$dev" /mnt/dji-cam 2>/dev/null; then
        CAM_MOUNT="/mnt/dji-cam"
        log "手动挂载成功: /mnt/dji-cam"
      fi
    fi
  fi

  if [ ! -d "$CAM_MOUNT/DCIM" ]; then
    log "超时：未检测到相机 DCIM"
    say "相机已连接，但读取失败，请检查"
    exit 1
  fi
  log "相机已挂载: $CAM_MOUNT"

  # --- 2. 检查 NAS（未挂载则尝试自动挂载）---
  if [ "$SKIP_MOUNT_CHECK" != "1" ] && ! mountpoint -q "$NAS_MOUNT"; then
    log "NAS 未挂载，尝试自动挂载"
    mkdir -p "$NAS_MOUNT"
    mount "$NAS_MOUNT" 2>/dev/null
    sleep 2
  fi
  if [ "$SKIP_MOUNT_CHECK" != "1" ] && ! mountpoint -q "$NAS_MOUNT" \
     || [ ! -w "$NAS_MOUNT" ]; then
    log "NAS 未挂载或不可写: $NAS_MOUNT"
    say "备份失败，网络存储不可用"
    exit 1
  fi

  say "相机已连接，开始备份"

  # --- 3. 增量备份（清单去重）---
  touch "$MANIFEST" 2>/dev/null || { log "清单不可写"; say "备份失败，无法写入清单"; exit 1; }

  # 读取清单（v2: 文件名 大小 时间 状态；兼容 v1 三列 → 视为 imported）
  local -A SEEN=() SEEN_STATUS=()
  local _n _s _t _st _key
  while IFS=$'\t' read -r _n _s _t _st; do
    [ -n "${_n:-}" ] || continue
    _key="$_n|$_s"
    SEEN["$_key"]=1
    SEEN_STATUS["$_key"]="${_st:-imported}"
  done < "$MANIFEST"

  local NEW=0 SKIP=0 FAIL=0 NEWBYTES=0
  local base size key d datef target

  while IFS= read -r f; do
    base=$(basename "$f")
    size=$(stat -c %s "$f" 2>/dev/null) || continue
    key="$base|$size"

    d=$(echo "$base" | grep -oP 'DJI_\K\d{8}' | head -1 || true)
    if [ -n "${d:-}" ]; then datef="${d:0:4}-${d:4:2}-${d:6:2}"; else datef="其他"; fi
    target="$NAS_MOUNT/$datef/$base"

    # ---- 命中清单 → 按状态校验（v2 核心逻辑）----
    if [ -n "${SEEN[$key]:-}" ]; then
      local st="${SEEN_STATUS[$key]:-imported}"
      local ok=0
      if [ "$st" = "converted" ]; then
        # 已转换：原片应躺在归档区
        if [ -f "$RAW_DIR/$datef/$base" ] \
           && [ "$(stat -c %s "$RAW_DIR/$datef/$base" 2>/dev/null)" = "$size" ]; then
          ok=1
        else
          # 原片丢了，但成品还在？→ 也算已备份
          local prod="$NAS_MOUNT/$datef/${base%.*}.JPG"
          if [ -f "$prod" ]; then
            ok=1
            log "警告: 原片缺失但成品存在，跳过: $base"
          else
            log "警告: 原片和成品都缺失，将重新备份: $base"
          fi
        fi
      else
        # imported：原片应在成品区
        if [ -f "$target" ] \
           && [ "$(stat -c %s "$target" 2>/dev/null)" = "$size" ]; then
          ok=1
        fi
      fi
      if [ "$ok" = "1" ]; then SKIP=$((SKIP + 1)); continue; fi
    fi

    mkdir -p "$NAS_MOUNT/$datef"
    if cp -p "$f" "$target" 2>/dev/null; then
      if [ "$(stat -c %s "$target" 2>/dev/null)" = "$size" ]; then
        manifest_upsert "$base" "$size" "imported"
        NEW=$((NEW + 1)); NEWBYTES=$((NEWBYTES + size))
      else
        log "校验失败: $base"
        rm -f "$target"
        FAIL=$((FAIL + 1))
      fi
    else
      log "复制失败: $base"
      FAIL=$((FAIL + 1))
    fi
  done < <(find "$CAM_MOUNT/DCIM" -type f \
             \( -iname '*.mp4' -o -iname '*.jpg' -o -iname '*.lrf' -o -iname '*.dng' \) 2>/dev/null)

  local MB=$((NEWBYTES / 1048576))
  log "备份结果: 新增=$NEW 跳过=$SKIP 失败=$FAIL 新增大小=${MB}MB"

  # --- 4. 播报备份结果 ---
  if [ "$FAIL" -gt 0 ]; then
    say "备份完成，新增${NEW}个文件，${FAIL}个失败"
  elif [ "$NEW" -gt 0 ]; then
    say "备份完成，新增${NEW}个文件，共${MB}兆"
  else
    say "备份完成，没有新文件"
  fi

  # --- 5. 是否自动卸载 ---
  if [ "$AUTO_EJECT" != "1" ]; then
    log "自动卸载已关闭，结束"
    exit 0
  fi
  if [ "$FAIL" -gt 0 ]; then
    log "有失败文件，为安全起见不卸载"
    exit 1
  fi

  sleep "$SLEEP_AFTER_BACKUP"
  say "备份完成，十五秒后卸载设备"
  sleep "$SLEEP_BEFORE_UMOUNT"

  # --- 6. 卸载 ---
  if command -v lsof >/dev/null 2>&1 && lsof +f -- "$CAM_MOUNT" >/dev/null 2>&1; then
    log "卸载失败: 有进程占用 $CAM_MOUNT"
    say "设备正在使用，无法卸载，请稍后手动拔出"
    exit 2
  fi

  sync
  if umount "$CAM_MOUNT" 2>/dev/null; then
    log "卸载成功: $CAM_MOUNT"
    say "相机已安全卸载，可以拔线了"

    # --- 7. 相机卸载后：后台静默转换实况照片（失败不播报）---
    if [ "${AUTO_CONVERT:-1}" = "1" ] && [ -x /usr/local/bin/dji-livephoto-convert.sh ]; then
      nohup /usr/local/bin/dji-livephoto-convert.sh --all >> /dev/null 2>&1 200>&- &
      log "已启动后台实况照片转换 (PID $!)"
    fi
  else
    log "卸载失败: $CAM_MOUNT"
    say "卸载失败，请手动安全弹出"
    exit 3
  fi

  log "===== 任务完成 ====="
}

# ============ 入口（加锁防重复触发）============
mkdir -p "$(dirname "$LOG")" "$(dirname "$TOKEN_FILE")"
exec 200>"$LOCK"
if ! flock -n 200; then
  log "已有任务在运行，本次跳过（防 udev 重复触发）"
  exit 0
fi
main
