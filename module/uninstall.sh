#!/system/bin/sh
# ADB Enable - runs when Magisk removes the module.
#
# Nothing is torn down on purpose:
#   * adb_enabled / development_settings_enabled stay in the settings DB
#   * /data/misc/adb/adb_keys stays, so you never lose access to a device
#     with a broken screen just because the module was removed
#   * most persist.* properties keep their current value
#   * the TCP adb port is cleared: a leftover listener is a security issue
# Flip the switches manually if you really want them off:
#   settings put global adb_enabled 0
#   setprop persist.security.adbinput 0
#   setprop persist.security.adbinstall 0
#
# Timing: Magisk runs this during post-fs-data for a "remove" module, where
# setprop can deadlock property_service.  Use resetprop for the props and
# only touch setprop when adbd is already running (i.e. live removal).

RP=$(command -v resetprop 2>/dev/null)
[ -n "$RP" ] || RP=/data/adb/magisk/resetprop
if command -v "$RP" >/dev/null 2>&1; then
	"$RP" -d service.adb.tcp.port 2>/dev/null
	"$RP" -p -d persist.adb.tcp.port 2>/dev/null
fi

# Live system removal: also reset with setprop and restart adbd so the
# already-open TCP listener is closed immediately.
if [ "$(getprop init.svc.adbd 2>/dev/null)" = running ]; then
	setprop service.adb.tcp.port -1 2>/dev/null
	setprop persist.adb.tcp.port -1 2>/dev/null
	setprop ctl.restart adbd 2>/dev/null
fi

LOG=/data/adb/adb-enable/log/uninstall.log
mkdir -p "${LOG%/*}" 2>/dev/null
printf '%s module removed (adb stays enabled, keys are kept)\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG" 2>/dev/null
exit 0
