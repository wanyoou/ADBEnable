#!/system/bin/sh
# ADB Enable - Magisk "Action" button.
#
# Re-applies everything immediately instead of waiting for the next boot.
case "$0" in
*/*) MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
*) MODDIR=${ADBEN_MODDIR:-/data/adb/modules/adb_enable} ;;
esac
[ -n "$MODDIR" ] || MODDIR=${ADBEN_MODDIR:-/data/adb/modules/adb_enable}
. "$MODDIR/common.sh"

main_action
exit $?
