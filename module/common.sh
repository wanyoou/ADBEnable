#!/system/bin/sh
# ============================================================================
# ADB Enable - shared library
#
# Sourced by post-fs-data.sh, service.sh, action.sh, customize.sh and
# bin/adb-enable.  Must stay POSIX sh / Magisk BusyBox ash compatible.
#
# DESIGN RULE (this is the bug that made the first manual fix fail):
#   Never let a binder backed command (settings / svc / pm / wm / input)
#   inherit an open file descriptor to a log file under /data/adb.
#   system_server has no SELinux write access there, so
#       settings put ... >> /data/adb/foo.log
#   fails with "Failed transaction (2147483646)" and the setting is never
#   applied.  Every such call goes through bcmd(), which captures stdout
#   through an anonymous pipe and only then writes the log line.
# ============================================================================

# ------------------------------------------------------------------ paths --
MODDIR="${MODDIR:-${0%/*}}"

# All paths are controlled by the environment / the module, never by the
# editable config file: re-applying this after load_config() makes a typo in
# the config unable to retarget the trust store, the log or the state dir.
reset_paths() {
	ADB_DIR="${ADBEN_ADB_DIR:-/data/adb}"
	STATE_DIR="${ADBEN_STATE_DIR:-$ADB_DIR/adb-enable}"
	KEYS_DIR="$STATE_DIR/keys"
	CONFIG_FILE="${ADBEN_CONFIG:-$STATE_DIR/config}"
	LOG_DIR="$STATE_DIR/log"
	LOG_FILE="${ADBEN_LOG:-$LOG_DIR/adb-enable.log}"
	# Set by post-fs-data only if adbd was already running before
	# ro.adb.secure=0 was applied.  The service stage must not restart a
	# daemon that was started after the property was set: that would drop
	# an already working USB session for no reason.
	ADBD_PREEXISTING_FLAG="$STATE_DIR/.adbd_preexisting"
	ADB_MISC_DIR="${ADBEN_ADB_MISC_DIR:-/data/misc/adb}"
	ADB_KEYS_FILE="${ADBEN_ADB_KEYS:-$ADB_MISC_DIR/adb_keys}"
	SYSTEM_BIN="${ADBEN_SYSTEM_BIN:-/system/bin}"
}
reset_paths

# --------------------------------------------------------------- defaults --
# Every option can be overridden in $CONFIG_FILE (plain KEY=VALUE lines).
ENABLE_ADB=1                 # master switch
FORCE_INSECURE_ADB=1         # ro.adb.secure=0 -> no auth, no key needed
USB_CONFIG="mtp,adb"         # value for persist/sys.usb.config
USB_CONFIG_ADB_ONLY="adb"    # fallback value
FORCE_USB_REENUM=1           # re-enumerate the USB gadget when adb is missing
START_ADBD=1                 # start adbd if it is not running
SKIP_SETUP_WIZARD=1          # mark device as provisioned (fresh wipe / BFU)
PROVISION_EARLY=1            # do it before boot completes, ahead of Setup Wizard
DISABLE_SETUP_WIZARD_PACKAGES=0
MIUI_SECURITY_BYPASS=1       # persist.security.adbinput / adbinstall
MIUI_FASTBOOT_BYPASS=0       # persist.fastboot.enable (do not enable by default)
FORCE_DEBUGGABLE=0           # ro.debuggable=1 (allows "adb root")
WIRELESS_ADB=0               # also listen on TCP (adb tcpip style)
WIRELESS_PORT=5555
WAKE_SCREEN=1                # KEYCODE_WAKEUP once per boot
STAY_AWAKE=0                 # stay_on_while_plugged_in=7 (screen never sleeps)
DISMISS_KEYGUARD=1           # wm dismiss-keyguard (insecure keyguard only)
BOOT_DELAY=8                 # seconds to wait after sys.boot_completed
BOOT_WAIT_SECONDS=240        # give up waiting for boot after this
RECHECK_SECONDS=90           # keep re-asserting adb_enabled for this long
RECHECK_INTERVAL=15
SETTINGS_RETRIES=4
SETTINGS_RETRY_DELAY=2
KEYS_KEEP_EXISTING=1         # never drop keys already trusted by the device
KEYS_FROM_STORAGE=0          # opt-in: import /sdcard/adb-enable/keys/* (see README)
KEYS_BACKUP=1                # keep adb_keys.bak next to adb_keys
LOG_MAX_BYTES=262144

# ------------------------------------------------------------------- misc --
STAGE="${STAGE:-runtime}"    # post-fs-data | service | action | cli | runtime
PROP_STAGE="${PROP_STAGE:-late}"
RESETPROP="${RESETPROP:-}"
GETPROP_CMD="${GETPROP_CMD:-}"
SETPROP_CMD="${SETPROP_CMD:-}"
SETTINGS_CMD="${SETTINGS_CMD:-}"
SVC_CMD="${SVC_CMD:-}"
PM_CMD="${PM_CMD:-}"
WM_CMD="${WM_CMD:-}"
INPUT_CMD="${INPUT_CMD:-}"
IP_CMD="${IP_CMD:-}"

# ------------------------------------------------------------------- log ----
log() {
	mkdir -p "$LOG_DIR" 2>/dev/null
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" \
		"$STAGE" "$*" >>"$LOG_FILE" 2>/dev/null
	return 0
}

rotate_log() {
	[ -f "$LOG_FILE" ] || return 0
	size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
	case "$size" in '' | *[!0-9]*) return 0 ;; esac
	[ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
	mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
	touch "$LOG_FILE" 2>/dev/null
}

# --------------------------------------------------------------- helpers ----
have() { command -v "$1" >/dev/null 2>&1; }

bool01() {
	case "$1" in 1 | on | ON | On | true | TRUE | yes | YES) echo 1 ;; *) echo 0 ;; esac
}

