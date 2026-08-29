#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
home="$test_tmp/home"
log="$test_tmp/calls.log"
mkdir -p "$stub_bin" "$home/.config/omarchy"
printf '%s\n' '{"host":"developer@mac.local"}' >"$home/.config/omarchy/ios-remote.json"
chmod 600 "$home/.config/omarchy/ios-remote.json"

cat >"$stub_bin/ssh" <<'STUB'
#!/bin/bash
line=ssh
for arg in "$@"; do line+=" <$arg>"; done
printf '%s\n' "$line" >>"$IOS_LOG"
forward=""
for ((i=1; i<=$#; i++)); do
  if [[ ${!i} == "-L" ]]; then ((i++)); forward=${!i}; fi
done
if [[ -n $forward ]]; then
  port=${forward#127.0.0.1:}; port=${port%%:*}
  exec python3 - "$port" "$IOS_LOG" <<'PY'
import signal, socket, sys
port, log = int(sys.argv[1]), sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', port)); s.listen()
def done(*_):
    open(log, 'a').write('vnc-tunnel-cleaned\n'); sys.exit(0)
signal.signal(signal.SIGTERM, done)
while True:
    connection, _ = s.accept(); connection.close()
PY
fi
if [[ " $* " == *" -R "* ]]; then
  trap 'printf "reverse-tunnel-cleaned\n" >>"$IOS_LOG"; exit 0' TERM
  while :; do sleep 1; done
fi
command=${!#}
case "$command" in
  *'simctl list devices available -j'*) printf '%s\n' "$IOS_DEVICES_JSON" ;;
  *'nc -z 127.0.0.1 5900'*) [[ ${IOS_VNC_AVAILABLE:-1} == 1 ]] ;;
  *'get_app_container'*) [[ ${IOS_EXPO_INSTALLED:-1} == 1 ]] ;;
  *'printf\ %s\ \"\$HOME\"'*) printf '/Users/developer' ;;
  *'test -d /Users/developer/Library/Caches/omarchy-ios/'*) [[ ${IOS_CACHE_PRESENT:-0} == 1 ]] ;;
  *'tar\ -xf\ -\ -C\ \"\$tmp\"'*) cat >/dev/null ;;
  *) : ;;
esac
STUB
chmod +x "$stub_bin/ssh"

cat >"$stub_bin/vncviewer" <<'STUB'
#!/bin/bash
printf 'vncviewer <%s>\n' "$*" >>"$IOS_LOG"
exit "${IOS_VIEWER_STATUS:-0}"
STUB
cat >"$stub_bin/omarchy-menu-select" <<'STUB'
#!/bin/bash
printf 'menu' >>"$IOS_LOG"; printf ' <%s>' "$@" >>"$IOS_LOG"; printf '\n' >>"$IOS_LOG"
printf '%s\n' "$IOS_MENU_SELECTION"
STUB
cat >"$stub_bin/ss" <<'STUB'
#!/bin/bash
[[ ${IOS_PORT_OCCUPIED:-0} == 1 ]] && printf 'LISTEN\n'
STUB
cat >"$stub_bin/pnpm" <<'STUB'
#!/bin/bash
line=pnpm
for arg in "$@"; do line+=" <$arg>"; done
printf '%s cwd=<%s>\n' "$line" "$PWD" >>"$IOS_LOG"
if [[ $1 == "dlx" ]]; then
  printf '%s\n' "$PWD" >"$IOS_DLX_DIR_FILE"
  mkdir -p "$PWD/Expo-Go-SDK.tar.app"
else
  if [[ ${IOS_METRO_FAIL:-0} == 1 ]]; then
    echo 'metro-startup-marker' >&2
    exit 17
  fi
  exec python3 - "$IOS_LOG" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import signal, sys
log = sys.argv[1]
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'packager-status:running')
    def log_message(self, *_): pass
server = HTTPServer(('127.0.0.1', 8081), Handler)
def done(*_):
    open(log, 'a').write('metro-cleaned\n'); sys.exit(0)
signal.signal(signal.SIGTERM, done)
server.serve_forever()
PY
fi
STUB
chmod +x "$stub_bin/vncviewer" "$stub_bin/omarchy-menu-select" "$stub_bin/ss" "$stub_bin/pnpm"
cat >"$stub_bin/omarchy-cmd-present" <<'STUB'
#!/bin/bash
command -v "$1" >/dev/null
STUB
chmod +x "$stub_bin/omarchy-cmd-present"

