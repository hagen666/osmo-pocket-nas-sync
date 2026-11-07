#!/bin/bash
# ============================================================
# osmo-pocket-nas-sync 安装脚本
#
# 用法:
#   sudo ./install.sh              # 完整安装
#   sudo ./install.sh --scripts    # 只装脚本（不装 systemd/udev）
#   sudo ./install.sh --uninstall  # 卸载
# ============================================================
set -eu

PREFIX="/usr/local/bin"
CONF_DIR="/etc/dji-import"
UNIT_DIR="/etc/systemd/system"
UDEV_DIR="/etc/udev/rules.d"
LOG_DIR="/var/log"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
ok()   { echo "${GREEN}✅${NC} $*"; }
warn() { echo "${YELLOW}⚠️${NC}  $*"; }
die()  { echo "${RED}❌${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 sudo 运行: sudo $0"

ACTION="install"
case "${1:-}" in
  --scripts)   ACTION="scripts" ;;
  --uninstall) ACTION="uninstall" ;;
  -h|--help)   sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 卸载 ----------
if [ "$ACTION" = "uninstall" ]; then
  echo "=== 卸载 osmo-pocket-nas-sync ==="
  systemctl disable --now dji-livephoto-scan.timer 2>/dev/null || true
  systemctl stop dji-import.service 2>/dev/null || true
  rm -f "$UNIT_DIR/dji-import.service" \
        "$UNIT_DIR/dji-livephoto-scan.service" \
        "$UNIT_DIR/dji-livephoto-scan.timer" \
        "$UDEV_DIR/99-dji-import.rules"
  rm -f "$PREFIX/dji-import.sh" \
        "$PREFIX/dji-livephoto-convert.sh" \
        "$PREFIX/dji-restore" \
        "$PREFIX/dji-extract-video" \
        "$PREFIX/dji-check" \
        "$PREFIX/dji-manifest-migrate"
  systemctl daemon-reload
  udevadm control --reload-rules 2>/dev/null || true
  ok "已卸载脚本和服务"
  warn "配置目录 $CONF_DIR 与日志 $LOG_DIR/dji-*.log 保留，如需清理请手动删除"
  warn "NAS 挂载点与 /etc/fstab 条目未改动，如需清理请手动编辑"
  exit 0
fi

# ---------- 依赖检查 ----------
echo "=== 检查依赖 ==="
MISSING=()
for c in ffmpeg ffprobe exiftool curl; do
  command -v "$c" >/dev/null 2>&1 || MISSING+=("$c")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  warn "缺少命令: ${MISSING[*]}"
  echo ""
  echo "  Ubuntu/Debian 安装:"
  echo "    sudo apt update"
  echo "    sudo apt install -y ffmpeg libimage-exiftool-perl curl"
  echo ""
  read -r -p "是否现在安装？[y/N] " ans
  case "$ans" in
    [yY]*)
      apt-get update -qq
      apt-get install -y ffmpeg libimage-exiftool-perl curl
      ;;
    *) die "依赖不全，退出" ;;
  esac
fi
ok "依赖齐全"

# ---------- 安装脚本 ----------
echo "=== 安装脚本到 $PREFIX ==="
install -m 755 "$SCRIPT_DIR/scripts/dji-import.sh"              "$PREFIX/dji-import.sh"
install -m 755 "$SCRIPT_DIR/scripts/dji-livephoto-convert.sh"   "$PREFIX/dji-livephoto-convert.sh"
install -m 755 "$SCRIPT_DIR/scripts/dji-restore.sh"             "$PREFIX/dji-restore"
install -m 755 "$SCRIPT_DIR/scripts/dji-extract-video.sh"       "$PREFIX/dji-extract-video"
install -m 755 "$SCRIPT_DIR/scripts/dji-check.sh"               "$PREFIX/dji-check"
install -m 755 "$SCRIPT_DIR/scripts/dji-manifest-migrate.sh"    "$PREFIX/dji-manifest-migrate"
ok "6 个脚本已安装"

# ---------- 配置 ----------
echo "=== 配置目录 $CONF_DIR ==="
mkdir -p "$CONF_DIR"
if [ -f "$CONF_DIR/config" ]; then
  warn "$CONF_DIR/config 已存在，不覆盖（如需重置请手动删除）"
else
  install -m 600 "$SCRIPT_DIR/config/config.example" "$CONF_DIR/config"
  ok "已创建 $CONF_DIR/config（请按需修改）"
fi
if [ ! -f "$CONF_DIR/ha_token" ]; then
  touch "$CONF_DIR/ha_token"
  chmod 600 "$CONF_DIR/ha_token"
  warn "未配置 HA 令牌（$CONF_DIR/ha_token 为空）→ 不会播报，不影响备份"
fi

# ---------- systemd ----------
if [ "$ACTION" = "install" ]; then
  echo "=== 安装 systemd 服务 ==="
  install -m 644 "$SCRIPT_DIR/systemd/dji-import.service"           "$UNIT_DIR/dji-import.service"
  install -m 644 "$SCRIPT_DIR/systemd/dji-livephoto-scan.service"   "$UNIT_DIR/dji-livephoto-scan.service"
  install -m 644 "$SCRIPT_DIR/systemd/dji-livephoto-scan.timer"     "$UNIT_DIR/dji-livephoto-scan.timer"
  systemctl daemon-reload
  systemctl enable --now dji-livephoto-scan.timer
  ok "定时转换器已启用（每 90 分钟）"
  # dji-import.service 由 udev 触发，不需要 enable
  ok "备份服务已安装（udev 触发，无需 enable）"

  echo "=== 安装 udev 规则 ==="
  install -m 644 "$SCRIPT_DIR/udev/99-dji-import.rules" "$UDEV_DIR/99-dji-import.rules"
  udevadm control --reload-rules 2>/dev/null || true
  ok "udev 规则已安装"
fi

# ---------- 自检 ----------
echo
echo "=== 自检 ==="
"$PREFIX/dji-check" || true

echo
echo "=========================================="
ok "安装完成"
echo
echo "下一步:"
echo "  1. 编辑配置:  sudo nano $CONF_DIR/config"
echo "  2. 配置 NAS:  参考 README 的「NAS 挂载」章节"
echo "  3. 自检:      sudo dji-check"
echo "  4. 插上相机测试"
echo "=========================================="