int_or() {
	case "$1" in '' | *[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac
}

prop_get() {
	[ -n "$GETPROP_CMD" ] || return 0
	"$GETPROP_CMD" "$1" 2>/dev/null | tr -d '\r'
}

module_version() {
	sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1
}

# Run a command with stdout/stderr going to the log file.  Only for commands
# that do NOT talk to system_server (setprop, resetprop, chmod, ...).
run_quiet() {
	"$@" >>"$LOG_FILE" 2>&1
	rc=$?
	log "run[$*] rc=$rc"
	return $rc
}

# Run a binder backed command.  stdout+stderr are captured through a pipe so
# that system_server never receives a /data/adb file descriptor.
# Result: $BCMD_OUT (single line, trimmed) and $BCMD_RC.
bcmd() {
	BCMD_OUT=$("$@" </dev/null 2>&1)
	BCMD_RC=$?
	BCMD_OUT=$(printf '%s' "$BCMD_OUT" | tr '\r\n' '  ' | cut -c 1-400)
	log "bcmd[$*] rc=$BCMD_RC${BCMD_OUT:+ out=$BCMD_OUT}"
	return $BCMD_RC
}

# Resolve an Android command, preferring the real binary over a BusyBox
# applet of the same name.  Magisk runs boot scripts with ASH_STANDALONE=1,
# where names such as `svc` or `ip` would otherwise resolve to BusyBox
# applets with different behaviour.
resolve_system_cmd() {
	if [ -x "$SYSTEM_BIN/$1" ]; then
		printf '%s/%s' "$SYSTEM_BIN" "$1"
		return 0
	fi
	command -v "$1" 2>/dev/null
}

resolve_tools() {
	if [ -z "$RESETPROP" ]; then
		for p in resetprop /data/adb/magisk/resetprop; do
			if command -v "$p" >/dev/null 2>&1; then
				RESETPROP=$p
				break
			fi
		done
	fi
	GETPROP_CMD=$(resolve_system_cmd getprop)
	SETPROP_CMD=$(resolve_system_cmd setprop)
	SETTINGS_CMD=$(resolve_system_cmd settings)
	SVC_CMD=$(resolve_system_cmd svc)
	PM_CMD=$(resolve_system_cmd pm)
	WM_CMD=$(resolve_system_cmd wm)
	INPUT_CMD=$(resolve_system_cmd input)
	IP_CMD=$(resolve_system_cmd ip)
	[ -n "$RESETPROP" ] || log "warning: resetprop not found, falling back to setprop"
}

# --------------------------------------------------------------- config -----
normalize_config() {
	ENABLE_ADB=$(bool01 "$ENABLE_ADB")
	FORCE_INSECURE_ADB=$(bool01 "$FORCE_INSECURE_ADB")
	FORCE_USB_REENUM=$(bool01 "$FORCE_USB_REENUM")
	START_ADBD=$(bool01 "$START_ADBD")
	SKIP_SETUP_WIZARD=$(bool01 "$SKIP_SETUP_WIZARD")
	DISABLE_SETUP_WIZARD_PACKAGES=$(bool01 "$DISABLE_SETUP_WIZARD_PACKAGES")
	PROVISION_EARLY=$(bool01 "$PROVISION_EARLY")
	MIUI_SECURITY_BYPASS=$(bool01 "$MIUI_SECURITY_BYPASS")
	MIUI_FASTBOOT_BYPASS=$(bool01 "$MIUI_FASTBOOT_BYPASS")
	FORCE_DEBUGGABLE=$(bool01 "$FORCE_DEBUGGABLE")
	WIRELESS_ADB=$(bool01 "$WIRELESS_ADB")
	WAKE_SCREEN=$(bool01 "$WAKE_SCREEN")
	STAY_AWAKE=$(bool01 "$STAY_AWAKE")
	DISMISS_KEYGUARD=$(bool01 "$DISMISS_KEYGUARD")
	KEYS_KEEP_EXISTING=$(bool01 "$KEYS_KEEP_EXISTING")
	KEYS_FROM_STORAGE=$(bool01 "$KEYS_FROM_STORAGE")
	KEYS_BACKUP=$(bool01 "$KEYS_BACKUP")

	WIRELESS_PORT=$(int_or "$WIRELESS_PORT" 5555)
	[ "$WIRELESS_PORT" -ge 1 ] 2>/dev/null && [ "$WIRELESS_PORT" -le 65535 ] 2>/dev/null \
		|| WIRELESS_PORT=5555
	BOOT_DELAY=$(int_or "$BOOT_DELAY" 8)
	BOOT_WAIT_SECONDS=$(int_or "$BOOT_WAIT_SECONDS" 240)
	RECHECK_SECONDS=$(int_or "$RECHECK_SECONDS" 90)
	RECHECK_INTERVAL=$(int_or "$RECHECK_INTERVAL" 15)
	[ "$RECHECK_INTERVAL" -ge 1 ] 2>/dev/null || RECHECK_INTERVAL=15
	SETTINGS_RETRIES=$(int_or "$SETTINGS_RETRIES" 4)
	[ "$SETTINGS_RETRIES" -ge 1 ] 2>/dev/null || SETTINGS_RETRIES=1
	SETTINGS_RETRY_DELAY=$(int_or "$SETTINGS_RETRY_DELAY" 2)
	LOG_MAX_BYTES=$(int_or "$LOG_MAX_BYTES" 262144)
	[ "$LOG_MAX_BYTES" -ge 65536 ] 2>/dev/null || LOG_MAX_BYTES=262144

	case "$USB_CONFIG" in
	"" | *[!A-Za-z0-9,._+-]*) USB_CONFIG="mtp,adb" ;;
	esac
	case "$USB_CONFIG_ADB_ONLY" in
	"" | *[!A-Za-z0-9,._+-]*) USB_CONFIG_ADB_ONLY="adb" ;;
	esac
	# `svc usb setFunctions` reads a single comma separated argument (AOSP
	# UsbCommand uses args[2] only), so this is exactly USB_CONFIG.
	USB_SVC_FUNCTIONS=$USB_CONFIG
}

