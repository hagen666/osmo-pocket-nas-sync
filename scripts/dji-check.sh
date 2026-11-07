#!/bin/bash
ok(){ echo "   ✅ $*"; }; bad(){ echo "   ❌ $*"; }; info(){ echo "   ℹ️  $*"; }
NAS_MOUNT="${NAS_MOUNT:-/mnt/pocket4}"
RAW_DIR="${RAW_DIR:-/mnt/pocket4_raw}"
MANIFEST="$NAS_MOUNT/.dji-manifest.tsv"
CONF="${DJI_IMPORT_CONF:-/etc/dji-import/config}"
[ -f "$CONF" ] && . "$CONF"
echo "======== 大疆备份 + 实况转换 自检 ========"

# 组件
[ -f /etc/udev/rules.d/99-dji-import.rules ] && ok "udev 规则" || bad "udev 规则缺失"
systemctl cat dji-import.service >/dev/null 2>&1 && ok "备份服务" || bad "备份服务缺失"
[ -x /usr/local/bin/dji-import.sh ] && ok "备份脚本" || bad "备份脚本缺失"
[ -x /usr/local/bin/dji-livephoto-convert.sh ] && ok "转换脚本" || bad "转换脚本缺失"
systemctl is-enabled dji-livephoto-scan.timer >/dev/null 2>&1 && ok "定时转换器（90分钟）" || bad "定时器未启用"

# 挂载
mountpoint -q "$NAS_MOUNT" && ok "成品区已挂载 ($NAS_MOUNT)" || bad "成品区未挂载"
if mountpoint -q "$RAW_DIR"; then ok "归档区已挂载 ($RAW_DIR)"
else bad "归档区不是挂载点！转换会被拒绝执行"; fi

# 清单
if [ -f "$MANIFEST" ]; then
  C=$(awk -F'\t' 'NF>0{print NF; exit}' "$MANIFEST")
  [ "$C" -ge 4 ] && ok "清单 v2（$(wc -l < "$MANIFEST") 条）" || bad "清单仍是 v1"
  info "imported=$(awk -F'\t' '$4=="imported"' "$MANIFEST"|wc -l)  converted=$(awk -F'\t' '$4=="converted"' "$MANIFEST"|wc -l)"
fi

# 数量
PJ=$(find "$NAS_MOUNT" -name '*.JPG' 2>/dev/null | wc -l)
PM=$(find "$NAS_MOUNT" -name '*.MP4' 2>/dev/null | wc -l)
RM=$(find "$RAW_DIR" -name '*.MP4' 2>/dev/null | wc -l)
[ "$PJ" -ge "$RM" ] && ok "成品区 JPG=$PJ ≥ 归档 MP4=$RM" || info "JPG=$PJ / 归档MP4=$RM"

# HA
T=$(cat /etc/dji-import/ha_token 2>/dev/null)
if [ -n "${T:-}" ] && [ -n "${HA_URL:-}" ]; then
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 8 -H "Authorization: Bearer $T" "$HA_URL/api/" 2>/dev/null)
  [ "$c" = "200" ] && ok "HA 令牌有效" || bad "HA 令牌无效（HTTP $c）"
else
  info "未配置 HA，跳过令牌检查"
fi

lsusb 2>/dev/null | grep -qi 2ca3 && ok "相机已插入" || info "相机未插入"
echo "   ℹ️  最近日志："; tail -2 /var/log/dji-import.log 2>/dev/null | sed 's/^/      /'
echo "=========================================="
