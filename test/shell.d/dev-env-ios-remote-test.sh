#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
log_file="$test_tmp/ssh.log"
pkg_log="$test_tmp/pkg.log"
home="$test_tmp/home"
mkdir -p "$stub_bin" "$home"

cat >"$stub_bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$#" >"$OMARCHY_IOS_TEST_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >>"$OMARCHY_IOS_TEST_LOG"; done
[[ -z ${OMARCHY_IOS_TEST_SSH_FAIL:-} ]] || exit 1
if [[ ${!#} == *'simctl list devices available -j'* ]]; then
  if [[ -n ${OMARCHY_IOS_TEST_DEVICES_JSON:-} ]]; then
    printf '%s\n' "$OMARCHY_IOS_TEST_DEVICES_JSON"
  else
    printf '%s\n' '{"devices":{"runtime":[{"name":"iPhone 16 Pro","udid":"UDID-16-PRO","state":"Shutdown","isAvailable":true}]}}'
  fi
fi
STUB
chmod +x "$stub_bin/ssh"

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_IOS_TEST_PKG_LOG"
[[ -z ${OMARCHY_IOS_TEST_PKG_FAIL:-} ]]
STUB
chmod +x "$stub_bin/omarchy-pkg-add"

cat >"$stub_bin/omarchy-cmd-present" <<'STUB'
#!/bin/bash
command -v "$1" >/dev/null
STUB
chmod +x "$stub_bin/omarchy-cmd-present"

run_install() {
  install_status=0
  PATH="$stub_bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    OMARCHY_IOS_TEST_LOG="$log_file" OMARCHY_IOS_TEST_PKG_LOG="$pkg_log" \
    bash "$ROOT/bin/omarchy-install-dev-env" ios "$1" >"$test_tmp/install.out" 2>&1 || install_status=$?
}

run_install "developer@mac-studio.local"
(( install_status == 0 )) || fail "iOS remote setup succeeds for a valid SSH target" "$(<"$test_tmp/install.out")"
pass "iOS remote setup succeeds for a valid SSH target"

grep -qx 'tigervnc' "$pkg_log" || fail "iOS remote setup installs TigerVNC before persisting config" "$(<"$pkg_log")"
pass "iOS remote setup installs TigerVNC for interactive remote desktop access"

config="$home/.config/omarchy/ios-remote.json"
[[ -f $config ]] || fail "iOS remote setup writes its config"
pass "iOS remote setup writes its config"

jq -e '. == {"host":"developer@mac-studio.local"}' "$config" >/dev/null ||
  fail "iOS remote config is non-executable JSON" "$(<"$config")"
pass "iOS remote config is non-executable JSON"

[[ $(stat -c %a "$config") == "600" ]] || fail "iOS remote config is private" "$(stat -c %a "$config")"
pass "iOS remote config is private"

mapfile -t ssh_call <"$log_file"
[[ ${ssh_call[0]} == "3" && ${ssh_call[1]} == "--" && ${ssh_call[2]} == "developer@mac-studio.local" ]] ||
  fail "installer terminates SSH options before the target" "$(<"$log_file")"
[[ ${ssh_call[3]} == *"xcode-select -p"* && ${ssh_call[3]} == *"xcrun --find simctl"* ]] ||
  fail "installer verifies Xcode and simctl before saving config" "$(<"$log_file")"
pass "installer verifies Xcode and simctl before saving config"

rm -f "$config" "$log_file"
OMARCHY_IOS_TEST_PKG_FAIL=1 run_install "developer@mac-studio.local"
(( install_status != 0 )) || fail "installer fails when TigerVNC cannot be installed"
[[ ! -e $config ]] || fail "package installation failure does not leave config behind"
pass "installer does not persist config when TigerVNC installation fails"

rm -f "$config" "$log_file"
run_install "-oProxyCommand=touch /tmp/pwned"
(( install_status != 0 )) || fail "installer rejects a target that could inject SSH options"
[[ ! -e $config && ! -e $log_file ]] || fail "invalid SSH targets cause no side effects"
pass "installer rejects SSH option injection before connecting or writing config"

rm -f "$config"
OMARCHY_IOS_TEST_SSH_FAIL=1 run_install "developer@offline-mac.local"
(( install_status != 0 )) || fail "installer fails when the Mac lacks or cannot expose Xcode"
[[ ! -e $config ]] || fail "failed remote validation does not leave config behind"
pass "installer only saves a Mac that passes the Xcode and simctl checks"

mkdir -p "$config"
run_install "developer@mac-studio.local"
(( install_status != 0 )) || fail "installer fails when the config destination is a directory"
[[ -d $config ]] || fail "failed config finalization leaves the colliding directory untouched"
if compgen -G "$(dirname "$config")/.ios-remote.json.*" >/dev/null; then
  fail "failed config finalization cleans up its temporary file"
fi
pass "installer reports config finalization failures and cleans up"
rm -rf "$config"

mkdir -p "$(dirname "$config")"
printf '%s\n' '{"host":"developer@mac-studio.local"}' >"$config"
chmod 600 "$config"

run_ios() {
  ios_status=0
  : >"$log_file"
  PATH="$stub_bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    OMARCHY_IOS_TEST_LOG="$log_file" OMARCHY_IOS_TEST_DEVICES_JSON="${OMARCHY_IOS_TEST_DEVICES_JSON:-}" \
    bash "$ROOT/bin/omarchy-ios" "$@" >"$test_tmp/ios.out" 2>&1 || ios_status=$?
}

run_ios devices
(( ios_status == 0 )) || fail "iOS devices command succeeds" "$(<"$test_tmp/ios.out")"
mapfile -t ssh_call <"$log_file"
[[ ${ssh_call[1]} == "--" && ${ssh_call[2]} == "developer@mac-studio.local" && ${ssh_call[3]} == "xcrun simctl list devices available" ]] ||
  fail "iOS devices lists available simulators on the configured Mac" "$(<"$log_file")"
pass "iOS devices lists available simulators on the configured Mac"

run_ios boot 'iPhone 16 Pro'
(( ios_status == 0 )) || fail "iOS boot command resolves a unique device name" "$(<"$test_tmp/ios.out")"
mapfile -t ssh_call <"$log_file"
[[ ${ssh_call[3]} == 'xcrun simctl boot UDID-16-PRO' ]] ||
  fail "iOS boot uses the uniquely resolved Simulator UDID" "$(<"$log_file")"
pass "iOS boot resolves names to stable Simulator UDIDs"

run_ios boot --help
(( ios_status != 0 )) || fail "iOS boot rejects device values that could become simctl options"
[[ ! -s $log_file ]] || fail "simctl option injection never reaches SSH" "$(<"$log_file")"
pass "iOS boot rejects simctl option injection before invoking SSH"

run_ios shutdown all
(( ios_status == 0 )) || fail "iOS shutdown command succeeds" "$(<"$test_tmp/ios.out")"
mapfile -t ssh_call <"$log_file"
[[ ${ssh_call[3]} == "xcrun simctl shutdown all" ]] || fail "iOS shutdown targets the configured Mac" "$(<"$log_file")"
pass "iOS shutdown targets a named simulator or all simulators"

run_ios open
(( ios_status != 0 )) || fail "iOS open requires a local VNC viewer"
grep -q "requires vncviewer" "$test_tmp/ios.out" || fail "iOS open explains its TigerVNC requirement" "$(<"$test_tmp/ios.out")"
[[ ! -s $log_file ]] || fail "iOS open checks the viewer before remote side effects" "$(<"$log_file")"
pass "iOS open requires TigerVNC before touching the remote Mac"

run_ios doctor
(( ios_status == 0 )) || fail "iOS doctor command succeeds" "$(<"$test_tmp/ios.out")"
grep -q "remote Mac" "$test_tmp/ios.out" || fail "iOS doctor states the remote-only product boundary" "$(<"$test_tmp/ios.out")"
mapfile -t ssh_call <"$log_file"
[[ ${ssh_call[3]} == *"xcodebuild -version"* && ${ssh_call[3]} == *"xcrun --find simctl"* ]] ||
  fail "iOS doctor checks the remote Xcode toolchain" "$(<"$log_file")"
pass "iOS doctor makes the remote-only boundary explicit and checks Xcode"

printf '%s\n' '{"host":"-Fmalicious"}' >"$config"
run_ios devices
(( ios_status != 0 )) || fail "iOS command rejects an unsafe host loaded from config"
[[ ! -s $log_file ]] || fail "unsafe config never reaches SSH" "$(<"$log_file")"
pass "iOS command revalidates persisted hosts before invoking SSH"

printf '%s\n' '{not-json' >"$config"
run_ios devices
(( ios_status != 0 )) || fail "iOS command rejects malformed JSON config"
[[ ! -s $log_file ]] || fail "malformed config never reaches SSH" "$(<"$log_file")"
pass "iOS command treats config as data and rejects malformed JSON"

printf '%s\n' '{"host":"developer@mac-studio.local"}' >"$config"
PATH="$stub_bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
  bash "$ROOT/bin/omarchy-remove-dev-env" ios >"$test_tmp/remove.out" 2>&1 ||
  fail "removing iOS remote setup succeeds" "$(<"$test_tmp/remove.out")"
[[ ! -e $config ]] || fail "removing iOS remote setup deletes its config"
pass "removing iOS remote setup only deletes the local connection config"

mkdir -p "$config"
remove_status=0
PATH="$stub_bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
  bash "$ROOT/bin/omarchy-remove-dev-env" ios >"$test_tmp/remove.out" 2>&1 || remove_status=$?
(( remove_status != 0 )) || fail "remover reports a config path it cannot remove"
[[ -d $config ]] || fail "failed removal leaves the colliding directory untouched"
pass "remover does not falsely report success when local config removal fails"