# Parse the config as plain KEY=VALUE lines.  It is deliberately NOT sourced:
# a typo such as `USB_CONFIG=mtp;adb` would otherwise execute `adb` as root,
# and the config must never be able to run arbitrary shell code.
load_config() {
	if [ -f "$CONFIG_FILE" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			line=$(printf '%s' "$line" | tr -d '\r')
			case "$line" in
			'' | '#'*) continue ;;
			esac
			key=${line%%=*}
			[ "$key" = "$line" ] && continue
			key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
			value=${line#*=}
			value=$(printf '%s' "$value" | sed -e 's/[[:space:]]#.*$//' \
				-e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
			case "$value" in
			\"*\") value=${value#\"} value=${value%\"} ;;
			\'*\') value=${value#\'} value=${value%\'} ;;
			esac
			case "$key" in
			ENABLE_ADB | FORCE_INSECURE_ADB | USB_CONFIG | USB_CONFIG_ADB_ONLY | \
				FORCE_USB_REENUM | START_ADBD | SKIP_SETUP_WIZARD | PROVISION_EARLY | \
				DISABLE_SETUP_WIZARD_PACKAGES | MIUI_SECURITY_BYPASS | MIUI_FASTBOOT_BYPASS | \
				FORCE_DEBUGGABLE | WIRELESS_ADB | WIRELESS_PORT | WAKE_SCREEN | STAY_AWAKE | \
				DISMISS_KEYGUARD | BOOT_DELAY | BOOT_WAIT_SECONDS | RECHECK_SECONDS | \
				RECHECK_INTERVAL | SETTINGS_RETRIES | SETTINGS_RETRY_DELAY | \
				KEYS_KEEP_EXISTING | KEYS_FROM_STORAGE | KEYS_BACKUP | LOG_MAX_BYTES)
				export "$key=$value"
				;;
			*)
				log "config: ignoring unknown key '$key'"
				;;
			esac
		done <"$CONFIG_FILE"
	fi
	# Never let the editable config redirect module/system paths.
	reset_paths
	normalize_config
}

ensure_default_config() {
	if [ ! -f "$CONFIG_FILE" ]; then
		mkdir -p "$STATE_DIR" 2>/dev/null
		cat >"$CONFIG_FILE" <<'ADBEN_CONFIG_EOF'
# ==========================================================================
# ADB Enable configuration
# Values: 1 = on, 0 = off.  Edit from a root shell or from TWRP, e.g.
#   adb shell "su -c 'vi /data/adb/adb-enable/config'"
# Then apply without reboot:
#   adb shell "su -c '/data/adb/modules/adb_enable/bin/adb-enable run'"
# ==========================================================================

# Master switch: enable USB debugging on every boot.
ENABLE_ADB=1

# ro.adb.secure=0: on an unlocked bootloader adbd skips authorization
# completely, so no public key is needed.  This is what makes
# "flash the zip, reboot, adb devices" work.  Set to 0 to require keys.
FORCE_INSECURE_ADB=1

# USB gadget functions that must include "adb".
# Use "adb" alone to avoid exposing MTP to the host.
USB_CONFIG=mtp,adb
USB_CONFIG_ADB_ONLY=adb

# Re-enumerate the USB port when the adb function is not active.
FORCE_USB_REENUM=1

# Start adbd if the framework did not.
START_ADBD=1

# Mark the device as provisioned, so a freshly wiped phone skips the setup
# wizard and lands on the launcher (no touch needed).  These are persistent
# settings; see README section 11 for how to revert them.
SKIP_SETUP_WIZARD=1

# Do the provisioning before boot completes, ahead of Setup Wizard.  Set to 0
# to only write it after boot (safer if you do not need to skip the wizard).
PROVISION_EARLY=1

# Also run `pm disable-user` on the setup wizard packages (more aggressive).
DISABLE_SETUP_WIZARD_PACKAGES=0

# MIUI / HyperOS: enable "USB debugging (Security settings)" and
# "USB install" without a Mi account / SIM card.  Required for scrcpy
# input injection (mouse / keyboard control).
MIUI_SECURITY_BYPASS=1

# MIUI / HyperOS: enable "FASTBOOT flashing mode" without a Mi account.
# Security risk, off by default.
MIUI_FASTBOOT_BYPASS=0

# ro.debuggable=1 (enables `adb root` on some ROMs).  Off by default.
FORCE_DEBUGGABLE=0

# Wireless ADB is OFF by default.  When 0, the module deletes the
# service/persist tcp port properties at boot, before adbd starts, so a
# stale 5555 from a previous session cannot come back.  Set to 1 to listen
# on WIRELESS_PORT (same as `adb tcpip <port>`).
WIRELESS_ADB=0
WIRELESS_PORT=5555

# Screen handling for headless use (scrcpy needs a powered display).
WAKE_SCREEN=1
STAY_AWAKE=0
DISMISS_KEYGUARD=1

# Timing.
BOOT_DELAY=8
BOOT_WAIT_SECONDS=240
RECHECK_SECONDS=90
RECHECK_INTERVAL=15
SETTINGS_RETRIES=4
SETTINGS_RETRY_DELAY=2

# Key management.
#   Keeps every key already present in /data/misc/adb/adb_keys.
KEYS_KEEP_EXISTING=1
#   Opt-in: import /sdcard/adbkey.pub and /sdcard/adb-enable/keys/*.
#   WARNING: any app with storage write access could add a permanently trusted
#   key there.  Keep 0 unless you specifically need the /sdcard drop path.
KEYS_FROM_STORAGE=0
#   Keep a copy of the previous adb_keys as adb_keys.bak.
KEYS_BACKUP=1

LOG_MAX_BYTES=262144
ADBEN_CONFIG_EOF
		chmod 0600 "$CONFIG_FILE" 2>/dev/null
	fi
}

setup_runtime() {
	mkdir -p "$STATE_DIR" "$KEYS_DIR" "$LOG_DIR" 2>/dev/null
	load_config
	resolve_tools
}

