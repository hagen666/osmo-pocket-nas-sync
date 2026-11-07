#!/bin/bash
# ============================================================
# 大疆导入清单迁移：v1(3列) → v2(4列，增加 status)
#
# v1: 文件名 <TAB> 大小 <TAB> 导入时间
# v2: 文件名 <TAB> 大小 <TAB> 导入时间 <TAB> 状态
#
# 状态取值：
#   imported  = 原片在成品区（默认）
#   converted = 原片已转换并归档到 RAW_DIR
#
# 用法：
#   dji-manifest-migrate            # 执行迁移
#   dji-manifest-migrate --dry-run  # 只报告不修改
# ============================================================
set -u

NAS_MOUNT="${NAS_MOUNT:-/mnt/pocket4}"
RAW_DIR="${RAW_DIR:-/mnt/pocket4_raw}"
MANIFEST="${MANIFEST:-$NAS_MOUNT/.dji-manifest.tsv}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

datef_of() {
  local d
  d=$(echo "$1" | grep -oP 'DJI_\K\d{8}' | head -1 || true)
  if [ -n "${d:-}" ]; then echo "${d:0:4}-${d:4:2}-${d:6:2}"; else echo "其他"; fi
}

[ -f "$MANIFEST" ] || { echo "❌ 清单不存在: $MANIFEST"; exit 1; }

COLS=$(awk -F'\t' 'NF>0{print NF; exit}' "$MANIFEST")
echo "===== 清单迁移 ====="
echo "   文件: $MANIFEST"
echo "   当前列数: ${COLS:-0}"
echo "   总条数: $(wc -l < "$MANIFEST")"

if [ "${COLS:-0}" -ge 4 ]; then
  echo "   ✅ 已经是 v2 格式，无需迁移"
  exit 0
fi

if [ "$DRY" = "1" ]; then
  echo "   [dry-run] 将把 3 列迁移为 4 列（状态默认 imported）"
  exit 0
fi

# 备份
BAK="$MANIFEST.v1.bak.$(date +%Y%m%d_%H%M%S)"
cp -p "$MANIFEST" "$BAK" && echo "   ✅ 已备份: $BAK"

TMP=$(mktemp)
N_IMPORTED=0
N_CONVERTED=0

while IFS=$'\t' read -r name size ts rest; do
  [ -n "${name:-}" ] || continue

  # 已经是 4 列 → 原样保留
  if [ -n "${rest:-}" ]; then
    printf '%s\t%s\t%s\t%s\n' "$name" "$size" "$ts" "$rest" >> "$TMP"
    continue
  fi

  datef=$(datef_of "$name")
  status="imported"

  # 判断当前位置：成品区优先，其次归档区
  if [ -f "$NAS_MOUNT/$datef/$name" ] \
     && [ "$(stat -c %s "$NAS_MOUNT/$datef/$name" 2>/dev/null)" = "$size" ]; then
    status="imported"
    N_IMPORTED=$((N_IMPORTED + 1))
  elif [ -f "$RAW_DIR/$datef/$name" ] \
     && [ "$(stat -c %s "$RAW_DIR/$datef/$name" 2>/dev/null)" = "$size" ]; then
    status="converted"
    N_CONVERTED=$((N_CONVERTED + 1))
  else
    # 哪都找不到 → 保守标记 imported，下次备份会自动重传
    status="imported"
    N_IMPORTED=$((N_IMPORTED + 1))
  fi

  printf '%s\t%s\t%s\t%s\n' "$name" "$size" "$ts" "$status" >> "$TMP"
done < "$MANIFEST"

mv "$TMP" "$MANIFEST"
echo "   ✅ 迁移完成"
echo "      imported : $N_IMPORTED 条"
echo "      converted: $N_CONVERTED 条"
echo "      新列数   : $(awk -F'\t' 'NF>0{print NF; exit}' "$MANIFEST")"
echo
echo "   前 3 行预览:"
head -3 "$MANIFEST" | sed 's/^/      /'