single_booted='{"devices":{"runtime":[{"name":"iPhone 16 Pro","udid":"UDID-BOOTED","state":"Booted","isAvailable":true}]}}'
multiple_shutdown='{"devices":{"runtime":[{"name":"iPhone 16","udid":"UDID-A","state":"Shutdown","isAvailable":true},{"name":"iPhone 16 Pro","udid":"UDID-B","state":"Shutdown","isAvailable":true}]}}'

run_ios() {
  status=0
  : >"$log"
  (
    cd "${IOS_RUN_CWD:-$ROOT}"
    IOS_LOG="$log" IOS_DEVICES_JSON="${IOS_DEVICES_JSON:-$single_booted}" \
      IOS_MENU_SELECTION="${IOS_MENU_SELECTION:-iPhone 16 Pro$'\t'UDID-B$'\t'Shutdown}" \
      PATH="$stub_bin:/usr/bin" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      bash "$ROOT/bin/omarchy-ios" "$@" >"$test_tmp/out" 2>&1
  ) || status=$?
}

IOS_DEVICES_JSON=$multiple_shutdown run_ios open
(( status == 0 )) || fail "interactive open succeeds with a selected device" "$(<"$test_tmp/out")"
grep -q 'menu .*UDID-A.*UDID-B' "$log" || fail "open offers available JSON devices to the deterministic selector" "$(<"$log")"
grep -q 'simctl boot UDID-B' "$log" && grep -q 'simctl bootstatus UDID-B -b' "$log" && grep -q 'CurrentDeviceUDID UDID-B' "$log" || fail "open boots, waits for, and focuses the selected UDID" "$(<"$log")"
grep -Eq 'ssh.* <-L> <127\.0\.0\.1:[0-9]+:127\.0\.0\.1:5900> <-->' "$log" || fail "VNC forwarding binds only local loopback" "$(<"$log")"
grep -Eq 'vncviewer <127\.0\.0\.1::[0-9]+>' "$log" || fail "viewer connects through the local tunnel without a password argument" "$(<"$log")"
grep -q 'vnc-tunnel-cleaned' "$log" || fail "VNC tunnel is torn down after viewer exit" "$(<"$log")"
pass "interactive open selects a stable UDID and cleans up its loopback-only VNC tunnel"

IOS_VNC_AVAILABLE=0 run_ios open
(( status != 0 )) || fail "open fails when remote Screen Sharing is unavailable"
! grep -q ' <-L>' "$log" || fail "unavailable Screen Sharing never starts a VNC tunnel" "$(<"$log")"
pass "interactive open verifies remote loopback port 5900 before tunneling"

IOS_VIEWER_STATUS=7 run_ios open
(( status == 7 )) || fail "open returns viewer failures" "$(<"$test_tmp/out")"
grep -q 'vnc-tunnel-cleaned' "$log" || fail "viewer failure tears down the VNC tunnel" "$(<"$log")"
pass "interactive open propagates viewer failure and cleans up"

IOS_DEVICES_JSON='not-json' run_ios open
(( status != 0 )) && grep -q 'Invalid Simulator device data' "$test_tmp/out" || fail "open rejects malformed remote device data" "$(<"$test_tmp/out")"
! grep -q 'simctl boot' "$log" || fail "malformed device data cannot cause Simulator side effects" "$(<"$log")"
pass "interactive open treats remote device JSON as untrusted data"

non_expo="$test_tmp/non-expo"
mkdir -p "$non_expo"; printf '{}\n' >"$non_expo/package.json"
run_ios run "$non_expo"
(( status != 0 )) && grep -q 'Could not detect a supported' "$test_tmp/out" || fail "run rejects projects without Expo metadata" "$(<"$test_tmp/out")"
! grep -q '^pnpm' "$log" || fail "non-Expo package metadata cannot trigger project commands" "$(<"$log")"
pass "iOS run treats package metadata as data and rejects non-Expo projects"

expo_project="$test_tmp/expo project"
mkdir -p "$expo_project/node_modules/expo"
printf '{"dependencies":{"expo":"^52.0.0"}}\n' >"$expo_project/package.json"
printf '{"version":"52.0.1"}\n' >"$expo_project/node_modules/expo/package.json"
mv "$stub_bin/pnpm" "$stub_bin/pnpm.off"
run_ios run "$expo_project"
(( status != 0 )) && grep -q 'requires pnpm' "$test_tmp/out" || fail "run requires pnpm" "$(<"$test_tmp/out")"
mv "$stub_bin/pnpm.off" "$stub_bin/pnpm"
pass "iOS run requires pnpm"

