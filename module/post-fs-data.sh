#!/system/bin/sh
# ADB Enable - post-fs-data stage.
#
# Runs BLOCKING and very early (before Zygote), so it must stay short:
#   * set the early properties with resetprop (setprop dead-locks here)
#   * seed /data/misc/adb/adb_keys before adbd is ever started
# No waiting, no binder calls, no `settings` here.
case "$0" in
*/*) MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
*) MODDIR=${ADBEN_MODDIR:-/data/adb/modules/adb_enable} ;;
esac
[ -n "$MODDIR" ] || MODDIR=${ADBEN_MODDIR:-/data/adb/modules/adb_enable}
. "$MODDIR/common.sh"

main_post_fs_data
exit 0