# ------------------------------------------------------------- properties ---
prop_set() {
	name=$1
	value=$2
	case "$name" in
	ro.*)
		# Read-only properties can only be changed in memory.
		[ -n "$RESETPROP" ] && run_quiet "$RESETPROP" -n "$name" "$value"
		;;
	*)
		if [ "$PROP_STAGE" = early ]; then
			# post-fs-data: setprop would dead-lock the boot process.
			[ -n "$RESETPROP" ] && run_quiet "$RESETPROP" -n "$name" "$value"
		else
			[ -n "$SETPROP_CMD" ] && run_quiet "$SETPROP_CMD" "$name" "$value"
			# resetprop afterwards guarantees the in-memory value even if
			# property_service refused the write.  Values starting with "-"
			# (only service.adb.tcp.port -1) are left to setprop: resetprop's
			# option parser would treat them as flags.
			case "$value" in
			-*) ;;
			*) [ -n "$RESETPROP" ] && run_quiet "$RESETPROP" -n "$name" "$value" ;;
			esac
		fi
		;;
	esac
	return 0
}

apply_props() {
	[ "$ENABLE_ADB" = 1 ] || return 0

	# Older Android / vendor adbd switches, harmless on newer releases and
	# required by some vendor adbd implementations.
	prop_set persist.service.adb.enable 1
	prop_set persist.sys.usb.config "$USB_CONFIG"

	if [ "$FORCE_INSECURE_ADB" = 1 ]; then
		prop_set ro.adb.secure 0
	fi

	if [ "$FORCE_DEBUGGABLE" = 1 ]; then
		prop_set ro.debuggable 1
		prop_set persist.service.debuggable 1
	fi

	if [ "$MIUI_SECURITY_BYPASS" = 1 ]; then
		prop_set persist.security.adbinput 1
		prop_set persist.security.adbinstall 1
	fi

	if [ "$MIUI_FASTBOOT_BYPASS" = 1 ]; then
		prop_set persist.fastboot.enable 1
	fi
}

# ------------------------------------------------------------------ keys ----
# Only NEW sources are validated.  Keys that are already in the trust store
# are preserved verbatim (CR stripped, blank lines dropped), so an unknown
# key type can never be dropped by an update.
filter_keys() {
	sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' 2>/dev/null |
		grep -v '^#' 2>/dev/null |
		grep -v '^$' 2>/dev/null |
		grep -E '^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+)[[:space:]]+[A-Za-z0-9+/=]{20,}([[:space:]].*)?$|^[A-Za-z0-9+/=]{60,}([[:space:]].*)?$' 2>/dev/null |
		LC_ALL=C sort -u 2>/dev/null
}

count_keys() {
	grep -c . "$1" 2>/dev/null | tr -d ' '
}

# Existing trust store -> normalised, deduplicated lines.  Nothing is filtered
# out here: whatever the device already trusted stays trusted.
normalize_keep() {
	sed 's/\r$//' "$1" 2>/dev/null |
		grep -v '^[[:space:]]*$' 2>/dev/null |
		LC_ALL=C sort -u 2>/dev/null
}

MAX_KEY_BYTES=16384
MAX_KEY_TOTAL=65536

