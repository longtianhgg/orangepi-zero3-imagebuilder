#!/bin/sh
# Orange Pi Zero 3 / iStoreOS Overlay 扩容脚本
# 适用于当前项目固件布局：
#   p1 = boot (FAT)
#   p2 = SquashFS /rom
#   p3 = ext4 /overlay
#
# 设计原则：直接扩大现有 p3，不再新建 p4/p5，避免 MBR 四主分区限制。
# 第一次运行：备份分区表区域 -> 将 p3 扩到磁盘末尾 -> 安装一次性开机任务。
# 重启后：一次性任务自动执行 resize2fs 扩大 ext4，并自动删除自身。
# 如果 p3 已经扩到磁盘末尾，则直接在线执行 resize2fs。

set -u

TAG="zero3-expand"
INIT_NAME="zero3-expand-overlay-fs"
INIT_FILE="/etc/init.d/$INIT_NAME"
MIN_FREE_MIB=64

log()  { printf '[%s] %s\n' "$TAG" "$*"; }
warn() { printf '[%s] 警告: %s\n' "$TAG" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "$TAG" "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

[ "$(id -u)" = "0" ] || die "请使用 root 运行。"

need_cmd parted
need_cmd resize2fs
RESIZE2FS="$(command -v resize2fs)"
need_cmd dd
need_cmd awk
need_cmd sed
need_cmd grep

MODEL=""
if [ -r /proc/device-tree/model ]; then
    MODEL="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"
fi
[ -n "$MODEL" ] && log "设备: $MODEL"

# 从实际挂载关系识别 /overlay，避免硬编码设备名。
OVERLAY_DEV="$(awk '$2=="/overlay" {print $1; exit}' /proc/mounts 2>/dev/null)"
[ -n "$OVERLAY_DEV" ] || die "未检测到 /overlay 挂载。"
[ -b "$OVERLAY_DEV" ] || die "/overlay 不是块设备: $OVERLAY_DEV"

BASE="${OVERLAY_DEV#/dev/}"
case "$BASE" in
    mmcblk*p[0-9]*) ;;
    *) die "当前脚本只支持 mmcblkXpN 形式的 TF/eMMC 分区，检测到: $OVERLAY_DEV" ;;
esac

PARTNUM="${BASE##*p}"
DISK_BASE="${BASE%p$PARTNUM}"
DISK="/dev/$DISK_BASE"

# 当前项目固定使用 p3 作为 Overlay；不符合则停止，避免误操作。
[ "$PARTNUM" = "3" ] || die "预期 /overlay 位于 p3，但检测到 $OVERLAY_DEV。为安全起见停止。"
[ -b "$DISK" ] || die "未找到磁盘: $DISK"

FSTYPE=""
if command -v block >/dev/null 2>&1; then
    FSTYPE="$(block info "$OVERLAY_DEV" 2>/dev/null | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' | head -n1)"
fi
if [ -z "$FSTYPE" ] && command -v blkid >/dev/null 2>&1; then
    FSTYPE="$(blkid -s TYPE -o value "$OVERLAY_DEV" 2>/dev/null || true)"
fi
[ "$FSTYPE" = "ext4" ] || die "预期 $OVERLAY_DEV 为 ext4，实际检测到: ${FSTYPE:-未知}"

PTYPE="$(parted -s "$DISK" print 2>/dev/null | awk -F': ' '/Partition Table:/ {print $2; exit}')"
case "$PTYPE" in
    msdos|gpt) ;;
    *) die "不支持或无法识别的分区表类型: ${PTYPE:-未知}" ;;
esac

SYS_DISK="/sys/class/block/$DISK_BASE"
SYS_PART="/sys/class/block/$BASE"
[ -r "$SYS_DISK/size" ] || die "无法读取磁盘大小。"
[ -r "$SYS_PART/start" ] || die "无法读取 Overlay 分区起始位置。"
[ -r "$SYS_PART/size" ] || die "无法读取 Overlay 分区大小。"

DISK_SECTORS="$(cat "$SYS_DISK/size")"
PART_START="$(cat "$SYS_PART/start")"
PART_SECTORS="$(cat "$SYS_PART/size")"
PART_END=$((PART_START + PART_SECTORS))
FREE_SECTORS=$((DISK_SECTORS - PART_END))
[ "$FREE_SECTORS" -ge 0 ] || die "分区几何信息异常。"
FREE_MIB=$((FREE_SECTORS / 2048))

log "磁盘: $DISK ($PTYPE)"
log "Overlay: $OVERLAY_DEV (ext4)"
log "当前 p3 后方可用空间约: ${FREE_MIB} MiB"

