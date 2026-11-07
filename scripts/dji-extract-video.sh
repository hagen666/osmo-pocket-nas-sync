#!/bin/bash
# ============================================================
# 从实况照片中提取原始视频（无损）
#
# 原理：实况照片是一个 JPG，尾部原样拼接着原始 MP4。
#       XMP 里的 MicroVideoOffset 记录了 MP4 占多少字节（从文件末尾算）。
#       把尾部这些字节切出来，就是逐字节无损的原片。
#
# 用法：
#   dji-extract-video.sh <实况照片.JPG> [输出路径]
#   dji-extract-video.sh --to-raw <实况照片.JPG> [输出目录]
#   dji-extract-video.sh --verify <实况照片.JPG>   # 只校验，不输出
#
# 示例：
#   dji-extract-video.sh /mnt/pocket4/2026-11-07/DJI_xxx.JPG
#     → 生成 ./DJI_xxx.MP4
#
#   dji-extract-video.sh --to-raw /mnt/pocket4/2026-11-07/DJI_xxx.JPG
#     → 生成 /mnt/pocket4_raw/2026-11-07/DJI_xxx.MP4（若已存在则跳过）
# ============================================================
set -u

NAS_MOUNT="/mnt/pocket4"
RAW_DIR="/mnt/pocket4_raw"
LOG="${DJI_EXTRACT_LOG:-/var/log/dji-extract.log}"
CONF="${DJI_IMPORT_CONF:-/etc/dji-import/config}"

[ -f "$CONF" ] && . "$CONF"

# 配置可能改了路径，依赖它的要重新算

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---- 参数 ----
MODE="file"       # file | to-raw | verify
INPUT=""
OUTPUT=""
for a in "$@"; do
  case "$a" in
    --to-raw) MODE="to-raw" ;;
    --verify) MODE="verify" ;;
    -h|--help) usage ;;
    -*) ;;
    *)
      if [ -z "$INPUT" ]; then INPUT="$a"; else OUTPUT="$a"; fi
      ;;
  esac
done

[ -n "$INPUT" ] || usage
[ -f "$INPUT" ] || { echo "❌ 文件不存在: $INPUT"; exit 1; }
command -v exiftool >/dev/null || { echo "❌ 缺少 exiftool"; exit 1; }

# ---- 读元数据 ----
OFF=$(exiftool -s3 -MicroVideoOffset "$INPUT" 2>/dev/null | head -1 | tr -d ' \r')
TOTAL=$(stat -c %s "$INPUT")

if [ -z "${OFF:-}" ] || [ "$OFF" = "-" ]; then
  echo "❌ 这不是实况照片（找不到 MicroVideoOffset）: $(basename "$INPUT")"
  echo "   提示：如果它有 MicroVideo / MicroVideoVersion 但没 Offset，可能元数据损坏"
  exit 1
fi

if ! [[ "$OFF" =~ ^[0-9]+$ ]] || [ "$OFF" -le 0 ] || [ "$OFF" -ge "$TOTAL" ]; then
  echo "❌ MicroVideoOffset 异常: $OFF （文件总大小 $TOTAL）"
  exit 1
fi

COVER=$((TOTAL - OFF))
BASE=$(basename "${INPUT%.*}")
DATE_DIR=$(basename "$(dirname "$INPUT")")

echo "===== 实况照片解析 ====="
echo "   文件: $(basename "$INPUT")"
echo "   总大小: $TOTAL 字节"
echo "   封面:   $COVER 字节"
echo "   内嵌视频: $OFF 字节"
echo "   视频起点: 第 $COVER 字节"

# ---- 校验模式 ----
if [ "$MODE" = "verify" ]; then
  TMP=$(mktemp /tmp/djix.XXXXXX.mp4)
  tail -c "$OFF" "$INPUT" > "$TMP" 2>/dev/null
  echo "   --- 提取校验 ---"
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,pix_fmt \
    -show_entries format=duration -of default=noprint_wrappers=1 "$TMP" 2>/dev/null | sed 's/^/      /'
  if [ -s "$TMP" ]; then echo "   ✅ 内嵌视频可正常解析"; else echo "   ❌ 内嵌视频无法解析"; fi
  # 若能找到归档区原片，做 MD5 比对
  RAWMP4="$RAW_DIR/$DATE_DIR/$BASE.MP4"
  if [ -f "$RAWMP4" ]; then
    A=$(md5sum "$RAWMP4" | cut -d' ' -f1)
    B=$(md5sum "$TMP" | cut -d' ' -f1)
    echo "   --- 与原片比对 ---"
    echo "      原片 MD5: $A"
    echo "      提取 MD5: $B"
    [ "$A" = "$B" ] && echo "      🎉 完全无损" || echo "      ❌ 不一致"
  else
    echo "   ℹ️  归档区没有原片，跳过 MD5 比对"
  fi
  rm -f "$TMP"
  exit 0
fi

# ---- 确定输出路径 ----
if [ "$MODE" = "to-raw" ]; then
  DEST_DIR="${OUTPUT:-$RAW_DIR/$DATE_DIR}"
  mkdir -p "$DEST_DIR"
  OUT="$DEST_DIR/$BASE.MP4"
  if [ -f "$OUT" ]; then
    A=$(stat -c %s "$OUT")
    if [ "$A" = "$OFF" ]; then
      echo "   ℹ️  归档区已有同大小文件，跳过: $(basename "$OUT")"
      exit 0
    fi
    echo "   ⚠️  归档区已有不同大小的文件，覆盖: $(basename "$OUT")"
  fi
else
  if [ -n "$OUTPUT" ]; then
    case "$OUTPUT" in
      */) mkdir -p "$OUTPUT"; OUT="$OUTPUT/$BASE.MP4" ;;
      *)  OUT="$OUTPUT" ;;
    esac
  else
    OUT="./$BASE.MP4"
  fi
fi

# ---- 提取 ----
echo "   → 输出: $OUT"
if ! tail -c "$OFF" "$INPUT" > "$OUT.tmp" 2>/dev/null; then
  echo "❌ 提取失败"
  rm -f "$OUT.tmp"
  exit 1
fi

# ---- 校验提取结果 ----
GOT=$(stat -c %s "$OUT.tmp")
if [ "$GOT" != "$OFF" ]; then
  echo "❌ 大小不符: 期望 $OFF，实际 $GOT"
  rm -f "$OUT.tmp"
  exit 1
fi

if ! ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT.tmp" >/dev/null 2>&1; then
  echo "❌ 提取出的文件不是有效视频"
  rm -f "$OUT.tmp"
  exit 1
fi

mv "$OUT.tmp" "$OUT"
echo "   ✅ 提取成功: $(basename "$OUT")  ($GOT 字节)"

# ---- 与原片比对（如果归档区有）----
RAWMP4="$RAW_DIR/$DATE_DIR/$BASE.MP4"
if [ -f "$RAWMP4" ]; then
  A=$(md5sum "$RAWMP4" | cut -d' ' -f1)
  B=$(md5sum "$OUT" | cut -d' ' -f1)
  if [ "$A" = "$B" ]; then
    echo "   🎉 与原片 MD5 完全一致（无损）"
  else
    echo "   ⚠️  与原片 MD5 不一致（可能是转换时的旧版本）"
    echo "      原片: $A"
    echo "      提取: $B"
  fi
else
  echo "   ℹ️  归档区无原片，无法做 MD5 比对"
fi

log "提取成功: $INPUT → $OUT ($GOT 字节)"