# Collect every key source into the temp file passed as $1.
# Second argument "early" skips CE storage (/sdcard is locked in post-fs-data).
collect_keys() {
	out=$1
	mode=$2
	KEY_SRC_COUNT=0
	KEY_TOTAL_BYTES=0

	add_key_file() {
		# Regular, non-symlink, reasonably sized files only.  This prevents a
		# shared-storage file (or a symlink to /dev/urandom) from filling /data
		# or blocking post-fs-data.
		[ -f "$1" ] || return 1
		[ -L "$1" ] && {
			log "keys: skip symlink $1"
			return 1
		}
		case "${1##*/}" in
		README* | readme* | .*)
			log "keys: ignore documentation/hidden file $1"
			return 1
			;;
		esac
		size=$(stat -c %s "$1" 2>/dev/null)
		case "$size" in
		"" | *[!0-9]*) size=$(wc -c <"$1" 2>/dev/null | tr -d ' ') ;;
		esac
		case "$size" in
		"" | *[!0-9]*)
			log "keys: skip unreadable $1"
			return 1
			;;
		esac
		if [ "$size" -gt "$MAX_KEY_BYTES" ]; then
			log "keys: skip oversized $1 ($size bytes)"
			return 1
		fi
		if [ $((KEY_TOTAL_BYTES + size)) -gt "$MAX_KEY_TOTAL" ]; then
			log "keys: total intake limit reached, skipping $1"
			return 1
		fi
		KEY_TOTAL_BYTES=$((KEY_TOTAL_BYTES + size))
		head -c "$MAX_KEY_BYTES" "$1" >>"$out" 2>/dev/null || return 1
		# A key file is not guaranteed to end with a newline (adb does not
		# write one); without this the next key would be glued to this line
		# and both would become invalid.
		echo >>"$out" 2>/dev/null
		log "keys: read $1"
		KEY_SRC_COUNT=$((KEY_SRC_COUNT + 1))
		return 0
	}

	# 1. explicit key store managed by the user / by `adb-enable addkey`
	for f in "$KEYS_DIR"/*; do
		[ -f "$f" ] && add_key_file "$f"
	done
	[ -f "$STATE_DIR/adb_keys" ] && add_key_file "$STATE_DIR/adb_keys"

	# 2. keys shipped inside the module zip
	for f in "$MODDIR"/keys/*; do
		[ -f "$f" ] && add_key_file "$f"
	done

	# 3. convenient drop locations for recovery / adb push
	for f in /data/local/tmp/adbkey.pub /data/local/tmp/adb_keys; do
		[ -f "$f" ] && add_key_file "$f"
	done

	# 4. internal storage: OPT-IN only.  /sdcard is writable by any app with
	#    storage access, and anything imported here becomes permanently
	#    trusted, so this is off by default.
	if [ "$KEYS_FROM_STORAGE" = 1 ] && [ "$mode" != early ]; then
		for base in /sdcard /data/media/0; do
			[ -d "$base" ] || continue
			for f in "$base/adbkey.pub" "$base/adb_keys" "$base/adb-enable/adb_keys"; do
				[ -f "$f" ] && add_key_file "$f"
			done
			for f in "$base"/adb-enable/keys/*; do
				[ -f "$f" ] && add_key_file "$f"
			done
		done
	fi
	return 0
}

sync_keys() {
	mode=${1:-late}
	[ "$ENABLE_ADB" = 1 ] || return 0

	# Create the directory only when it is missing.  If init already created
	# it, leave its mode/owner/label exactly as the ROM set it.
	if [ ! -d "$ADB_MISC_DIR" ]; then
		if ! mkdir -p "$ADB_MISC_DIR" 2>/dev/null; then
			log "keys: cannot create $ADB_MISC_DIR"
			return 1
		fi
		chown 1000:2000 "$ADB_MISC_DIR" 2>/dev/null \
			|| log "keys: WARNING cannot chown $ADB_MISC_DIR"
		chmod 02750 "$ADB_MISC_DIR" 2>/dev/null \
			|| log "keys: WARNING cannot chmod $ADB_MISC_DIR"
		chcon u:object_r:adb_data_file:s0 "$ADB_MISC_DIR" 2>/dev/null \
			|| log "keys: WARNING cannot chcon $ADB_MISC_DIR"
		log "keys: created $ADB_MISC_DIR"
	fi

	keep="$ADB_MISC_DIR/.adb_keys.keep.$$"
	src="$ADB_MISC_DIR/.adb_keys.src.$$"
	new="$ADB_MISC_DIR/.adb_keys.new.$$"
	merged="$ADB_MISC_DIR/.adb_keys.merged.$$"
	if ! touch "$keep" "$src" 2>/dev/null; then
		log "keys: cannot create temp files in $ADB_MISC_DIR"
		rm -f "$keep" "$src" "$new"
		return 1
	fi

	existing_n=0
	if [ "$KEYS_KEEP_EXISTING" = 1 ] && [ -f "$ADB_KEYS_FILE" ]; then
		if normalize_keep "$ADB_KEYS_FILE" >"$keep" 2>/dev/null; then
			existing_n=$(grep -c . "$keep" 2>/dev/null | tr -d ' ')
			[ -n "$existing_n" ] || existing_n=0
			log "keys: kept existing $ADB_KEYS_FILE ($existing_n unique)"
		else
			log "keys: WARNING cannot read existing $ADB_KEYS_FILE"
		fi
		# A non-empty store that normalised to zero lines means the read
		# failed.  Never continue: the next step would replace it with a
		# smaller file.
		if [ -s "$ADB_KEYS_FILE" ] && [ "$existing_n" -eq 0 ]; then
			log "keys: existing store unreadable, $ADB_KEYS_FILE left untouched"
			rm -f "$keep" "$src" "$new" "$merged"
			return 1
		fi
	fi

	collect_keys "$src" "$mode"
	rm -f "$new" 2>/dev/null
	if ! filter_keys <"$src" >"$new" 2>/dev/null; then
		log "keys: filter failed, $ADB_KEYS_FILE left untouched"
		rm -f "$keep" "$src" "$new" "$merged"
		return 1
	fi
	rm -f "$src" 2>/dev/null

	# Merge the verbatim existing lines with the validated new ones.
	if [ -s "$keep" ]; then
		if LC_ALL=C sort -u "$keep" "$new" >"$merged" 2>/dev/null; then
			mv -f "$merged" "$new" 2>/dev/null || {
				log "keys: cannot prepare merged store"
				rm -f "$keep" "$new" "$merged"
				return 1
			}
		else
			log "keys: merge failed, $ADB_KEYS_FILE left untouched"
			rm -f "$keep" "$new" "$merged"
			return 1
		fi
	fi
	rm -f "$keep" 2>/dev/null

	if [ ! -s "$new" ]; then
		log "keys: no valid key found, $ADB_KEYS_FILE left untouched"
		rm -f "$new" 2>/dev/null
		return 0
	fi

	# Hard safety net: never shrink the trust store.
	new_n=$(count_keys "$new")
	[ -n "$new_n" ] || new_n=0
	if [ "$KEYS_KEEP_EXISTING" = 1 ] && [ "$new_n" -lt "$existing_n" ]; then
		log "keys: refusing to shrink trust store ($existing_n -> $new_n)"
		rm -f "$new" 2>/dev/null
		return 1
	fi

	if [ -f "$ADB_KEYS_FILE" ] && have cmp && cmp -s "$new" "$ADB_KEYS_FILE"; then
		log "keys: unchanged ($(count_keys "$ADB_KEYS_FILE") key(s))"
		rm -f "$new" 2>/dev/null
		return 0
	fi

	# A backup is part of the write contract: if it cannot be written, do not
	# touch the live store.
	if [ "$KEYS_BACKUP" = 1 ] && [ -f "$ADB_KEYS_FILE" ]; then
		if ! cp -f "$ADB_KEYS_FILE" "$ADB_KEYS_FILE.bak" 2>/dev/null; then
			log "keys: backup failed, $ADB_KEYS_FILE left untouched"
			rm -f "$new" 2>/dev/null
			return 1
		fi
	fi

	# adbd expects system:shell 0640 with the adb_keys_file label.  Apply the
	# attributes to the temp inode, verify them, then rename atomically.
	if ! chown 1000:2000 "$new" 2>/dev/null; then
		log "keys: chown failed, $ADB_KEYS_FILE left untouched"
		rm -f "$new" 2>/dev/null
		return 1
	fi
	if ! chmod 0640 "$new" 2>/dev/null; then
		log "keys: chmod failed, $ADB_KEYS_FILE left untouched"
		rm -f "$new" 2>/dev/null
		return 1
	fi
	if ! chcon u:object_r:adb_keys_file:s0 "$new" 2>/dev/null; then
		have restorecon && restorecon -F "$new" 2>/dev/null
		case "$(ls -lZ "$new" 2>/dev/null)" in
		*adb_keys_file*) ;;
		*)
			log "keys: chcon failed, $ADB_KEYS_FILE left untouched"
			rm -f "$new" 2>/dev/null
			return 1
			;;
		esac
	fi

	if ! mv -f "$new" "$ADB_KEYS_FILE" 2>/dev/null; then
		log "keys: failed to install $ADB_KEYS_FILE"
		rm -f "$new" 2>/dev/null
		return 1
	fi

	log "keys: installed $(count_keys "$ADB_KEYS_FILE") key(s) from $KEY_SRC_COUNT source(s)"
	log "keys: $(ls -lZ "$ADB_KEYS_FILE" 2>/dev/null | tr -s ' ')"
	return 0
}

# ---------------------------------------------------------------- settings --
settings_value() {
	[ -n "$SETTINGS_CMD" ] || return 0
	bcmd "$SETTINGS_CMD" get "$1" "$2"
	printf '%s' "$BCMD_OUT"
}

settings_put() {
	ns=$1
	key=$2
	want=$3
	i=0
	while [ "$i" -lt "$SETTINGS_RETRIES" ]; do
		if [ -n "$SETTINGS_CMD" ]; then
			bcmd "$SETTINGS_CMD" put "$ns" "$key" "$want"
			cur=$(settings_value "$ns" "$key")
			if [ "$cur" = "$want" ]; then
				log "settings: $ns/$key=$want OK"
				return 0
			fi
			bcmd "$SETTINGS_CMD" --user 0 put "$ns" "$key" "$want"
			cur=$(settings_value "$ns" "$key")
			if [ "$cur" = "$want" ]; then
				log "settings: $ns/$key=$want OK (user 0)"
				return 0
			fi
			log "settings: retry $ns/$key (current='$cur')"
		fi
		i=$((i + 1))
		sleep "$SETTINGS_RETRY_DELAY"
	done
	log "settings: FAILED $ns/$key=$want"
	return 1
}

disable_setup_packages() {
	[ -n "$PM_CMD" ] || return 0
	for pkg in com.google.android.setupwizard com.miui.provision; do
		bcmd "$PM_CMD" disable-user --user 0 "$pkg"
	done
}

apply_settings() {
	[ "$ENABLE_ADB" = 1 ] || return 0

	if [ "$SKIP_SETUP_WIZARD" = 1 ]; then
		settings_put global device_provisioned 1
		settings_put secure user_setup_complete 1
		settings_put global setup_wizard_has_run 1
		[ "$DISABLE_SETUP_WIZARD_PACKAGES" = 1 ] && disable_setup_packages
	fi

	# The real "USB debugging" switch.  While this stays 0, AdbService
	# stops adbd again no matter what sys.usb.config says.
	settings_put global development_settings_enabled 1
	settings_put global adb_enabled 1
}

# -------------------------------------------------------------------- usb ---
usb_has_adb() {
	state=$(prop_get sys.usb.state)
	case "$state" in *adb*) return 0 ;; esac
	# some ROMs do not expose sys.usb.state
	if [ -z "$state" ]; then
		case "$(prop_get sys.usb.config)" in *adb*) return 0 ;; esac
	fi
	return 1
}

fix_usb() {
	[ "$ENABLE_ADB" = 1 ] || return 0
	[ "$FORCE_USB_REENUM" = 1 ] || return 0

	if usb_has_adb && [ "$(prop_get sys.usb.ffs.ready)" != 0 ]; then
		log "usb: adb function already active (config=$(prop_get sys.usb.config) state=$(prop_get sys.usb.state))"
		return 0
	fi
	if usb_has_adb; then
		log "usb: adb configured but sys.usb.ffs.ready=0, re-enumerating"
	fi

	# Preferred: the framework API (Android 11+), same path as the UI.
	# `svc usb setFunctions` only reads the single argument args[2].
	if [ -n "$SVC_CMD" ]; then
		bcmd "$SVC_CMD" usb setFunctions "$USB_SVC_FUNCTIONS"
		sleep 2
		if usb_has_adb; then
			log "usb: svc usb setFunctions $USB_SVC_FUNCTIONS worked"
			return 0
		fi
		bcmd "$SVC_CMD" usb setFunctions adb
		sleep 2
		if usb_has_adb; then
			log "usb: svc usb setFunctions adb worked"
			return 0
		fi
	fi

	# Fallback: toggle the gadget through init properties (proven path).
	if [ -z "$SETPROP_CMD" ]; then
		log "usb: setprop not available, skipping re-enumeration"
		return 0
	fi
	prev_usb=$(prop_get sys.usb.config)
	run_quiet "$SETPROP_CMD" sys.usb.config none
	sleep 1
	if ! run_quiet "$SETPROP_CMD" sys.usb.config "$USB_CONFIG"; then
		log "usb: restore to '$USB_CONFIG' failed, putting back '${prev_usb:-none}'"
		run_quiet "$SETPROP_CMD" sys.usb.config "${prev_usb:-$USB_CONFIG}"
	fi
	sleep 2
	if ! usb_has_adb; then
		run_quiet "$SETPROP_CMD" sys.usb.config "$USB_CONFIG_ADB_ONLY"
		sleep 2
		if ! usb_has_adb; then
			log "usb: fallback failed, putting back '${prev_usb:-none}'"
			run_quiet "$SETPROP_CMD" sys.usb.config "${prev_usb:-$USB_CONFIG}"
		fi
	fi

	if usb_has_adb; then
		log "usb: adb function active (state=$(prop_get sys.usb.state))"
	else
		log "usb: WARNING adb not active (config=$(prop_get sys.usb.config) state=$(prop_get sys.usb.state) ffs=$(prop_get sys.usb.ffs.ready))"
	fi
	return 0
}

ensure_adbd() {
	[ "$ENABLE_ADB" = 1 ] || return 0
	[ "$START_ADBD" = 1 ] || return 0
	[ -n "$SETPROP_CMD" ] || {
		log "adbd: setprop not available"
		return 0
	}
	svc_state=$(prop_get init.svc.adbd)
	if [ "$svc_state" != running ]; then
		log "adbd: '$svc_state', starting"
		run_quiet "$SETPROP_CMD" ctl.start adbd
		sleep 2
		svc_state=$(prop_get init.svc.adbd)
		log "adbd: now '$svc_state'"
		if [ "$svc_state" = running ]; then
			# This start happened after ro.adb.secure=0, so adbd has
			# already read the right value; do not restart it.
			rm -f "$ADBD_PREEXISTING_FLAG" 2>/dev/null
		fi
	else
		log "adbd: already running"
	fi
	return 0
}

# adbd reads ro.adb.secure once at startup.  On an unlocked bootloader
# (ro.boot.verifiedbootstate=orange) the value 0 disables authorization
# completely, which is what makes a key-less "flash and reboot" work.
#
# Restart only when adbd was already running *before* post-fs-data set the
# property.  In the normal boot order adbd starts afterwards and has already
# read 0; restarting it then would disconnect a working adb/scrcpy session.
refresh_adbd_auth() {
	[ "$FORCE_INSECURE_ADB" = 1 ] || return 0
	[ "$START_ADBD" = 1 ] || return 0
	[ -n "$SETPROP_CMD" ] || return 0
	[ "$(prop_get init.svc.adbd)" = running ] || return 0

	if [ "$(prop_get ro.adb.secure)" != 0 ]; then
		log "adbd: ro.adb.secure='$(prop_get ro.adb.secure)', not restarting"
		rm -f "$ADBD_PREEXISTING_FLAG" 2>/dev/null
		return 0
	fi
	flag=$(cat "$ADBD_PREEXISTING_FLAG" 2>/dev/null)
	if [ "$flag" != 1 ]; then
		log "adbd: started after ro.adb.secure=0, no restart needed"
		return 0
	fi
	log "adbd: restarting once (it was running before ro.adb.secure=0)"
	run_quiet "$SETPROP_CMD" ctl.restart adbd
	# Clear the flag even if the restart failed: a retry in the 90 s recheck
	# would disconnect the session again.  ensure_adbd() will start adbd
	# fresh (and it will read the current property) on the next pass.
	rm -f "$ADBD_PREEXISTING_FLAG" 2>/dev/null
	sleep 2
	log "adbd: now '$(prop_get init.svc.adbd)'"
	return 0
}

# -------------------------------------------------------------- wireless ----
# Wireless ADB is OFF by default: delete both port properties before adbd
# ever starts (post-fs-data), then keep them explicitly at -1 in the late
# stage.  resetprop -d is safe in post-fs-data; setprop is not.
clear_tcp_ports() {
	if [ -n "$RESETPROP" ]; then
		run_quiet "$RESETPROP" -d service.adb.tcp.port
		run_quiet "$RESETPROP" -p -d persist.adb.tcp.port
	fi
	if [ "$PROP_STAGE" != early ]; then
		[ -n "$SETPROP_CMD" ] && run_quiet "$SETPROP_CMD" service.adb.tcp.port -1
		[ -n "$SETPROP_CMD" ] && run_quiet "$SETPROP_CMD" persist.adb.tcp.port -1
	fi
}

apply_wireless() {
	if [ "$WIRELESS_ADB" = 1 ] && [ "$ENABLE_ADB" = 1 ]; then
		prop_set service.adb.tcp.port "$WIRELESS_PORT"
		prop_set persist.adb.tcp.port "$WIRELESS_PORT"
		if [ -n "$SETPROP_CMD" ]; then
			run_quiet "$SETPROP_CMD" ctl.restart adbd
			sleep 1
			if [ "$(prop_get init.svc.adbd)" != running ]; then
				run_quiet "$SETPROP_CMD" ctl.start adbd
			fi
		fi
		for ip in $([ -n "$IP_CMD" ] && "$IP_CMD" addr show 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2); do
			case "$ip" in 127.*) continue ;; esac
			log "wireless: adb connect $ip:$WIRELESS_PORT"
		done
		ip=$(prop_get dhcp.wlan0.ipaddress)
		[ -n "$ip" ] && log "wireless: adb connect $ip:$WIRELESS_PORT"
	else
		# Clear both: persist.adb.tcp.port survives reboots and uninstall,
		# so leaving it behind would keep adbd listening on TCP.
		restart_needed=0
		case "$(prop_get service.adb.tcp.port)" in
		'' | -1) ;;
		*) restart_needed=1 ;;
		esac
		case "$(prop_get persist.adb.tcp.port)" in
		'' | -1) ;;
		*) restart_needed=1 ;;
		esac
		clear_tcp_ports
		# A live adbd may still hold an old listener; restart it once.
		if [ "$restart_needed" = 1 ] && [ -n "$SETPROP_CMD" ] &&
			[ "$(prop_get init.svc.adbd)" = running ]; then
			run_quiet "$SETPROP_CMD" ctl.restart adbd
			log "wireless: off, adbd restarted to close the TCP port"
		fi
	fi
	return 0
}

# ----------------------------------------------------------------- screen ---
wake_device() {
	[ "$ENABLE_ADB" = 1 ] || return 0

	if [ "$WAKE_SCREEN" = 1 ] && [ -n "$INPUT_CMD" ]; then
		bcmd "$INPUT_CMD" keyevent 224
	fi
	if [ "$STAY_AWAKE" = 1 ]; then
		settings_put global stay_on_while_plugged_in 7
	fi
	if [ "$DISMISS_KEYGUARD" = 1 ] && [ -n "$WM_CMD" ]; then
		bcmd "$WM_CMD" dismiss-keyguard
	fi
	return 0
}

# ----------------------------------------------------------------- status ---
status_report() {
	keys_n=$(count_keys "$ADB_KEYS_FILE")
	[ -n "$keys_n" ] || keys_n=0
	log "status: adb_enabled=$(settings_value global adb_enabled) dev_options=$(settings_value global development_settings_enabled) provisioned=$(settings_value global device_provisioned) setup=$(settings_value secure user_setup_complete)"
	log "status: adbd=$(prop_get init.svc.adbd) usb_config=$(prop_get sys.usb.config) usb_state=$(prop_get sys.usb.state) ffs=$(prop_get sys.usb.ffs.ready) udc=$(cat /config/usb_gadget/g1/UDC 2>/dev/null)"
	log "status: adb_secure=$(prop_get ro.adb.secure) debuggable=$(prop_get ro.debuggable) miui_input=$(prop_get persist.security.adbinput) miui_install=$(prop_get persist.security.adbinstall) keys=$keys_n wireless=service:$(prop_get service.adb.tcp.port),persist:$(prop_get persist.adb.tcp.port)"
}

# One-line human readable summary for action.sh / interactive use.
status_brief() {
	keys_n=$(count_keys "$ADB_KEYS_FILE")
	[ -n "$keys_n" ] || keys_n=0
	printf 'adb_enabled=%s dev_options=%s adbd=%s usb=%s ffs=%s keys=%s wireless=%s/%s\n' \
		"$(settings_value global adb_enabled)" \
		"$(settings_value global development_settings_enabled)" \
		"$(prop_get init.svc.adbd)" \
		"$(prop_get sys.usb.state)" \
		"$(prop_get sys.usb.ffs.ready)" \
		"$keys_n" \
		"$(prop_get service.adb.tcp.port)" \
		"$(prop_get persist.adb.tcp.port)"
}

# ------------------------------------------------------------- main flows ---
apply_all() {
	apply_props
	sync_keys late
	apply_settings
	fix_usb
	ensure_adbd
	apply_wireless
	wake_device
	status_report
}

# Try to mark the device provisioned BEFORE the setup wizard starts, so a
# freshly wiped phone boots straight to the launcher.  SettingsProvider is
# usually up a few seconds after late_start, hence the retry loop.
provision_early() {
	[ "$ENABLE_ADB" = 1 ] || return 0
	[ "$SKIP_SETUP_WIZARD" = 1 ] || return 0
	[ "$PROVISION_EARLY" = 1 ] || return 0
	[ "$(prop_get sys.boot_completed)" = 1 ] && return 0
	[ -n "$SETTINGS_CMD" ] || return 0
	i=0
	while [ "$i" -lt 8 ]; do
		bcmd "$SETTINGS_CMD" put global device_provisioned 1
		bcmd "$SETTINGS_CMD" put secure user_setup_complete 1
		bcmd "$SETTINGS_CMD" put global setup_wizard_has_run 1
		if [ "$(settings_value global device_provisioned)" = 1 ]; then
			log "setup wizard: provisioned early (attempt $((i + 1)))"
			return 0
		fi
		i=$((i + 1))
		sleep 2
	done
	log "setup wizard: early provisioning failed, retry after boot"
	return 1
}

wait_boot() {
	waited=0
	while [ "$(prop_get sys.boot_completed)" != 1 ]; do
		if [ "$waited" -ge "$BOOT_WAIT_SECONDS" ]; then
			log "boot: not completed after ${waited}s, continuing anyway"
			return 1
		fi
		sleep 2
		waited=$((waited + 2))
	done
	log "boot: completed after ${waited}s"
	return 0
}

main_post_fs_data() {
	STAGE=post-fs-data
	PROP_STAGE=early
	setup_runtime
	rotate_log
	log "===== ADB Enable $(module_version) post-fs-data ====="
	# A flag from a previous boot must never trigger a restart in this boot.
	rm -f "$ADBD_PREEXISTING_FLAG" 2>/dev/null
	ro_secure_before=$(prop_get ro.adb.secure)
	adbd_preexisting=0
	# If the ROM already had ro.adb.secure=0, even a pre-existing adbd read
	# 0 and does not need a restart.  Otherwise a running adbd may have read
	# 1 before this script changed it.
	[ "$(prop_get init.svc.adbd)" = running ] && [ "$ro_secure_before" != 0 ] && adbd_preexisting=1
	# Keys first: nothing may start adbd before the trust store is in place.
	sync_keys early
	# Wireless ADB is off by default; remove any stale 5555 before adbd runs.
	[ "$WIRELESS_ADB" = 1 ] || clear_tcp_ports
	apply_props
	# If adbd appeared while we were setting up, it may have read the old
	# ro.adb.secure=1.  Record that so the service stage can refresh it
	# once; otherwise it already read 0 and must not be restarted.
	[ "$(prop_get init.svc.adbd)" = running ] && [ "$ro_secure_before" != 0 ] && adbd_preexisting=1
	if [ "$adbd_preexisting" = 1 ]; then
		if printf '1\n' >"$ADBD_PREEXISTING_FLAG" 2>/dev/null; then
			log "adbd: running before ro.adb.secure=0, auth refresh scheduled"
		else
			log "adbd: cannot write $ADBD_PREEXISTING_FLAG, no restart will be attempted"
		fi
	else
		printf '0\n' >"$ADBD_PREEXISTING_FLAG" 2>/dev/null
		if [ "$(prop_get init.svc.adbd)" = running ]; then
			log "adbd: already running with ro.adb.secure=0, no refresh needed"
		else
			log "adbd: not running yet, it will read ro.adb.secure=0 on start"
		fi
	fi
	log "post-fs-data done"
}

main_service() {
	STAGE=service
	PROP_STAGE=late
	setup_runtime
	ensure_default_config
	load_config
	rotate_log
	log "===== ADB Enable $(module_version) service ====="
	log "device=$(prop_get ro.product.device) sdk=$(prop_get ro.build.version.sdk) resetprop=${RESETPROP:-none}"

	provision_early
	wait_boot
	[ "$BOOT_DELAY" -gt 0 ] 2>/dev/null && sleep "$BOOT_DELAY"

	if [ "$ENABLE_ADB" != 1 ]; then
		log "ENABLE_ADB=0, service does nothing"
		clear_tcp_ports
		return 0
	fi

	apply_all
	refresh_adbd_auth

	end=$(( $(date +%s) + RECHECK_SECONDS ))
	while [ "$(date +%s)" -lt "$end" ]; do
		sleep "$RECHECK_INTERVAL"
		cur=$(settings_value global adb_enabled)
		adbd=$(prop_get init.svc.adbd)
		case "$cur" in
		0 | null | "")
			log "recheck: adb_enabled='$cur', re-applying"
			apply_all
			;;
		*)
			if [ "$adbd" != running ]; then
				log "recheck: adbd='$adbd', re-applying"
				apply_all
			fi
			;;
		esac
	done
	log "service done"
}

main_action() {
	STAGE=action
	PROP_STAGE=late
	setup_runtime
	ensure_default_config
	load_config
	log "===== ADB Enable $(module_version) action ====="
	if [ "$(prop_get sys.boot_completed)" != 1 ]; then
		log "boot not completed yet"
		printf 'boot not completed yet, try again in a minute\n'
		return 1
	fi
	printf 'applying ADB Enable...\n'
	apply_all
	status_brief
	printf 'log: %s\n' "$LOG_FILE"
	log "action done (log: $LOG_FILE)"
}
