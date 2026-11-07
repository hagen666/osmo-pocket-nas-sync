#!/bin/bash
# ============================================================
# 实况照片回滚工具
#   把已转换的实况照片还原成「原片 + LRF」，清单状态改回 imported
#
# 用法：
#   dji-restore.sh --list                 # 列出所有已转换的
#   dji-restore.sh DJI_20261107111324     # 按文件名片段匹配回滚
#   dji-restore.sh --all                  # 全部回滚
#   dji-restore.sh --dry-run <pattern>    # 只报告
#
# 说明：
#   - 原片从 RAW_DIR 移回成品区
#   - 成品 JPG 移到 RAW_DIR/.trash/<日期>/ （可恢复，不直接删）
#   - 清单状态 converted → imported
# ============================================================
set -u

NAS_MOUNT="/mnt/pocket4"
RAW_DIR="/mnt/pocket4_raw"
MANIFEST="$NAS_MOUNT/.dji-manifest.tsv"
LOG="${DJI_RESTORE_LOG:-/var/log/dji-restore.log}"
CONF="${DJI_IMPORT_CONF:-/etc/dji-import/config}"
TRASH="$RAW_DIR/.trash"

[ -f "$CONF" ] && . "$CONF"

# 配置可能改了 NAS_MOUNT，依赖它的路径要重新算
MANIFEST="$NAS_MOUNT/.dji-manifest.tsv"
TRASH="$RAW_DIR/.trash"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

datef_of() {
  local d
  d=$(echo "$1" | grep -oP 'DJI_\K\d{8}' | head -1 || true)
  if [ -n "${d:-}" ]; then echo "${d:0:4}-${d:4:2}-${d:6:2}"; else echo "其他"; fi
}

manifest_set_status() {
  local n="$1" sz="$2" st="$3" tm
  tm=$(date '+%F %T')
  awk -F'\t' -v OFS='\t' -v n="$n" -v sz="$sz" -v st="$st" -v tm="$tm" \
    '{ if ($1==n) { $2=sz; $3=tm; $4=st } print }' "$MANIFEST" > "$MANIFEST.tmp" \
    && mv "$MANIFEST.tmp" "$MANIFEST"
}

# ---- 参数 ----
ACTION="restore"
PATTERN=""
DRY=0
for a in "$@"; do
  case "$a" in
    --list)    ACTION="list" ;;
    --all)     ACTION="all" ;;
    --dry-run) DRY=1 ;;
    -*)        ;;
    *)         PATTERN="$a" ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "❌ 清单不存在: $MANIFEST"; exit 1; }

# ---- 列出 ----
if [ "$ACTION" = "list" ]; then
  echo "===== 已转换的实况照片 ====="
  local_n=0
  while IFS=$'\t' read -r n s t st; do
    [ "${st:-}" = "converted" ] || continue
    case "$n" in *.MP4|*.mp4) ;; *) continue ;; esac
    local_n=$((local_n+1))
    printf "  %-42s %10.1f MB\n" "$n" "$(echo "scale=1;$s/1048576"|bc)"
  done < "$MANIFEST"
  echo "  合计: ${local_n} 个"
  exit 0
fi

# ---- 回滚单个 ----
restore_one() {
  local base="$1" datef src jpg lrf rawmp4 rawlrf
  datef=$(datef_of "$base")
  src="$NAS_MOUNT/$datef/$base"
  jpg="$NAS_MOUNT/$datef/${base%.*}.JPG"
  rawmp4="$RAW_DIR/$datef/$base"
  rawlrf="$RAW_DIR/$datef/${base%.*}.LRF"
  lrf="$NAS_MOUNT/$datef/${base%.*}.LRF"

  if [ ! -f "$rawmp4" ]; then
    log "✗ 归档区找不到原片: $rawmp4"
    echo "  ✗ 归档区找不到原片: $base"
    return 1
  fi
  if [ -f "$src" ]; then
    log "✗ 成品区已存在同名文件，中止: $src"
    echo "  ✗ 成品区已有同名文件，中止: $base"
    return 1
  fi

  if [ "$DRY" = "1" ]; then
    echo "  [dry-run] 会回滚: $base"
    echo "             原片: $rawmp4 → $src"
    [ -f "$rawlrf" ] && echo "             LRF : $rawlrf → $lrf"
    [ -f "$jpg" ]  && echo "             成品: $jpg → $TRASH/$datef/"
    return 0
  fi

  # 1) 原片移回
  if ! mv "$rawmp4" "$src" 2>>"$LOG"; then
    log "✗ 移动原片失败: $base"; echo "  ✗ 移动原片失败"; return 1
  fi
  manifest_set_status "$base" "$(stat -c %s "$src")" "imported"

  # 2) LRF 移回
  if [ -f "$rawlrf" ]; then
    if mv "$rawlrf" "$lrf" 2>>"$LOG"; then
      manifest_set_status "$(basename "$lrf")" "$(stat -c %s "$lrf")" "imported"
    else
      log "⚠ LRF 移动失败: ${base%.*}.LRF"
    fi
  fi

  # 3) 成品 JPG 移到回收站
  if [ -f "$jpg" ]; then
    mkdir -p "$TRASH/$datef"
    mv "$jpg" "$TRASH/$datef/" 2>>"$LOG" || log "⚠ 成品移动失败: $jpg"
  fi

  log "✓ 已回滚: $base"
  echo "  ✓ 已回滚: $base"
  return 0
}

# ---- 收集目标 ----
TARGETS=()
if [ "$ACTION" = "all" ]; then
  while IFS=$'\t' read -r n s t st; do
    [ "${st:-}" = "converted" ] || continue
    case "$n" in *.MP4|*.mp4) ;; *) continue ;; esac
    TARGETS+=("$n")
  done < "$MANIFEST"
elif [ -n "$PATTERN" ]; then
  while IFS=$'\t' read -r n s t st; do
    [ "${st:-}" = "converted" ] || continue
    case "$n" in *.MP4|*.mp4) ;; *) continue ;; esac
    case "$n" in *"$PATTERN"*) TARGETS+=("$n") ;; esac
  done < "$MANIFEST"
else
  echo "用法:"
  echo "  dji-restore.sh --list                 # 列出已转换"
  echo "  dji-restore.sh <文件名片段>            # 回滚匹配项"
  echo "  dji-restore.sh --all                  # 全部回滚"
  echo "  dji-restore.sh --dry-run <片段>        # 演练"
  exit 1
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "没有匹配的已转换文件"
  exit 0
fi

echo "===== 回滚 ${#TARGETS[@]} 个（dry=$DRY）====="
ok=0; fail=0
for b in "${TARGETS[@]}"; do
  if restore_one "$b"; then ok=$((ok+1)); else fail=$((fail+1)); fi
done
echo "===== 完成: 成功=$ok 失败=$fail ====="
echo "  成品 JPG 已移至: $TRASH"
log "===== 回滚完成: 成功=$ok 失败=$fail ====="
