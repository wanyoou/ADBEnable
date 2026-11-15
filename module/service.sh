#!/system/bin/sh
# ADB Enable - late_start service stage.
#
# Non-blocking.  Waits for Android to finish booting, then:
#   settings  -> turn the real "USB debugging" switch on
#   props     -> MIUI / HyperOS security bypass
#   keys      -> merge and install pre-authorized adb keys
#   usb       -> re-enumerate the gadget / start adbd
#   wireless  -> optional TCP listener
#   status    -> one status line per subsystem in the log
case "$0" in
*/*) MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
*) MODDIR=${ADBEN_MODDIR:-/data/adb/modules/adb_enable} ;;
esac
[ -n "$MODDIR" ] || MODDIR=${ADBEN_MODDIR:-/data/adb/modules/adb_enable}
. "$MODDIR/common.sh"

main_service
exit 0
