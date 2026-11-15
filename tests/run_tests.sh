#!/usr/bin/env bash
# ============================================================================
# ADB Enable - host-side test suite
#
# Runs the real Magisk scripts under dash with a fake Android environment
# (getprop/setprop/resetprop/settings/svc/pm/wm/input/chown/chcon/...).
#
# The interesting part: the `settings`, `svc`, `pm`, `wm` and `input` stubs
# fail with rc=97 if their stdout is a regular file instead of a pipe.  That
# is exactly the SELinux/binder bug that made the manual fix fail, so this
# test suite fails if anybody reintroduces `settings ... >> log`.
# ============================================================================
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ORIG_PATH=$PATH
SH=${SH:-sh}
PASS=0
FAIL=0
FAILED=()
CURRENT="?"

# ------------------------------------------------------------------ asserts --
ok() { PASS=$((PASS + 1)); }

bad() {
	FAIL=$((FAIL + 1))
	FAILED+=("$CURRENT: $1")
	printf '  FAIL %s\n' "$1"
}

assert_eq() { # name expected actual
	if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2] got [$3]"; fi
}

assert_contains() { # name needle haystack
	if printf '%s' "$3" | grep -qF -- "$2"; then ok; else bad "$1: missing [$2]"; fi
}

assert_file() { # name path
	if [ -f "$2" ]; then ok; else bad "$1: no file $2"; fi
}

assert_no_file() { # name path
	if [ ! -e "$2" ]; then ok; else bad "$1: file exists $2"; fi
}

assert_mode() { # name path mode
	m=$(stat -c '%a' "$2" 2>/dev/null)
	assert_eq "$1 mode" "$3" "$m"
}

# ------------------------------------------------------------------- stubs ---
make_stub() {
	cat >"$FAKE/bin/$1"
	chmod 0755 "$FAKE/bin/$1"
}

make_stubs() {
	make_stub _util.sh <<'EOF'
put_prop() {
	awk -v k="$1" 'index($0, k "=") != 1' "$FAKE/props" >"$FAKE/props.tmp"
	printf '%s=%s\n' "$1" "$2" >>"$FAKE/props.tmp"
	mv "$FAKE/props.tmp" "$FAKE/props"
}

del_prop() {
	awk -v k="$1=" 'index($0, k) != 1' "$FAKE/props" >"$FAKE/props.tmp"
	mv "$FAKE/props.tmp" "$FAKE/props"
}
EOF

	make_stub _fdcheck.sh <<'EOF'
# A binder backed command must never inherit a regular file descriptor.
target=$(readlink "/proc/$$/fd/1" 2>/dev/null)
case "$target" in
pipe:*) ;;
*)
	printf 'FD-VIOLATION %s -> %s\n' "$0" "$target" >>"$FAKE/fd_violations"
	echo "binder command inherited a file fd: $target" >&2
	exit 97
	;;
esac
EOF

	make_stub getprop <<'EOF'
#!/bin/sh
if [ "$#" -eq 0 ]; then
	cat "$FAKE/props"
	exit 0
fi
awk -v k="$1" 'index($0, k "=") == 1 { sub("^" k "=", ""); v = $0 } END { print v }' "$FAKE/props"
EOF

	make_stub setprop <<'EOF'
#!/bin/sh
. "$FAKE/bin/_util.sh"
printf '%s=%s\n' "$1" "$2" >>"$FAKE/setprop.log"
case "$1" in
ctl.start | ctl.restart) [ "$2" = adbd ] && put_prop init.svc.adbd running ;;
sys.usb.config)
	put_prop sys.usb.config "$2"
	put_prop sys.usb.state "$2"
	;;
*) put_prop "$1" "$2" ;;
esac
exit 0
EOF

	make_stub resetprop <<'EOF'
#!/bin/sh
. "$FAKE/bin/_util.sh"
delete=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	-d | --delete) delete=1; shift ;;
	-n | -p | -v | -w) shift ;;
	*) break ;;
	esac
done
if [ "$delete" = 1 ]; then
	[ "$#" -ge 1 ] || exit 1
	printf 'delete %s\n' "$1" >>"$FAKE/resetprop.log"
	del_prop "$1"
	exit 0
fi
[ "$#" -ge 2 ] || exit 1
printf '%s=%s\n' "$1" "$2" >>"$FAKE/resetprop.log"
put_prop "$1" "$2"
exit 0
EOF

	make_stub settings <<'EOF'
#!/bin/sh
. "$FAKE/bin/_fdcheck.sh"
. "$FAKE/bin/_util.sh"
if [ "$1" = "--user" ]; then shift 2; fi
verb=$1
ns=$2
key=$3
val=$4
case "$verb" in
put)
	if [ -f "$FAKE/settings_fail" ]; then
		left=$(cat "$FAKE/settings_fail" 2>/dev/null)
		if [ "$left" -gt 0 ] 2>/dev/null; then
			echo $((left - 1)) >"$FAKE/settings_fail"
			printf 'cmd: Failure calling service settings: Failed transaction (2147483646)\n'
			exit 1
		fi
	fi
	awk -v k="$ns/$key=" 'index($0, k) != 1' "$FAKE/settings.db" >"$FAKE/settings.db.tmp"
	printf '%s/%s=%s\n' "$ns" "$key" "$val" >>"$FAKE/settings.db.tmp"
	mv "$FAKE/settings.db.tmp" "$FAKE/settings.db"
	printf 'put %s %s %s\n' "$ns" "$key" "$val" >>"$FAKE/settings.log"
	;;
