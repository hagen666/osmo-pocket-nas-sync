#!/bin/bash
# ============================================================
# 大疆实况照片转换器
#   把 3 秒片段（无损）转成单文件 Motion Photo（安卓/绿联相册可识别）
#   成功后把原片移入 RAW_DIR 归档，只留成品
#
# 用法：
#   dji-livephoto-convert.sh                # 全量扫描（只处理 status=imported）
#   dji-livephoto-convert.sh --dry-run      # 只报告不执行
#   dji-livephoto-convert.sh --one <文件名>  # 只处理一个
#   dji-livephoto-convert.sh --all          # 同默认
#
# 日志：/var/log/dji-livephoto.log
# ============================================================
set -u

# ============ 默认配置（可被 /etc/dji-import/config 覆盖）============
NAS_MOUNT="/mnt/pocket4"
RAW_DIR="/mnt/pocket4_raw"
MANIFEST="$NAS_MOUNT/.dji-manifest.tsv"
LOG="${DJI_LIVEPHOTO_LOG:-/var/log/dji-livephoto.log}"
LOCK="${DJI_LIVEPHOTO_LOCK:-/var/lock/dji-livephoto.lock}"
CONF="${DJI_IMPORT_CONF:-/etc/dji-import/config}"

LIVEPHOTO_MIN_DUR=2.5
LIVEPHOTO_MAX_DUR=4.0
LIVEPHOTO_REQUIRE_NO_LENSTAG=1
LIVEPHOTO_COVER_W=3840
LIVEPHOTO_COVER_H=2160
LIVEPHOTO_JPEG_Q=1
LIVEPHOTO_KEYFRAME_TS=0.3
LIVEPHOTO_TS_US=300000
SKIP_LIST="$NAS_MOUNT/.livephoto-skip.txt"
FORCE_LIST="$NAS_MOUNT/.livephoto-force.txt"

[ -f "$CONF" ] && . "$CONF"

# 配置可能改了 NAS_MOUNT，依赖它的路径要重新算
MANIFEST="$NAS_MOUNT/.dji-manifest.tsv"
SKIP_LIST="$NAS_MOUNT/.livephoto-skip.txt"
FORCE_LIST="$NAS_MOUNT/.livephoto-force.txt"

# ============ 参数 ============
MODE="all"
DRY=0
ONE=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --all)     MODE="all" ;;
    --one)     MODE="one" ;;   # 后面跟文件名
    --one=*)   MODE="one"; ONE="${a#--one=}" ;;
    *)         [ "$MODE" = "one" ] && ONE="$a" ;;
  esac
done

# ============ 工具函数 ============
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

datef_of() {
  local d
  d=$(echo "$1" | grep -oP 'DJI_\K\d{8}' | head -1 || true)
  if [ -n "${d:-}" ]; then echo "${d:0:4}-${d:4:2}-${d:6:2}"; else echo "其他"; fi
}

# 清单：查询状态（找不到输出空）
manifest_status() {
  awk -F'\t' -v n="$1" '$1==n{print $4; exit}' "$MANIFEST" 2>/dev/null
}

# 清单：更新状态（不存在则追加）
manifest_set_status() {
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

list_contains() {   # list_contains <文件> <名字>
  [ -f "$1" ] && grep -qxF "$2" "$1" 2>/dev/null
}

get_dur() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | head -1
}

has_lens_tag() {
  local v
  v=$(exiftool -s3 -DjiCameraLensType "$1" 2>/dev/null | head -1 | tr -d ' \r')
  [ -n "$v" ] && [ "$v" != "-" ]
}

# 判断是否实况素材（双条件）
is_livephoto() {
  local f="$1" dur
  dur=$(get_dur "$f")
  [ -n "${dur:-}" ] || return 1
  # 条件① 时长
  if ! awk -v d="$dur" -v lo="$LIVEPHOTO_MIN_DUR" -v hi="$LIVEPHOTO_MAX_DUR" \
        'BEGIN{exit !(d>=lo && d<=hi)}'; then
    return 1
  fi
  # 条件② 无 LensType 标记
  if [ "$LIVEPHOTO_REQUIRE_NO_LENSTAG" = "1" ]; then
    if has_lens_tag "$f"; then return 1; fi
  fi
  return 0
}