IOS_EXPO_INSTALLED=1 IOS_METRO_FAIL=1 run_ios run "$expo_project" --device UDID-BOOTED
(( status != 0 )) || fail "Expo run propagates Metro startup failure"
grep -q 'metro-startup-marker' "$test_tmp/out" || fail "Metro failure output remains visible after temporary cleanup" "$(<"$test_tmp/out")"
pass "iOS run prints Metro diagnostics before cleaning temporary logs"

run_ios run "$expo_project" --device --malicious-device
(( status != 0 )) && grep -q "cannot begin with '-'" "$test_tmp/out" || fail "run rejects simctl option injection" "$(<"$test_tmp/out")"
! grep -q 'bootstatus' "$log" || fail "malicious device input never reaches simctl" "$(<"$log")"
pass "iOS run rejects malicious device input before simulator side effects"

run_ios open UDID-BOOTED unexpected
(( status != 0 )) && grep -q 'Usage:' "$test_tmp/out" || fail "open rejects extra arguments" "$(<"$test_tmp/out")"
run_ios run "$expo_project" unexpected
(( status != 0 )) && grep -q 'Usage:' "$test_tmp/out" || fail "Expo run rejects extra arguments" "$(<"$test_tmp/out")"
pass "iOS open and run reject ignored extra arguments"

IOS_EXPO_INSTALLED=1 IOS_RUN_CWD="$expo_project" run_ios run --device UDID-BOOTED
(( status == 0 )) || fail "Expo run detects the project from the current directory" "$(<"$test_tmp/out")"
grep -q "cwd=<$expo_project>" "$log" || fail "default Expo run executes Metro from the current project" "$(<"$log")"
pass "iOS run auto-detects an Expo project from the current directory"

IOS_EXPO_INSTALLED=1 run_ios run "$expo_project" --device UDID-BOOTED
(( status == 0 )) || fail "Expo run succeeds when matching Expo Go is installed" "$(<"$test_tmp/out")"
! grep -q 'expo-go download' "$log" || fail "installed Expo Go avoids download" "$(<"$log")"
grep -q 'TEMPORARY_SDK_VERSION' "$log" || fail "installed Expo Go detection reads the SDK key used by real downloaded artifacts" "$(<"$log")"
grep -q 'generated JavaScript bundle and assets' "$test_tmp/out" || fail "Expo run explains what crosses the Mac trust boundary" "$(<"$test_tmp/out")"
grep -q 'pnpm <exec> <expo> <start> <--host> <localhost> <--port> <8081>' "$log" || fail "Expo run starts local Metro with fixed localhost flags" "$(<"$log")"
grep -q ' <-R> <127.0.0.1:8081:127.0.0.1:8081>' "$log" || fail "Expo run reverse forwarding binds remote and local loopback" "$(<"$log")"
grep -Fq 'simctl openurl UDID-BOOTED exp://127.0.0.1:8081' "$log" || fail "Expo run opens the tunneled Metro URL on the stable simulator UDID" "$(<"$log")"
grep -q 'reverse-tunnel-cleaned' "$log" && grep -q 'metro-cleaned' "$log" || fail "Expo run tears down Metro and its reverse tunnel" "$(<"$log")"
pass "Expo run uses installed Expo Go, local Metro, reverse loopback SSH, and cleanup"

IOS_EXPO_INSTALLED=0 IOS_CACHE_PRESENT=0 IOS_DLX_DIR_FILE="$test_tmp/dlx-dir" run_ios run "$expo_project" --device UDID-BOOTED
(( status == 0 )) || fail "Expo run downloads and installs missing Expo Go" "$(<"$test_tmp/out")"
grep -q 'pnpm <dlx> <expo-go@0.1.0> <download> <ios> <52>' "$log" || fail "Expo Go download pins its CLI and uses the detected installed SDK major" "$(<"$log")"
grep -Fq 'simctl install UDID-BOOTED /Users/developer/Library/Caches/omarchy-ios/expo-go/SDK-52/Expo-Go.app' "$log" || fail "Expo Go installs from the fixed remote user cache" "$(<"$log")"
dlx_dir=$(<"$test_tmp/dlx-dir")
[[ ! -e $dlx_dir ]] || fail "private Expo Go download directory is cleaned up" "$dlx_dir"
pass "Expo run downloads exactly one matching Expo Go app, caches, installs, and cleans temporary files"

[[ ! $(<"$log") =~ [Pp]assword|[Ss]ecret ]] || fail "iOS workflows never place secrets in SSH or viewer arguments" "$(<"$log")"
pass "iOS interactive and Expo workflows do not expand config or pass secrets"