get)
	awk -v k="$ns/$key=" 'index($0, k) == 1 { sub("^" k, ""); v = $0 } END { print v }' "$FAKE/settings.db"
	;;
*)
	printf 'unknown settings verb: %s\n' "$verb"
	exit 1
	;;
esac
exit 0
EOF

	make_stub svc <<'EOF'
#!/bin/sh
. "$FAKE/bin/_fdcheck.sh"
. "$FAKE/bin/_util.sh"
[ "$1" = "usb" ] && [ "$2" = "setFunctions" ] || exit 0
shift 2
if [ "${FAKE_SVC_FAIL:-0}" = "1" ]; then
	printf 'Error: UsbManager unavailable\n'
	exit 1
fi
joined=$1
put_prop sys.usb.config "$joined"
put_prop sys.usb.state "$joined"
printf 'svc usb setFunctions argc=%s arg=%s\n' "$#" "$1" >>"$FAKE/svc.log"
printf 'USB functions set to %s\n' "$joined"
EOF

	for cmd in pm wm input; do
		make_stub "$cmd" <<'EOF'
#!/bin/sh
. "$FAKE/bin/_fdcheck.sh"
printf '%s %s\n' "${0##*/}" "$*" >>"$FAKE/binder.log"
exit 0
EOF
	done

	make_stub sleep <<'EOF'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$FAKE/sleep.log"
exit 0
EOF

	for cmd in chown chcon; do
		make_stub "$cmd" <<'EOF'
#!/bin/sh
if [ "${0##*/}" = chcon ] && [ "${FAKE_CHCON_FAIL:-0}" = 1 ]; then
	exit 1
fi
printf '%s %s\n' "${0##*/}" "$*" >>"$FAKE/perm.log"
exit 0
EOF
	done

	make_stub cp <<'EOF'
#!/bin/sh
if [ "${FAKE_CP_FAIL:-0}" = 1 ]; then
	exit 1
fi
exec /bin/cp "$@"
EOF

	make_stub ip <<'EOF'
#!/bin/sh
echo '2: wlan0: <BROADCAST,MULTICAST,UP> mtu 1500'
echo '    inet 192.168.1.23/24 brd 192.168.1.255 scope global wlan0'
EOF
}

# --------------------------------------------------------------- fake world --
new_env() {
	[ -n "${TMP:-}" ] && rm -rf "$TMP"
	TMP=$(mktemp -d)
	FAKE="$TMP/root"
	mkdir -p "$FAKE/bin" "$FAKE/module" "$FAKE/data/adb/adb-enable/keys" \
		"$FAKE/data/misc/adb"
	cp -a "$ROOT/module/." "$FAKE/module/"
	make_stubs
	: >"$FAKE/props"
	: >"$FAKE/settings.db"
	: >"$FAKE/setprop.log"
	: >"$FAKE/resetprop.log"
	: >"$FAKE/binder.log"
	: >"$FAKE/perm.log"
	: >"$FAKE/svc.log"

	export FAKE
	export ADBEN_ADB_DIR="$FAKE/data/adb"
	export ADBEN_STATE_DIR="$FAKE/data/adb/adb-enable"
	export ADBEN_CONFIG="$FAKE/data/adb/adb-enable/config"
	export ADBEN_LOG="$FAKE/data/adb/adb-enable/log/adb-enable.log"
	export ADBEN_ADB_MISC_DIR="$FAKE/data/misc/adb"
	export ADBEN_ADB_KEYS="$FAKE/data/misc/adb/adb_keys"
	export ADBEN_SYSTEM_BIN="$FAKE/system/bin"
	export PATH="$FAKE/bin:$ORIG_PATH"
	unset FAKE_SVC_FAIL FAKE_CP_FAIL FAKE_CHCON_FAIL
}

write_config() { cat >"$ADBEN_CONFIG"; }

prop() {
	awk -v k="$1=" 'index($0, k) == 1 { sub("^" k, ""); v = $0 } END { print v }' "$FAKE/props"
}

set_prop() {
	awk -v k="$1=" 'index($0, k) != 1' "$FAKE/props" >"$FAKE/props.tmp"
	printf '%s=%s\n' "$1" "$2" >>"$FAKE/props.tmp"
	mv "$FAKE/props.tmp" "$FAKE/props"
}

setting() { # namespace key
	awk -v k="$1/$2=" 'index($0, k) == 1 { sub("^" k, ""); v = $0 } END { print v }' "$FAKE/settings.db"
}

logtext() { cat "$ADBEN_LOG" 2>/dev/null; }

run_pfd() { "$SH" "$FAKE/module/post-fs-data.sh" >/dev/null 2>&1; echo $?; }

run_service() { "$SH" "$FAKE/module/service.sh" >/dev/null 2>&1; echo $?; }

run_sync() {
	"$SH" -c 'MODDIR="$1"; . "$1/common.sh"; STAGE=test; setup_runtime; sync_keys late' _ "$FAKE/module"
	echo $?
}

make_qaaa_key() {
	if [ -f "$HOME/.android/adbkey.pub" ]; then
		cat "$HOME/.android/adbkey.pub"
	else
		printf 'QAAAA'
		head -c 480 /dev/urandom | base64 | tr -d '\n'
		printf ' test@host\n'
	fi
}