# 确认 p3 是物理上最后一个分区。编号更大的分区可以存在，但只要它位于 p3 前面就不妨碍扩容。
for P in /sys/class/block/${DISK_BASE}p*; do
    [ -e "$P" ] || continue
    PNAME="${P##*/}"
    [ "$PNAME" = "$BASE" ] && continue
    [ -r "$P/start" ] || continue
    PSTART="$(cat "$P/start")"
    if [ "$PSTART" -gt "$PART_START" ]; then
        die "检测到分区 $PNAME 位于 p3 之后，不能安全把 p3 扩到磁盘末尾。"
    fi
done

# 如果存在历史 1 MiB p4，只提示，不自动删除。它位于 p3 前方时不会阻碍直接扩大 p3。
P4_SYS="/sys/class/block/${DISK_BASE}p4"
if [ -e "$P4_SYS" ] && [ -r "$P4_SYS/size" ]; then
    P4_SECTORS="$(cat "$P4_SYS/size")"
    P4_START="$(cat "$P4_SYS/start" 2>/dev/null || echo 0)"
    if [ "$P4_SECTORS" = "2048" ] && [ "$P4_START" -lt "$PART_START" ]; then
        warn "检测到历史 1 MiB p4。它在 p3 前方，不影响本脚本扩容；本脚本不会自动删除它。"
    fi
fi

# p3 已经基本占满磁盘：只需要扩文件系统。
if [ "$FREE_MIB" -lt "$MIN_FREE_MIB" ]; then
    log "p3 已经接近磁盘末尾，直接执行 ext4 在线扩容。"
    resize2fs "$OVERLAY_DEV" || die "resize2fs 执行失败。"
    log "完成。当前 /overlay 容量："
    df -h /overlay 2>/dev/null || true
    exit 0
fi

# 备份前 1 MiB：包含 MBR/GPT 前部元数据以及本平台磁盘开头的关键区域。
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
BACKUP_DIR="/root"
if [ -d /mnt/mmcblk0p1 ] && grep -q " /mnt/mmcblk0p1 " /proc/mounts 2>/dev/null && [ -w /mnt/mmcblk0p1 ]; then
    BACKUP_DIR="/mnt/mmcblk0p1"
fi
BACKUP="$BACKUP_DIR/${DISK_BASE}-first1MiB-$STAMP.bin"
log "备份磁盘前 1 MiB 到: $BACKUP"
dd if="$DISK" of="$BACKUP" bs=1M count=1 >/dev/null 2>&1 || die "备份失败，停止扩容。"
sync
[ -s "$BACKUP" ] || die "备份文件为空，停止扩容。"
if command -v sha256sum >/dev/null 2>&1; then
    SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
    log "备份 SHA256: $SHA"
fi

log "扩展 p3 到磁盘末尾。不会新建 p4/p5。"
# GNU parted 在已挂载分区上会要求确认；--pretend-input-tty 允许脚本明确输入 Yes。
if printf 'Yes\n' | parted ---pretend-input-tty "$DISK" resizepart "$PARTNUM" 100%; then
    :
else
    die "parted 扩展分区失败。备份保留在: $BACKUP"
fi

log "新的磁盘分区表："
parted -s "$DISK" unit MiB print free 2>/dev/null || true

# 因为 /overlay 正在使用，内核通常需要重启后才能按新边界重新识别 p3。
# 安装一次性开机任务，重启后自动 resize2fs 并自删除。
cat > "$INIT_FILE" <<EOF2
#!/bin/sh /etc/rc.common
START=99
STOP=10

boot() {
    DEV="$OVERLAY_DEV"
    LOG="/tmp/zero3-expand-overlay.log"
    echo "[zero3-expand] boot stage: resize2fs \$DEV" > "\$LOG"
    sleep 3
    if "$RESIZE2FS" "\$DEV" >> "\$LOG" 2>&1; then
        logger -t zero3-expand "Overlay filesystem resized successfully: \$DEV"
        rm -f /etc/rc.d/S99$INIT_NAME
        rm -f "$INIT_FILE"
    else
        logger -t zero3-expand "Overlay filesystem resize failed; see \$LOG"
    fi
}
EOF2
chmod 0755 "$INIT_FILE" || die "无法创建一次性启动任务。"
"$INIT_FILE" enable || die "无法启用一次性启动任务。"

log "分区表扩展已完成。下一步必须重启，让内核重新读取 p3 边界。"
log "重启后脚本会自动执行 resize2fs，并删除一次性启动任务。"
log "验证命令: lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS $DISK ; df -h /overlay"

printf '是否现在重启？[y/N] '
read ANSWER
case "$ANSWER" in
    y|Y|yes|YES|Yes)
        sync
        reboot
        ;;
    *)
        log "未自动重启。请稍后手工执行: reboot"
        ;;
esac