# 校验成品：大小关系 + 能无损提取出原片
verify_product() {
  local jpg="$1" src="$2" off total msz cover
  [ -f "$jpg" ] || return 1
  off=$(exiftool -s3 -MicroVideoOffset "$jpg" 2>/dev/null | head -1 | tr -d ' \r')
  [ -n "${off:-}" ] || return 1
  total=$(stat -c %s "$jpg" 2>/dev/null) || return 1
  msz=$(stat -c %s "$src" 2>/dev/null) || return 1
  cover=$((total - off))
  [ "$cover" -gt 1000 ] || return 1
  [ "$off" = "$msz" ] || return 1
  # 提取尾部并比对 MD5
  tail -c "$off" "$jpg" > "/tmp/djilp.verify.$$" 2>/dev/null || return 1
  local a b
  a=$(md5sum "$src" 2>/dev/null | cut -d' ' -f1)
  b=$(md5sum "/tmp/djilp.verify.$$" 2>/dev/null | cut -d' ' -f1)
  rm -f "/tmp/djilp.verify.$$"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# 生成成品
build_product() {
  local src="$1" out="$2" base cover msz
  base=$(basename "$src")
  cover="/tmp/djilp.cover.$$.jpg"

  # ① 提封面
  if ! ffmpeg -y -loglevel error -ss "$LIVEPHOTO_KEYFRAME_TS" -i "$src" \
        -frames:v 1 -vf "scale=${LIVEPHOTO_COVER_W}:${LIVEPHOTO_COVER_H}:flags=lanczos" \
        -q:v "$LIVEPHOTO_JPEG_Q" "$cover" 2>>"$LOG"; then
    log "  ✗ 提封面失败: $base"
    rm -f "$cover"; return 1
  fi

  # ② 拼接（封面 + 原片，视频零改动）
  msz=$(stat -c %s "$src")
  cat "$cover" "$src" > "$out.tmp" 2>>"$LOG" || { log "  ✗ 拼接失败: $base"; rm -f "$cover" "$out.tmp"; return 1; }

  # ③ 写 XMP
  exiftool -overwrite_original -q \
    -XMP-GCamera:MicroVideo=1 \
    -XMP-GCamera:MicroVideoVersion=1 \
    -XMP-GCamera:MicroVideoOffset="$msz" \
    -XMP-GCamera:MicroVideoPresentationTimestampUs="$LIVEPHOTO_TS_US" \
    "$out.tmp" 2>>"$LOG" || { log "  ✗ 写XMP失败: $base"; rm -f "$cover" "$out.tmp"; return 1; }

  # ④ 校验
  if ! verify_product "$out.tmp" "$src"; then
    log "  ✗ 校验失败: $base"
    rm -f "$cover" "$out.tmp"; return 1
  fi

  rm -f "$cover"
  mv "$out.tmp" "$out" || { log "  ✗ 落位失败: $base"; return 1; }
  return 0
}

# 归档原片（MP4 + LRF）
archive_originals() {
  local src="$1" datef base lrf ok=0
  base=$(basename "$src")
  datef=$(datef_of "$base")
  mkdir -p "$RAW_DIR/$datef" 2>/dev/null

  if mv "$src" "$RAW_DIR/$datef/$base" 2>>"$LOG"; then
    manifest_set_status "$base" "$(stat -c %s "$RAW_DIR/$datef/$base")" "converted"
    ok=1
  else
    log "  ✗ 归档原片失败: $base"
    return 1
  fi

  lrf="${src%.MP4}.LRF"
  if [ -f "$lrf" ]; then
    if mv "$lrf" "$RAW_DIR/$datef/" 2>>"$LOG"; then
      manifest_set_status "$(basename "$lrf")" "$(stat -c %s "$RAW_DIR/$datef/$(basename "$lrf")")" "converted"
    else
      log "  ⚠ 归档 LRF 失败: $(basename "$lrf")"
    fi
  fi
  return 0
}

# ============ 单文件处理 ============
process_one() {
  local base="$1" datef src jpg lrf
  datef=$(datef_of "$base")
  src="$NAS_MOUNT/$datef/$base"
  jpg="$NAS_MOUNT/$datef/${base%.*}.JPG"
  lrf="${src%.MP4}.LRF"

  # 已在归档区？（状态=converted）
  if [ "$(manifest_status "$base")" = "converted" ]; then
    log "  跳过(已转换): $base"; return 2
  fi

  # 原片不在成品区？
  if [ ! -f "$src" ]; then
    log "  跳过(原片不存在): $src"; return 2
  fi

  # 跳过清单
  if list_contains "$SKIP_LIST" "$base"; then
    log "  跳过(skip清单): $base"; return 2
  fi

  # 判据
  local forced=0
  list_contains "$FORCE_LIST" "$base" && forced=1

  if [ "$forced" != "1" ]; then
    if ! is_livephoto "$src"; then
      log "  跳过(非实况): $base  dur=$(get_dur "$src")  lens=$(has_lens_tag "$src" && echo 有 || echo 无)"
      return 2
    fi
  else
    log "  ⚑ 强制转换(force清单): $base"
  fi

  # 幂等：成品已存在
  if [ -f "$jpg" ]; then
    if verify_product "$jpg" "$src"; then
      log "  成品已存在且有效，仅归档原片: $base"
      if [ "$DRY" = "1" ]; then log "  [dry-run] 会归档 $base"; return 0; fi
      archive_originals "$src" && return 0 || return 1
    else
      log "  成品已存在但无效，删除重建: $jpg"
      [ "$DRY" = "1" ] || rm -f "$jpg"
    fi
  fi

  if [ "$DRY" = "1" ]; then
    log "  [dry-run] 会转换: $base  ($(get_dur "$src")s, $(stat -c %s "$src") 字节)"
    return 0
  fi

  # 转换
  if ! build_product "$src" "$jpg"; then
    log "  ✗ 转换失败，原片保留: $base"
    return 1
  fi
  log "  ✓ 已生成: $(basename "$jpg")  ($(stat -c %s "$jpg") 字节)"

  # 归档
  if ! archive_originals "$src"; then
    log "  ⚠ 已生成成品但归档失败，原片保留在成品区: $base"
    return 1
  fi
  log "  ✓ 已归档原片: $base"
  return 0
}

# ============ 主流程 ============
main() {
  log "===== 转换任务开始 (mode=$MODE dry=$DRY) ====="

  if [ ! -d "$NAS_MOUNT" ] || [ ! -w "$NAS_MOUNT" ]; then
    log "成品区不可用: $NAS_MOUNT"; return 1
  fi
  if [ ! -f "$MANIFEST" ]; then
    log "清单不存在: $MANIFEST"; return 1
  fi
  command -v ffmpeg  >/dev/null || { log "缺少 ffmpeg"; return 1; }
  command -v exiftool >/dev/null || { log "缺少 exiftool"; return 1; }
  # ⚠️ 归档区必须是挂载点，否则会把文件写到本机磁盘（曾有过的坑）
  if [ "${SKIP_MOUNT_CHECK:-0}" != "1" ]; then
    if ! mountpoint -q "$RAW_DIR"; then
      log "❌ 归档区不是挂载点，拒绝执行: $RAW_DIR"
      log "   （这是保护措施：避免把原片写到本机磁盘而不是 NAS）"
      return 1
    fi
  fi
  mkdir -p "$RAW_DIR" 2>/dev/null || { log "归档区不可写: $RAW_DIR"; return 1; }

  local candidates=()
  if [ "$MODE" = "one" ] && [ -n "$ONE" ]; then
    candidates=("$ONE")
  else
    while IFS=$'\t' read -r n s t st; do
      [ -n "${n:-}" ] || continue
      [ "${st:-}" = "imported" ] || continue
      case "$n" in *.MP4|*.mp4) ;; *) continue ;; esac
      candidates+=("$n")
    done < "$MANIFEST"
  fi

  log "候选文件: ${#candidates[@]} 个"

  local ok=0 skip=0 fail=0
  for base in "${candidates[@]}"; do
    process_one "$base"
    case $? in
      0) ok=$((ok+1)) ;;
      2) skip=$((skip+1)) ;;
      *) fail=$((fail+1)) ;;
    esac
  done

  log "===== 完成: 转换=$ok 跳过=$skip 失败=$fail ====="
  return 0
}

# ============ 入口 ============
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec 200>"$LOCK" 2>/dev/null
if ! flock -n 200 2>/dev/null; then
  log "已有转换任务在运行，本次退出"
  exit 0
fi
main
