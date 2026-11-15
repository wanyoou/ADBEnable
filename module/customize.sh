#!/system/bin/sh
# ADB Enable - installer customization (sourced by Magisk's module_installer)
#
# Responsibilities:
#   * fix file permissions (Magisk installs everything as 0644)
#   * create the persistent state dir and the default config
#   * import any adb public keys shipped in keys/, /sdcard or /data/local/tmp

if ! command -v ui_print >/dev/null 2>&1; then
	ui_print() { echo "$1"; }
fi

ui_print "- ADB Enable $(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null)"

# --- permissions -----------------------------------------------------------
set_perm_recursive "$MODPATH" 0 0 0755 0644 2>/dev/null
for f in post-fs-data.sh service.sh action.sh uninstall.sh bin/adb-enable \
	META-INF/com/google/android/update-binary; do
	[ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755 2>/dev/null
done

# --- persistent state + default config -------------------------------------
MODDIR=$MODPATH
. "$MODPATH/common.sh"

STAGE=installer
setup_runtime
ensure_default_config
load_config
ui_print "- Config: $CONFIG_FILE (edit it, then run bin/adb-enable run)"

# --- pre-authorised adb keys ----------------------------------------------
sync_keys late >/dev/null 2>&1
keys_n=$(count_keys "$ADB_KEYS_FILE")
[ -n "$keys_n" ] || keys_n=0
ui_print "- Optional adb keys on device: $keys_n (default mode needs none)"
ui_print "- No-key mode: ro.adb.secure=0 (no prompt, no key)"

ui_print "- Reboot once, then: adb devices / scrcpy"
ui_print "- Log after boot: $LOG_FILE"