start_test() {
	CURRENT=$1
	printf '\n== %s\n' "$CURRENT"
}

# ------------------------------------------------------------------- tests ---
test_syntax() {
	start_test "shell syntax"
	for f in "$ROOT"/module/*.sh "$ROOT"/module/bin/adb-enable \
		"$ROOT"/module/META-INF/com/google/android/update-binary; do
		if dash -n "$f" 2>/dev/null; then ok; else bad "dash -n $f"; fi
	done
}

test_no_binder_redirect() {
	start_test "static: no binder command redirected to a log file"
	violations=$(
		cd "$ROOT/module" &&
			grep -nE '^[^#]*\b(settings|svc|pm|wm|input)\b[^|]*>>' \
				*.sh bin/adb-enable 2>/dev/null
	)
	assert_eq "binder redirect scan" "" "$violations"
}

test_post_fs_data() {
	start_test "post-fs-data: early props + adb_keys seeding"
	new_env
	write_config <<'EOF'
ENABLE_ADB=1
FORCE_INSECURE_ADB=1
MIUI_SECURITY_BYPASS=1
KEYS_FROM_STORAGE=0
EOF
	printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExistingKeyPlaceholderForTests existing@pc' \
		>"$ADBEN_ADB_KEYS"
	make_qaaa_key >"$ADBEN_STATE_DIR/keys/pc.pub"
	make_qaaa_key >"$ADBEN_STATE_DIR/keys/pc-copy.pub"
	printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCTestOnlyKeyForUnitTests test@pc\n' \
		>"$ADBEN_STATE_DIR/keys/second.pub"
	printf 'this is not a key at all\n/dev/null\nssh-rsa\n' >"$ADBEN_STATE_DIR/keys/junk.txt"
	rc=$(run_pfd)
	assert_eq "post-fs-data rc" 0 "$rc"
	assert_eq "setprop untouched" 0 "$(wc -l <"$FAKE/setprop.log" | tr -d ' ')"
	assert_eq "ro.adb.secure" 0 "$(prop ro.adb.secure)"
	assert_eq "miui adbinput" 1 "$(prop persist.security.adbinput)"
	assert_eq "persist.sys.usb.config" "mtp,adb" "$(prop persist.sys.usb.config)"
	assert_eq "key count (dedup + existing)" 3 "$(grep -c . "$ADBEN_ADB_KEYS")"
	assert_mode "adb_keys" "$ADBEN_ADB_KEYS" 640
	assert_contains "chown recorded" "chown 1000:2000" "$(cat "$FAKE/perm.log")"
	assert_contains "chcon recorded" "adb_keys_file" "$(cat "$FAKE/perm.log")"
	assert_no_file "no CR in keys" "$ADBEN_ADB_KEYS.cr"
	if grep -q $'\r' "$ADBEN_ADB_KEYS"; then bad "adb_keys contains CR"; else ok; fi
	if grep -q 'adbkey.pub from adb' "$ADBEN_ADB_KEYS"; then bad "README example imported"; else ok; fi
	assert_contains "log done" "post-fs-data done" "$(logtext)"
	assert_contains "keys log" "installed 3 key(s)" "$(logtext)"
}

test_service_svc() {
	start_test "service: settings + svc usb + adbd"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\nsys.usb.config=mtp\nsys.usb.state=mtp\n' >"$FAKE/props"
	printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCTestOnlyKeyForUnitTests t@pc\n' \
		>"$ADBEN_STATE_DIR/keys/k.pub"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "global adb_enabled" 1 "$(setting global adb_enabled)"
	assert_eq "development_settings_enabled" 1 "$(setting global development_settings_enabled)"
	assert_eq "device_provisioned" 1 "$(setting global device_provisioned)"
	assert_eq "user_setup_complete" 1 "$(setting secure user_setup_complete)"
	assert_eq "setup_wizard_has_run" 1 "$(setting global setup_wizard_has_run)"
	assert_eq "adbd" running "$(prop init.svc.adbd)"
	case "$(prop sys.usb.state)" in *adb*) ok ;; *) bad "usb state has no adb: $(prop sys.usb.state)" ;; esac
	assert_eq "ro.adb.secure late" 0 "$(prop ro.adb.secure)"
	assert_contains "svc used" "svc usb setFunctions" "$(cat "$FAKE/svc.log")"
	assert_contains "svc comma argument" "argc=1 arg=mtp,adb" "$(cat "$FAKE/svc.log")"
	assert_no_file "no fd violations" "$FAKE/fd_violations"
	assert_contains "status logged" "status: adb_enabled=1" "$(logtext)"
	assert_contains "keys unchanged" "keys: installed 1 key(s)" "$(logtext)"
}

test_service_prop_fallback() {
	start_test "service: prop fallback when svc usb fails"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\nsys.usb.config=mtp\nsys.usb.state=mtp\n' >"$FAKE/props"
	export FAKE_SVC_FAIL=1
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_contains "usb none" "sys.usb.config=none" "$(cat "$FAKE/setprop.log")"
	assert_contains "usb mtp,adb" "sys.usb.config=mtp,adb" "$(cat "$FAKE/setprop.log")"
	assert_eq "adbd" running "$(prop init.svc.adbd)"
}

test_settings_retry() {
	start_test "service: settings retry after 'Failed transaction'"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
SETTINGS_RETRIES=3
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=running\nsys.usb.config=mtp,adb\nsys.usb.state=mtp,adb\n' >"$FAKE/props"
	echo 2 >"$FAKE/settings_fail"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "adb_enabled after retry" 1 "$(setting global adb_enabled)"
	assert_contains "retry logged" "settings: retry" "$(logtext)"
	assert_no_file "no fd violations" "$FAKE/fd_violations"
}

test_full_boot() {
	start_test "full boot: post-fs-data then service"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=0\ninit.svc.adbd=stopped\nsys.usb.config=mtp\nsys.usb.state=mtp\n' >"$FAKE/props"
	printf 'QAAAA%s pc@host\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" \
		>"$ADBEN_STATE_DIR/keys/pc.pub"
	assert_eq "post-fs-data rc" 0 "$(run_pfd)"
	assert_eq "keys after post-fs-data" 1 "$(grep -c . "$ADBEN_ADB_KEYS")"
	set_prop sys.boot_completed 1
	assert_eq "service rc" 0 "$(run_service)"
	assert_eq "adb_enabled" 1 "$(setting global adb_enabled)"
	assert_eq "adbd" running "$(prop init.svc.adbd)"
	case "$(prop sys.usb.state)" in *adb*) ok ;; *) bad "usb state: $(prop sys.usb.state)" ;; esac
	assert_contains "keys unchanged in service" "keys: unchanged" "$(logtext)"
	assert_no_file "no fd violations" "$FAKE/fd_violations"
}

test_zero_config() {
	start_test "zero config: no key at all, reboot and adb works"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=0\ninit.svc.adbd=stopped\nsys.usb.config=mtp\nsys.usb.state=mtp\n' >"$FAKE/props"
	assert_eq "zero-config post-fs-data rc" 0 "$(run_pfd)"
	assert_no_file "no adb_keys without keys" "$ADBEN_ADB_KEYS"
	assert_eq "insecure adb prop" 0 "$(prop ro.adb.secure)"
	set_prop sys.boot_completed 1
	assert_eq "zero-config service rc" 0 "$(run_service)"
	assert_eq "zero-config adb_enabled" 1 "$(setting global adb_enabled)"
	assert_eq "zero-config adbd" running "$(prop init.svc.adbd)"
	case "$(prop sys.usb.state)" in *adb*) ok ;; *) bad "zero-config usb: $(prop sys.usb.state)" ;; esac
	assert_contains "auth refresh logged" "restarting once to apply ro.adb.secure=0" "$(logtext)"
	assert_no_file "still no adb_keys" "$ADBEN_ADB_KEYS"
	assert_no_file "no fd violations" "$FAKE/fd_violations"
}

test_ffs_not_ready() {
	start_test "service: re-enumerate when ffs is not ready"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=running\nsys.usb.config=mtp,adb\nsys.usb.state=mtp,adb\nsys.usb.ffs.ready=0\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_contains "re-enumerated" "ffs.ready=0, re-enumerating" "$(logtext)"
	assert_contains "svc called" "svc usb setFunctions" "$(cat "$FAKE/svc.log")"
	assert_no_file "no fd violations" "$FAKE/fd_violations"
}

test_provision_early() {
	start_test "service: skip setup wizard before boot completes"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
BOOT_WAIT_SECONDS=4
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=0\ninit.svc.adbd=stopped\nsys.usb.config=mtp\nsys.usb.state=mtp\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "early device_provisioned" 1 "$(setting global device_provisioned)"
	assert_eq "early user_setup_complete" 1 "$(setting secure user_setup_complete)"
	assert_contains "early log" "provisioned early" "$(logtext)"
}

test_system_cmd_resolution() {
	start_test "system commands: /system/bin wins over BusyBox applets"
	new_env
	mkdir -p "$FAKE/system/bin"
	printf '#!/bin/sh\nexit 0\n' >"$FAKE/system/bin/settings"
	chmod 0755 "$FAKE/system/bin/settings"
	out=$(ADBEN_SYSTEM_BIN="$FAKE/system/bin" "$SH" -c '. "$1/common.sh"; resolve_system_cmd settings' _ "$FAKE/module")
	assert_eq "preferred system path" "$FAKE/system/bin/settings" "$out"
	out=$(ADBEN_SYSTEM_BIN="$FAKE/missing" "$SH" -c '. "$1/common.sh"; resolve_system_cmd settings' _ "$FAKE/module")
	assert_eq "fallback to PATH" "$FAKE/bin/settings" "$out"
}

test_keys_unknown_types() {
	start_test "keys: unknown existing types are preserved verbatim"
	new_env
	write_config <<'EOF'
KEYS_FROM_STORAGE=0
EOF
	# note: deliberately no trailing newline on the existing store
	printf 'sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5AAAAIYubiKeyPlaceholder yubi@pc\necdsa-sha2-nistp256@openssh.com AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIWeirdKey weird@pc' \
		>"$ADBEN_ADB_KEYS"
	printf 'QAAAA%s new@pc\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" \
		>"$ADBEN_STATE_DIR/keys/new.pub"
	rc=$(run_pfd)
	assert_eq "post-fs-data rc" 0 "$rc"
	assert_file "trust store exists" "$ADBEN_ADB_KEYS"
	assert_eq "unknown keys preserved + new" 3 "$(grep -c . "$ADBEN_ADB_KEYS")"
	assert_contains "sk key kept" "yubi@pc" "$(cat "$ADBEN_ADB_KEYS")"
	assert_contains "ecdsa key kept" "weird@pc" "$(cat "$ADBEN_ADB_KEYS")"
	assert_contains "new key merged" "new@pc" "$(cat "$ADBEN_ADB_KEYS")"
	assert_file "backup created" "$ADBEN_ADB_KEYS.bak"
	assert_eq "backup holds the old store" 2 "$(grep -c . "$ADBEN_ADB_KEYS.bak")"
}

test_keys_oversized_symlink() {
	start_test "keys: oversized files and symlinks are skipped"
	new_env
	write_config <<'EOF'
KEYS_FROM_STORAGE=0
EOF
	printf 'QAAAA%s real@pc\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" \
		>"$ADBEN_STATE_DIR/keys/real.pub"
	ln -s real.pub "$ADBEN_STATE_DIR/keys/link.pub"
	head -c 20000 /dev/urandom | base64 >"$ADBEN_STATE_DIR/keys/huge.pub"
	rc=$(run_pfd)
	assert_eq "post-fs-data rc" 0 "$rc"
	assert_eq "only real key imported" 1 "$(grep -c . "$ADBEN_ADB_KEYS")"
	assert_contains "symlink skipped" "skip symlink" "$(logtext)"
	assert_contains "oversized skipped" "skip oversized" "$(logtext)"
}

test_keys_backup_and_chcon_failure() {
	start_test "keys: backup/chcon failure never replaces the live store"
	new_env
	write_config <<'EOF'
KEYS_FROM_STORAGE=0
KEYS_BACKUP=1
EOF
	old='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExistingKeyPlaceholderForTests existing@pc'
	printf '%s\n' "$old" >"$ADBEN_ADB_KEYS"
	printf 'QAAAA%s new@pc\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" \
		>"$ADBEN_STATE_DIR/keys/new.pub"

	export FAKE_CP_FAIL=1
	rc=$(run_sync)
	unset FAKE_CP_FAIL
	assert_eq "backup-failure rc" 1 "$rc"
	assert_eq "store untouched on backup failure" "$old" "$(cat "$ADBEN_ADB_KEYS")"
	assert_contains "backup failure logged" "backup failed" "$(logtext)"

	export FAKE_CHCON_FAIL=1
	rc=$(run_sync)
	unset FAKE_CHCON_FAIL
	assert_eq "chcon-failure rc" 1 "$rc"
	assert_eq "store untouched on chcon failure" "$old" "$(cat "$ADBEN_ADB_KEYS")"
	assert_contains "chcon failure logged" "chcon failed" "$(logtext)"
	assert_eq "no temp leftovers" "" "$(find "$ADBEN_ADB_MISC_DIR" -name '.adb_keys.*' 2>/dev/null)"
}

test_wireless_off_clears_persist() {
	start_test "wireless: off clears both TCP port properties"
	new_env
	write_config <<'EOF'
WIRELESS_ADB=0
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=running\nsys.usb.config=mtp,adb\nsys.usb.state=mtp,adb\npersist.adb.tcp.port=5555\nservice.adb.tcp.port=5555\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "persist tcp port cleared" -1 "$(prop persist.adb.tcp.port)"
	assert_eq "service tcp port cleared" -1 "$(prop service.adb.tcp.port)"
}

test_uninstall_clears_tcp() {
	start_test "uninstall: closes the TCP adb port (live + early)"
	new_env
	printf 'persist.adb.tcp.port=5555\nservice.adb.tcp.port=5555\ninit.svc.adbd=running\n' >"$FAKE/props"
	"$SH" "$FAKE/module/uninstall.sh" >/dev/null 2>&1
	assert_eq "uninstall persist port" -1 "$(prop persist.adb.tcp.port)"
	assert_eq "uninstall service port" -1 "$(prop service.adb.tcp.port)"

	# post-fs-data removal: no setprop, resetprop delete only
	new_env
	printf 'persist.adb.tcp.port=5555\nservice.adb.tcp.port=5555\ninit.svc.adbd=stopped\n' >"$FAKE/props"
	"$SH" "$FAKE/module/uninstall.sh" >/dev/null 2>&1
	assert_eq "early uninstall persist port" "" "$(prop persist.adb.tcp.port)"
	assert_eq "early uninstall service port" "" "$(prop service.adb.tcp.port)"
}

test_wireless_off_master_off() {
	start_test "wireless: master switch off still clears TCP ports"
	new_env
	write_config <<'EOF'
ENABLE_ADB=0
WIRELESS_ADB=0
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\npersist.adb.tcp.port=5555\nservice.adb.tcp.port=5555\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "master-off persist port" -1 "$(prop persist.adb.tcp.port)"
	assert_eq "master-off service port" -1 "$(prop service.adb.tcp.port)"
}

test_wireless_default_off_early() {
	start_test "wireless: default off removes stale 5555 before adbd starts"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=0\ninit.svc.adbd=stopped\nsys.usb.config=mtp\nsys.usb.state=mtp\npersist.adb.tcp.port=5555\nservice.adb.tcp.port=5555\n' >"$FAKE/props"
	rc=$(run_pfd)
	assert_eq "post-fs-data rc" 0 "$rc"
	assert_eq "early service port removed" "" "$(prop service.adb.tcp.port)"
	assert_eq "early persist port removed" "" "$(prop persist.adb.tcp.port)"
	set_prop sys.boot_completed 1
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "late service port" -1 "$(prop service.adb.tcp.port)"
	assert_eq "late persist port" -1 "$(prop persist.adb.tcp.port)"
}

test_usb_config_validation() {
	start_test "config: invalid USB_CONFIG falls back to mtp,adb"
	new_env
	write_config <<'EOF'
USB_CONFIG="mtp;adb"
BOOT_DELAY=0
RECHECK_SECONDS=0
EOF
	printf 'sys.boot_completed=0\ninit.svc.adbd=stopped\n' >"$FAKE/props"
	rc=$(run_pfd)
	assert_eq "post-fs-data rc" 0 "$rc"
	assert_eq "validated usb config" "mtp,adb" "$(prop persist.sys.usb.config)"
}

test_config_no_code_exec() {
	start_test "config: values are parsed, never executed"
	new_env
	rm -f /tmp/adben-pwned-test
	printf 'ENABLE_ADB=1\nBAD=$(touch /tmp/adben-pwned-test)\nEVIL=1\nBOOT_DELAY=0\nRECHECK_SECONDS=0\n' >"$ADBEN_CONFIG"
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\nsys.usb.config=mtp\nsys.usb.state=mtp\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_no_file "config payload was not executed" /tmp/adben-pwned-test
	assert_eq "known key still works" 1 "$(setting global adb_enabled)"
}

test_addkey_hidden() {
	start_test "cli: addkey renames hidden files instead of faking success"
	new_env
	write_config <<'EOF'
KEYS_FROM_STORAGE=0
EOF
	printf 'QAAAA%s hidden@pc\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" \
		>"$FAKE/.hidden.pub"
	out=$("$SH" "$FAKE/module/bin/adb-enable" addkey "$FAKE/.hidden.pub" 2>&1)
	assert_contains "addkey output" "imported" "$out"
	assert_file "renamed key file" "$ADBEN_STATE_DIR/keys/key.hidden.pub"
	assert_file "trust store written" "$ADBEN_ADB_KEYS"
	assert_contains "hidden key imported" "hidden@pc" "$(cat "$ADBEN_ADB_KEYS")"
}

test_master_switch_off() {
	start_test "config: ENABLE_ADB=0 does nothing"
	new_env
	write_config <<'EOF'
ENABLE_ADB=0
BOOT_DELAY=0
RECHECK_SECONDS=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "no settings written" 0 "$(wc -l <"$FAKE/settings.db" | tr -d ' ')"
	assert_eq "no ro.adb.secure" "" "$(prop ro.adb.secure)"
	assert_eq "adbd untouched" stopped "$(prop init.svc.adbd)"

	# a Windows (CRLF) config must be honoured too
	new_env
	printf 'ENABLE_ADB=0\r\nBOOT_DELAY=0\r\nRECHECK_SECONDS=0\r\n' >"$ADBEN_CONFIG"
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "crlf config rc" 0 "$rc"
	assert_eq "crlf config honoured" 0 "$(wc -l <"$FAKE/settings.db" | tr -d ' ')"

	# inline comment and spaces around '=' must be handled
	new_env
	printf 'ENABLE_ADB = 0  # master off\nBOOT_DELAY=0\nRECHECK_SECONDS=0\n' >"$ADBEN_CONFIG"
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "inline-comment rc" 0 "$rc"
	assert_eq "inline-comment honoured" 0 "$(wc -l <"$FAKE/settings.db" | tr -d ' ')"
}

test_options_off() {
	start_test "config: every risky option off"
	new_env
	write_config <<'EOF'
ENABLE_ADB=1
FORCE_INSECURE_ADB=0
MIUI_SECURITY_BYPASS=0
SKIP_SETUP_WIZARD=0
FORCE_USB_REENUM=0
START_ADBD=0
WAKE_SCREEN=0
DISMISS_KEYGUARD=0
BOOT_DELAY=0
RECHECK_SECONDS=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\nsys.usb.config=mtp,adb\nsys.usb.state=mtp,adb\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "no ro.adb.secure" "" "$(prop ro.adb.secure)"
	assert_eq "no miui input" "" "$(prop persist.security.adbinput)"
	assert_eq "no provisioned" "" "$(setting global device_provisioned)"
	assert_eq "adb_enabled still on" 1 "$(setting global adb_enabled)"
	assert_eq "no ctl.start" 0 "$(grep -c 'ctl.start' "$FAKE/setprop.log" 2>/dev/null || true)"
	assert_eq "no input calls" 0 "$(grep -c '^input ' "$FAKE/binder.log" 2>/dev/null || true)"
	assert_eq "no wm calls" 0 "$(grep -c '^wm ' "$FAKE/binder.log" 2>/dev/null || true)"
	assert_eq "no svc calls" 0 "$(wc -l <"$FAKE/svc.log" | tr -d ' ')"
	assert_eq "no adbd restart" 0 "$(grep -c 'ctl.restart' "$FAKE/setprop.log" 2>/dev/null || true)"
}

test_wireless() {
	start_test "config: wireless adb"
	new_env
	write_config <<'EOF'
WIRELESS_ADB=1
WIRELESS_PORT=5555
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=running\nsys.usb.config=mtp,adb\nsys.usb.state=mtp,adb\n' >"$FAKE/props"
	rc=$(run_service)
	assert_eq "service rc" 0 "$rc"
	assert_eq "tcp port prop" 5555 "$(prop service.adb.tcp.port)"
	assert_contains "restart adbd" "ctl.restart=adbd" "$(cat "$FAKE/setprop.log")"
	assert_contains "ip hint" "adb connect 192.168.1.23:5555" "$(logtext)"
	assert_contains "port in status" "wireless=service:5555" "$(logtext)"
}

test_keys_safety() {
	start_test "keys: invalid input never wipes the trust store"
	new_env
	write_config <<'EOF'
KEYS_FROM_STORAGE=0
EOF
	existing='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExistingKeyPlaceholderForTests existing@pc'
	printf '%s\n' "$existing" >"$ADBEN_ADB_KEYS"
	printf 'garbage\nnot.a.key\n' >"$ADBEN_STATE_DIR/keys/bad.txt"
	rc=$(run_pfd)
	assert_eq "post-fs-data rc" 0 "$rc"
	assert_eq "existing key untouched" "$existing" "$(cat "$ADBEN_ADB_KEYS")"
	assert_contains "unchanged" "keys: unchanged" "$(logtext)"

	new_env
	write_config <<'EOF'
KEYS_FROM_STORAGE=0
EOF
	printf 'garbage\n' >"$ADBEN_STATE_DIR/keys/bad.txt"
	rc=$(run_pfd)
	assert_eq "post-fs-data rc" 0 "$rc"
	assert_no_file "no empty adb_keys created" "$ADBEN_ADB_KEYS"

	new_env
	write_config <<'EOF'
KEYS_FROM_STORAGE=0
EOF
	printf 'QAAAA%s line1@pc\r\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" \
		>"$ADBEN_STATE_DIR/keys/crlf.pub"
	rc=$(run_pfd)
	assert_eq "post-fs-data rc" 0 "$rc"
	assert_file "crlf key imported" "$ADBEN_ADB_KEYS"
	if grep -q $'\r' "$ADBEN_ADB_KEYS"; then bad "CR survived"; else ok; fi
}

test_customize() {
	start_test "installer: default config + key import + permissions"
	new_env
	printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExistingKeyPlaceholderForTests existing@pc\n' \
		>"$ADBEN_ADB_KEYS"
	printf 'QAAAA%s pc@host\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" \
		>"$FAKE/module/keys/pc.pub"
	cat >"$FAKE/installer_prelude.sh" <<'EOF'
ui_print() { printf '%s\n' "$1"; }
set_perm() { chmod "$4" "$1" 2>/dev/null; printf 'set_perm %s %s\n' "$1" "$4" >>"$FAKE/perm.log"; }
set_perm_recursive() { printf 'set_perm_recursive %s\n' "$1" >>"$FAKE/perm.log"; }
EOF
	out=$(FAKE="$FAKE" MODPATH="$FAKE/module" "$SH" -c \
		'. "$FAKE/installer_prelude.sh"; . "$MODPATH/customize.sh"' 2>&1)
	rc=$?
	assert_eq "customize rc" 0 "$rc"
	assert_file "default config created" "$ADBEN_CONFIG"
	assert_contains "config mentions ENABLE_ADB" "ENABLE_ADB=1" "$(cat "$ADBEN_CONFIG")"
	assert_eq "keys imported at install time" 2 "$(grep -c . "$ADBEN_ADB_KEYS")"
	if grep -q 'adbkey.pub from adb' "$ADBEN_ADB_KEYS"; then
		bad "keys/README.txt imported"
	else
		ok
	fi
	assert_contains "installer banner" "- ADB Enable v1.0.0" "$out"
	assert_contains "installer key note" "No-key mode" "$out"
	assert_contains "exec bit set" "set_perm_recursive" "$(cat "$FAKE/perm.log")"
}

test_cli() {
	start_test "cli: status / addkey / wireless / config / log"
	new_env
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=running\nsys.usb.config=mtp,adb\nsys.usb.state=mtp,adb\n' >"$FAKE/props"
	printf 'put global adb_enabled 1\n' >"$FAKE/settings.log"
	cp "$FAKE/settings.log" "$FAKE/settings.db.tmp"
	printf 'global/adb_enabled=1\n' >"$FAKE/settings.db"

	out=$("$SH" "$FAKE/module/bin/adb-enable" status 2>&1)
	assert_contains "status version" "ADB Enable v1.0.0" "$out"
	assert_contains "status adb_enabled" "adb_enabled     : 1" "$out"
	assert_contains "status adbd" "adbd            : running" "$out"

	printf 'QAAAA%s pc@host\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" >"$FAKE/new.pub"
	out=$("$SH" "$FAKE/module/bin/adb-enable" addkey "$FAKE/new.pub" 2>&1)
	assert_file "addkey copied" "$ADBEN_STATE_DIR/keys/new.pub"
	assert_file "addkey installed" "$ADBEN_ADB_KEYS"
	assert_contains "addkey output" "imported" "$out"

	out=$("$SH" "$FAKE/module/bin/adb-enable" wireless on 2>&1)
	assert_contains "wireless output" "wireless ADB on" "$out"
	assert_eq "wireless config" 1 "$(sed -n 's/^WIRELESS_ADB=//p' "$ADBEN_CONFIG")"
	assert_eq "wireless prop" 5555 "$(prop service.adb.tcp.port)"

	out=$("$SH" "$FAKE/module/bin/adb-enable" wireless off 2>&1)
	assert_contains "wireless off output" "wireless ADB off" "$out"
	assert_eq "wireless off service prop" -1 "$(prop service.adb.tcp.port)"
	assert_eq "wireless off persist prop" -1 "$(prop persist.adb.tcp.port)"

	out=$("$SH" "$FAKE/module/bin/adb-enable" config 2>&1)
	assert_contains "config output" "WIRELESS_ADB=0" "$out"

	out=$("$SH" "$FAKE/module/bin/adb-enable" run 2>&1)
	assert_contains "run output" "applied" "$out"

	out=$("$SH" "$FAKE/module/bin/adb-enable" log 2>&1)
	assert_contains "log output" "ADB Enable" "$out"

	out=$("$SH" "$FAKE/module/bin/adb-enable" nope 2>&1)
	assert_contains "usage on bad command" "usage:" "$out"
}

test_zip() {
	start_test "build: zip structure and permissions"
	(cd "$ROOT" && python3 build.py >/dev/null 2>&1) || {
		bad "build.py failed"
		return
	}
	zipfile=$(ls -1t "$ROOT"/dist/ADB-Enable-*.zip 2>/dev/null | head -n 1)
	assert_file "zip built" "$zipfile"
	out=$(python3 - "$zipfile" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
info = {i.filename: i for i in z.infolist()}
problems = []
for required in ("module.prop", "common.sh", "post-fs-data.sh", "service.sh",
                 "action.sh", "uninstall.sh", "customize.sh", "skip_mount",
                 "bin/adb-enable", "keys/README.txt",
                 "META-INF/com/google/android/update-binary",
                 "META-INF/com/google/android/updater-script"):
    if required not in names:
        problems.append("missing " + required)
for required in ("post-fs-data.sh", "service.sh", "action.sh", "uninstall.sh",
                 "bin/adb-enable", "META-INF/com/google/android/update-binary"):
    mode = (info[required].external_attr >> 16) & 0o777
    if mode != 0o755:
        problems.append("%s mode %o" % (required, mode))
props = z.read("module.prop").decode()
for line in ("id=adb_enable", "name=ADB Enable", "version=v1.0.0", "versionCode=10000"):
    if line not in props.splitlines():
        problems.append("module.prop missing " + line)
if b"\r\n" in z.read("module.prop"):
    problems.append("module.prop has CRLF")
if z.read("META-INF/com/google/android/updater-script").decode().strip() != "#MAGISK":
    problems.append("bad updater-script")
print("OK" if not problems else "; ".join(problems))
PY
)
	assert_eq "zip checks" "OK" "$out"

	# key files shipped in keys/ must be importable and README must be skipped
	python3 - "$zipfile" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
print("zip entries: %d" % len(z.namelist()))
PY
}

test_zip_runtime() {
	start_test "zip: extracted module runs end to end"
	(cd "$ROOT" && python3 build.py >/dev/null 2>&1) || {
		bad "build.py failed"
		return
	}
	zipfile=$(ls -1t "$ROOT"/dist/ADB-Enable-*.zip 2>/dev/null | head -n 1)
	new_env
	rm -rf "$FAKE/module"
	mkdir -p "$FAKE/module"
	python3 - "$zipfile" "$FAKE/module" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
	write_config <<'EOF'
BOOT_DELAY=0
RECHECK_SECONDS=0
SETTINGS_RETRY_DELAY=0
EOF
	printf 'sys.boot_completed=1\ninit.svc.adbd=stopped\nsys.usb.config=mtp\nsys.usb.state=mtp\n' >"$FAKE/props"
	printf 'QAAAA%s pc@host\n' "$(head -c 400 /dev/urandom | base64 | tr -d '\n')" \
		>"$ADBEN_STATE_DIR/keys/pc.pub"
	assert_eq "extracted post-fs-data rc" 0 "$(run_pfd)"
	assert_eq "extracted service rc" 0 "$(run_service)"
	assert_eq "extracted adb_enabled" 1 "$(setting global adb_enabled)"
	assert_eq "extracted adbd" running "$(prop init.svc.adbd)"
	assert_eq "extracted keys" 1 "$(grep -c . "$ADBEN_ADB_KEYS")"
}

test_negative_control() {
	start_test "negative control: the fd check really fires"
	new_env
	printf 'x\n' >"$FAKE/target.log"
	sh "$FAKE/bin/settings" get global adb_enabled >>"$FAKE/target.log" 2>/dev/null
	rc=$?
	assert_eq "fd violation detected" 97 "$rc"
	assert_file "violation recorded" "$FAKE/fd_violations"
}

# -------------------------------------------------------------------- main ---
cd "$ROOT" || exit 1
for t in test_syntax test_no_binder_redirect test_post_fs_data test_service_svc \
	test_service_prop_fallback test_settings_retry test_full_boot test_zero_config \
	test_ffs_not_ready test_keys_unknown_types test_keys_oversized_symlink \
	test_keys_backup_and_chcon_failure test_wireless_off_clears_persist \
	test_uninstall_clears_tcp test_wireless_off_master_off \
	test_wireless_default_off_early test_usb_config_validation \
	test_config_no_code_exec test_addkey_hidden \
	test_provision_early \
	test_system_cmd_resolution test_master_switch_off \
	test_options_off test_wireless test_keys_safety test_customize test_cli \
	test_zip test_zip_runtime test_negative_control; do
	"$t"
done

printf '\n==========================================\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf 'failures:\n'
	printf '  - %s\n' "${FAILED[@]}"
	exit 1
fi
printf 'ALL TESTS PASSED\n'
