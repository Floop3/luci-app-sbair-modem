#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
# Mac-side iperf3 installer/test helper for SoftBank Air 6 / SBA6D.
set -euo pipefail

COMMAND=${1:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
[ -n "$COMMAND" ] && shift || true
AIR6_HOST=${AIR6_HOST:-}
AIR6_USER=${AIR6_USER:-root}
AIR6_SSH_PORT=${AIR6_SSH_PORT:-22}
AIR6_FORCE=${AIR6_FORCE:-0}
FEED_BASE=https://downloads.openwrt.org/releases/21.02.7/packages/aarch64_generic/packages/
REMOTE_STAGE=/tmp/sbair-iperf3-$$
TMP_DIR=
META_FILE=
RUN_DIR=
REFERENCE_HOST=${REFERENCE_HOST:-}
IPERF_DURATION=${IPERF_DURATION:-10}
IPERF_UDP_DURATION=${IPERF_UDP_DURATION:-2}
SBAIR_IPERF_BRIDGE=${SBAIR_IPERF_BRIDGE:-br-lan}
REMOTE_RUN_ID=sbair-$$
REMOTE_RUN_DIR=/tmp/sbair-iperf3-run-$REMOTE_RUN_ID
REMOTE_TUNING_PATH=/tmp/sbair-iperf3-tuning.snapshot
TEST_SETUP_ACTIVE=0
EXPERIMENT_ACTIVE=0
TABLE_FILE=
SELECTED_IFACE=
INTERFACE_DECISION=
IRQ_NUMBER=
IRQ_HOT_CPU=
IRQ_TARGET_CPU=
IRQ_CAN_TUNE=0
BASELINE_DROP=0
BASELINE_SQUEEZE=0
BASELINE_BACKLOG=unknown
PKG_VERSION=
PKG_FILENAME=
PKG_SHA256=
PKG_DEPENDS=
PACKAGE_FILES=()
PACKAGE_NAMES=()
PACKAGE_HASHES=()
PACKAGE_REMOTE_PATHS=()
OPKG_ARGS=

PARSER_FILE=$SCRIPT_DIR/parsers.sh
[ -r "$PARSER_FILE" ] || { echo "[ERROR] parser helper is missing: $PARSER_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
. "$PARSER_FILE"

die() { echo "[ERROR] $*" >&2; exit 1; }
say() { echo "[INFO] $*"; }
usage() {
  cat <<'EOF'
Usage:
  ./air6-install-iperf3.sh install [AIR6_IP]
  ./air6-install-iperf3.sh check [AIR6_IP]
  ./air6-install-iperf3.sh start [AIR6_IP]
  ./air6-install-iperf3.sh stop [AIR6_IP]
  ./air6-install-iperf3.sh test [AIR6_IP]
  ./air6-install-iperf3.sh diagnose [AIR6_IP] [--duration SEC]
  ./air6-install-iperf3.sh experiment [AIR6_IP] [--duration SEC]
  ./air6-install-iperf3.sh rollback [AIR6_IP]

Environment:
  AIR6_HOST=<AIR6_IP>       Air6 address (no default)
  AIR6_USER=root              SSH user
  AIR6_SSH_PORT=22            SSH port
  AIR6_FORCE=1                reinstall an already runnable iperf3
  --reference-host HOST       optional external iperf3 endpoint
  --duration SEC              duration of each diagnostic TCP benchmark (default: 10)
  --udp-duration SEC          duration of each UDP sweep step (default: 2)
EOF
}

[ -n "$COMMAND" ] || { usage >&2; exit 2; }
case "$COMMAND" in
  install|check|start|stop|test|diagnose|experiment|rollback) : ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; die "unknown command: $COMMAND" ;;
esac

POSITIONAL_HOST=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) [ "$#" -ge 2 ] || die '--host requires an address'; AIR6_HOST=$2; shift ;;
    --user) [ "$#" -ge 2 ] || die '--user requires a username'; AIR6_USER=$2; shift ;;
    --port) [ "$#" -ge 2 ] || die '--port requires a TCP port'; AIR6_SSH_PORT=$2; shift ;;
    --reference-host) [ "$#" -ge 2 ] || die '--reference-host requires an address'; REFERENCE_HOST=$2; shift ;;
    --duration) [ "$#" -ge 2 ] || die '--duration requires seconds'; IPERF_DURATION=$2; shift ;;
    --udp-duration) [ "$#" -ge 2 ] || die '--udp-duration requires seconds'; IPERF_UDP_DURATION=$2; shift ;;
    --force) AIR6_FORCE=1 ;;
    --help|-h) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ "$POSITIONAL_HOST" -eq 0 ] || die 'only one Air6 address is allowed'; AIR6_HOST=$1; POSITIONAL_HOST=1 ;;
  esac
  shift
done

[ -n "$AIR6_HOST" ] || {
  usage >&2
  die 'Air6 address is required (use positional AIR6_IP, --host or AIR6_HOST)'
}

case "$AIR6_SSH_PORT" in ''|*[!0-9]*) die 'AIR6_SSH_PORT must be numeric' ;; esac
case "$IPERF_DURATION" in ''|*[!0-9]*) die 'IPERF_DURATION must be numeric' ;; esac
case "$IPERF_UDP_DURATION" in ''|*[!0-9]*) die 'IPERF_UDP_DURATION must be numeric' ;; esac
if [[ "$AIR6_HOST" == *@* ]]; then TARGET=$AIR6_HOST; else TARGET=${AIR6_USER}@${AIR6_HOST}; fi
SSH_ARGS=(-p "$AIR6_SSH_PORT" -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

require_command() { command -v "$1" >/dev/null 2>&1 || die "required Mac command is missing: $1"; }
hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
cleanup() {
  local rc=$?
  set +e
  if [ "${EXPERIMENT_ACTIVE:-0}" -eq 1 ] && type rollback_remote >/dev/null 2>&1; then
    echo '[WARN] emergency rollback: restoring Air6 runtime tuning' >&2
    rollback_remote >/dev/null 2>&1 || echo '[ERROR] emergency rollback failed; run rollback explicitly' >&2
  fi
  if [ "${TEST_SETUP_ACTIVE:-0}" -eq 1 ] && type cleanup_test_setup >/dev/null 2>&1; then
    cleanup_test_setup >/dev/null 2>&1 || echo '[ERROR] temporary iperf test cleanup failed' >&2
  fi
  [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ] || rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
remote() { ssh "${SSH_ARGS[@]}" "$TARGET" "$@"; }
remote_script() { ssh "${SSH_ARGS[@]}" "$TARGET" /bin/sh -s -- "$@"; }
check_ssh() { remote true >/dev/null 2>&1 || die "cannot reach Air6 by SSH: $TARGET"; }

preflight() {
  say "checking SSH and Air6 platform: $TARGET"
  local output
  if ! output=$(remote_script <<'REMOTE_PREFLIGHT'
set -eu
echo '=== AIR6 PREFLIGHT ==='
[ -r /etc/openwrt_release ] || { echo '[ERROR] /etc/openwrt_release is missing' >&2; exit 1; }
cat /etc/openwrt_release
release=$(sed -n "s/^DISTRIB_RELEASE='//p" /etc/openwrt_release | sed "s/'$//" | head -n 1)
[ "$release" = '21.02.7' ] || { echo "[ERROR] required OpenWrt release is 21.02.7 (found $release)" >&2; exit 1; }
machine=$(uname -m)
if [ "$machine" != "aarch64" ]; then echo "[ERROR] target is not aarch64: $machine" >&2; exit 1; fi
command -v opkg >/dev/null 2>&1 || { echo '[ERROR] opkg is missing' >&2; exit 1; }
echo "uname -m: $machine"
echo 'opkg architectures:'
opkg print-architecture
echo 'root filesystem:'
df -h /
REMOTE_PREFLIGHT
  ); then
    echo "$output"
    die 'Air6 preflight failed (release, architecture, or opkg check)'
  fi
  echo "$output"
}

download_metadata() {
  require_command curl
  require_command gzip
  require_command awk
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/air6-iperf3.XXXXXX")
  META_FILE=$TMP_DIR/Packages.gz
  say 'downloading Packages.gz on the Mac'
  curl --fail --location --retry 2 --connect-timeout 15 --output "$META_FILE.part" "$FEED_BASE/Packages.gz" || die 'Mac download failed: Packages.gz'
  mv "$META_FILE.part" "$META_FILE"
  gzip -t "$META_FILE" || die 'downloaded Packages.gz is invalid'
}

# Output: version<TAB>filename<TAB>sha256<TAB>depends<TAB>architecture.
lookup_package() {
  local wanted=$1 required_arch=${2:-}
  gzip -cd "$META_FILE" | awk -v wanted="$wanted" -v required_arch="$required_arch" '
  BEGIN { RS = ""; FS = "\n"; found = 0; best_rank = 999 }
  {
    pkg = version = filename = sha = depends = arch = ""
    for (i = 1; i <= NF; i++) {
      line = $i
      if (index(line, "Package: ") == 1) pkg = substr(line, 10)
      else if (index(line, "Version: ") == 1) version = substr(line, 10)
      else if (index(line, "Filename: ") == 1) filename = substr(line, 11)
      else if (index(line, "SHA256sum: ") == 1) sha = substr(line, 12)
      else if (index(line, "Depends: ") == 1) depends = substr(line, 10)
      else if (index(line, "Architecture: ") == 1) arch = substr(line, 15)
    }
    if (pkg != wanted || version == "" || filename == "" || sha == "") next
    if (required_arch != "" && arch != required_arch) next
    if (required_arch == "") {
      rank = (arch == "aarch64_generic" ? 0 : (arch == "all" || arch == "noarch" ? 1 : 99))
      if (rank >= 99) next
    } else rank = 0
    if (!found || rank < best_rank) {
      found = 1
      best_rank = rank
      best = version "\t" filename "\t" sha "\t" depends "\t" arch
    }
  }
  END { if (found) print best; else exit 1 }
  ' || return 1
}

validate_filename() {
  case "$1" in ''|*/*|*..*) die "invalid package filename from metadata: $1" ;; esac
  case "$1" in *.ipk) : ;; *) die "package filename does not end in .ipk: $1" ;; esac
}
validate_package_name() {
  case "$1" in ''|*[!A-Za-z0-9+._-]*) die "invalid package name: $1" ;; esac
}
package_index() {
  local needle=$1 item
  for item in "${PACKAGE_NAMES[@]}"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}
protected_dependency() {
  case "$1" in libc|libubus*|libuci*|libubox*|kernel|kernel-*|kmod-*|kn_*|mtk_*) return 0 ;; *) return 1 ;; esac
}
remote_package_installed() {
  local package=$1
  validate_package_name "$package"
  remote "opkg status '$package' 2>/dev/null | grep -q '^Status: install ok installed$'"
}

download_record() {
  local package=$1 record=$2 role=$3
  local version filename expected depends arch path actual
  version=$(printf '%s\n' "$record" | awk -F '\t' '{print $1}')
  filename=$(printf '%s\n' "$record" | awk -F '\t' '{print $2}')
  expected=$(printf '%s\n' "$record" | awk -F '\t' '{print $3}')
  depends=$(printf '%s\n' "$record" | awk -F '\t' '{print $4}')
  arch=$(printf '%s\n' "$record" | awk -F '\t' '{print $5}')
  validate_package_name "$package"
  validate_filename "$filename"
  case "$expected" in ''|*[!0-9a-fA-F]*) die "invalid SHA256 for $package" ;; esac
  [ "${#expected}" -eq 64 ] || die "invalid SHA256 length for $package"
  path=$TMP_DIR/$filename
  say "downloading $role package: $package ($version, $arch)"
  curl --fail --location --retry 2 --connect-timeout 15 --output "$path.part" "$FEED_BASE/$filename" || die "Mac download failed for $package"
  mv "$path.part" "$path"
  actual=$(hash_file "$path")
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ] || die "SHA256 mismatch for $filename (got $actual)"
  say "Mac SHA256 verified: $filename"
  PACKAGE_FILES+=("$path")
  PACKAGE_NAMES+=("$package")
  PACKAGE_HASHES+=("$expected")
  PACKAGE_REMOTE_PATHS+=("$REMOTE_STAGE/$filename")
}

resolve_direct_dependencies() {
  local raw name record dep_depends
  [ -n "$PKG_DEPENDS" ] || return 0
  say "checking declared iperf3 dependencies: $PKG_DEPENDS"
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    name=$(printf '%s\n' "$raw" | awk -F'|' '{print $1}' | sed 's/[[:space:]]*(.*$//; s/[[:space:]]//g; s/:.*$//')
    validate_package_name "$name"
    if remote_package_installed "$name" >/dev/null 2>&1; then
      say "dependency already installed: $name"
      continue
    fi
    protected_dependency "$name" && die "required protected/vendor dependency is not installed: $name"
    package_index "$name" && continue
    record=$(lookup_package "$name") || die "dependency metadata not found in official feed: $name"
    download_record "$name" "$record" dependency
    dep_depends=$(printf '%s\n' "$record" | awk -F '\t' '{print $4}')
    [ -z "$dep_depends" ] || die "dependency $name has additional dependencies; refusing general package-manager behavior: $dep_depends"
  done <<EOF
$(printf '%s\n' "$PKG_DEPENDS" | awk -F',' '{ for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i); if ($i != "") print $i } }')
EOF
}

discover_and_download() {
  local record
  record=$(lookup_package iperf3 aarch64_generic) || die 'package metadata not found: iperf3/aarch64_generic'
  PKG_VERSION=$(printf '%s\n' "$record" | awk -F '\t' '{print $1}')
  PKG_FILENAME=$(printf '%s\n' "$record" | awk -F '\t' '{print $2}')
  PKG_SHA256=$(printf '%s\n' "$record" | awk -F '\t' '{print $3}')
  PKG_DEPENDS=$(printf '%s\n' "$record" | awk -F '\t' '{print $4}')
  validate_filename "$PKG_FILENAME"
  say "iperf3 metadata: version=$PKG_VERSION filename=$PKG_FILENAME"
  [ -n "$PKG_DEPENDS" ] && say "iperf3 declared dependencies: $PKG_DEPENDS" || say 'iperf3 declared dependencies: none'
  download_record iperf3 "$record" main
  resolve_direct_dependencies
}

upload_and_verify() {
  local i file filename path actual expected args=
  for i in "${!PACKAGE_FILES[@]}"; do
    file=${PACKAGE_FILES[$i]}
    filename=$(basename "$file")
    path=${PACKAGE_REMOTE_PATHS[$i]}
    expected=${PACKAGE_HASHES[$i]}
    args="$args '$path'"
    validate_filename "$filename"
    say "uploading verified IPK over local-LAN SSH: $filename"
    remote "umask 077; cat > '$path'" <"$file" || die "upload failed: $filename"
    actual=$(remote "if command -v sha256sum >/dev/null 2>&1; then sha256sum '$path' | awk '{print \$1}'; else echo NO_SHA256SUM; fi") || die "target-side hash check failed: $filename"
    case "$actual" in
      NO_SHA256SUM) say 'Air6 has no sha256sum; Mac verification remains authoritative' ;;
      *) [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ] || die "target-side SHA256 mismatch: $filename"; say "target SHA256 verified: $filename" ;;
    esac
  done
  OPKG_ARGS=$args
}

install_local_packages() {
  local dryrun
  upload_and_verify
  say 'running opkg dry-run with temporary architectures only'
  if ! dryrun=$(remote "opkg --add-arch all:1 --add-arch noarch:1 --add-arch aarch64_generic:10 --add-arch aarch64_cortex-a55_neon-vfpv4:100 --noaction install $OPKG_ARGS" 2>&1); then
    echo "$dryrun"
    die 'opkg dry-run failed; no installation was performed'
  fi
  echo "$dryrun"
  if printf '%s\n' "$dryrun" | grep -Eiq '(^|[[:space:]])(upgrading|downgrading|removing|reinstalling|replacing|purging|downloading)([[:space:]]|:)'; then die 'opkg dry-run unsafe: upgrade/downgrade/removal/download detected'; fi
  if printf '%s\n' "$dryrun" | grep -Eiq '(installing|upgrading|downgrading|removing|reinstalling|replacing|purging)[[:space:]]+(libc([[:space:]]|$)|libubus|libuci|libubox|kernel([[:space:]-]|$)|kmod-|kn_|mtk_)'; then die 'opkg dry-run unsafe: core/kernel/vendor activity detected'; fi
  say 'installing only transferred local IPKs'
  remote "opkg --add-arch all:1 --add-arch noarch:1 --add-arch aarch64_generic:10 --add-arch aarch64_cortex-a55_neon-vfpv4:100 install $OPKG_ARGS" || die 'local opkg install failed'
  remote_script <<'REMOTE_POST'
set -eu
command -v iperf3
iperf3 --version
opkg status iperf3
if command -v ldd >/dev/null 2>&1; then echo '=== ldd /usr/bin/iperf3 ==='; ldd /usr/bin/iperf3 || true; fi
REMOTE_POST
  remote "rm -f $OPKG_ARGS"
  remote "rmdir '$REMOTE_STAGE' 2>/dev/null || true"
  say 'temporary uploaded IPKs removed from Air6'
}

install_command() {
  check_ssh
  preflight
  if [ "$AIR6_FORCE" != 1 ] && remote_script <<'REMOTE_RUNNABLE' >/dev/null 2>&1
set -eu
command -v iperf3 >/dev/null
iperf3 --version >/dev/null
REMOTE_RUNNABLE
  then
    say 'iperf3 is already installed and runnable; skipping reinstall'
    check_command
    return 0
  fi
  download_metadata
  discover_and_download
  install_local_packages
  echo 'iperf3 installation completed; no Air6 network or Wi-Fi settings were changed.'
}

check_command() {
  check_ssh
  remote_script <<'REMOTE_CHECK' || die 'iperf3 check failed: not installed or not runnable'
set -u
echo '=== IPERF3 CHECK ==='
command -v iperf3 >/dev/null 2>&1 || { echo '[NOT INSTALLED] iperf3'; exit 1; }
command -v iperf3
iperf3 --version || true
opkg status iperf3 || true
echo '=== SERVER PROCESS ==='
ps w | grep '[i]perf3' || true
echo '=== TCP/5201 ==='
netstat -lnt 2>/dev/null | grep -E '(^|[[:space:]])(0\.0\.0\.0:|:::|[0-9.]+:)5201([[:space:]]|$)' || echo '[NOT LISTENING] TCP/5201'
echo '=== TEMPORARY FIREWALL RULE ==='
iptables -C INPUT -i br-lan -p tcp --dport 5201 -j ACCEPT 2>/dev/null && echo '[PRESENT] br-lan TCP/5201' || echo '[ABSENT] br-lan TCP/5201'
REMOTE_CHECK
}

start_command() {
  check_ssh
  remote_script <<'REMOTE_START' || die 'iperf3 failed to start or TCP/5201 is not listening'
set -eu
command -v iperf3 >/dev/null 2>&1 || { echo '[ERROR] iperf3 is not installed; run install first' >&2; exit 1; }
iperf3 --version >/dev/null 2>&1 || { echo '[ERROR] iperf3 is not runnable' >&2; exit 1; }
if ! iptables -C INPUT -i br-lan -p tcp --dport 5201 -j ACCEPT 2>/dev/null; then
  iptables -I INPUT 1 -i br-lan -p tcp --dport 5201 -j ACCEPT
  echo 'temporary firewall rule added: br-lan TCP/5201'
  echo 'tcp br-lan 5201' > /tmp/sbair-iperf3.firewall
else
  echo 'existing firewall rule reused: br-lan TCP/5201'
fi
if ps w | grep -E '[i]perf3.*(^|[[:space:]])-s([[:space:]]|$)' >/dev/null 2>&1; then echo 'iperf3 server already running'; else iperf3 -s -D; echo 'iperf3 server started'; fi
sleep 1
ps w | grep -E '[i]perf3.*(^|[[:space:]])-s([[:space:]]|$)' >/dev/null 2>&1 || { echo '[ERROR] iperf3 server process was not found' >&2; exit 1; }
netstat -lnt 2>/dev/null | grep -E '(^|[[:space:]])(0\.0\.0\.0:|:::|[0-9.]+:)5201([[:space:]]|$)' >/dev/null 2>&1 || { echo '[ERROR] TCP/5201 is not listening' >&2; exit 1; }
echo '[OK] iperf3 server process exists and TCP/5201 is LISTEN'
REMOTE_START
}

stop_command() {
  check_ssh
  remote_script <<'REMOTE_STOP' || die 'iperf3 stop failed'
set -u
found=0
for pid in $(ps w | awk '$0 ~ /[i]perf3/ && $0 ~ /(^|[[:space:]])-s([[:space:]]|$)/ { print $1 }'); do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  kill "$pid" 2>/dev/null || true
  found=1
done
if [ "$found" -eq 1 ]; then sleep 1; echo 'iperf3 server stopped'; else echo 'iperf3 server was not running'; fi
if [ -f /tmp/sbair-iperf3.firewall ]; then
  if iptables -C INPUT -i br-lan -p tcp --dport 5201 2>/dev/null; then iptables -D INPUT -i br-lan -p tcp --dport 5201 -j ACCEPT 2>/dev/null || true; echo 'temporary firewall rule removed: br-lan TCP/5201'; else echo 'temporary firewall rule was already absent'; fi
  rm -f /tmp/sbair-iperf3.firewall
else
  echo 'no firewall rule created by this helper; existing rules were left untouched'
fi
REMOTE_STOP
}

test_command() {
  require_command iperf3
  check_ssh
  say "showing Mac route selected for $AIR6_HOST"
  command -v route >/dev/null 2>&1 && route -n get "$AIR6_HOST" || true
  start_command
  local normal_status=0 reverse_status=0
  echo '=== Mac -> Air6 ==='
  iperf3 -c "$AIR6_HOST" -P 4 -t 30 || normal_status=1
  echo '=== Air6 -> Mac ==='
  iperf3 -c "$AIR6_HOST" -P 4 -t 30 -R || reverse_status=1
  if [ "$normal_status" -ne 0 ] || [ "$reverse_status" -ne 0 ]; then die "iperf3 test failed (Mac->Air6=$normal_status Air6->Mac=$reverse_status); use stop to clean up"; fi
  echo 'iperf3 tests completed. The diagnostic server remains running; run stop when finished.'
}

make_run_dir() {
  RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/air6-iperf3-run.XXXXXX") || die 'cannot create Mac-side diagnostic run directory'
  chmod 700 "$RUN_DIR"
  TABLE_FILE=$RUN_DIR/results.tsv
  printf 'mode\tmac_to_air6\tair6_to_mac\tretrans\tsoftnet_drop\n' > "$TABLE_FILE"
}

remote_setup_test() {
  [ "${TEST_SETUP_ACTIVE:-0}" -eq 1 ] && return 0
  TEST_SETUP_ACTIVE=1
  remote_script "$REMOTE_RUN_ID" "$SBAIR_IPERF_BRIDGE" 5201 5211 5212 5213 5214 <<'REMOTE_SETUP'
set -eu
run_id=$1
bridge=$2
shift 2
case "$run_id" in ''|*[!A-Za-z0-9_.-]*) echo '[ERROR] invalid diagnostic run id' >&2; exit 1 ;; esac
case "$bridge" in ''|*[!A-Za-z0-9_.:-]*) echo '[ERROR] invalid bridge name' >&2; exit 1 ;; esac
run_dir=/tmp/sbair-iperf3-run-$run_id
mkdir -p "$run_dir"
chmod 700 "$run_dir"
created_firewall=$run_dir/firewall-created
server_pids=$run_dir/server-pids
: > "$created_firewall"
: > "$server_pids"
command -v iperf3 >/dev/null 2>&1 || { echo '[ERROR] iperf3 is not installed on Air6' >&2; exit 1; }
command -v iptables >/dev/null 2>&1 || { echo '[ERROR] iptables is missing on Air6' >&2; exit 1; }
command -v netstat >/dev/null 2>&1 || { echo '[ERROR] netstat is missing on Air6' >&2; exit 1; }
[ -d "/sys/class/net/$bridge" ] || { echo "[ERROR] bridge does not exist: $bridge" >&2; exit 1; }
listening() {
  netstat -ln 2>/dev/null | grep -E "([.:])$1([[:space:]]|$)" >/dev/null 2>&1
}
for port in "$@"; do
  case "$port" in ''|*[!0-9]*) echo '[ERROR] invalid test port' >&2; exit 1 ;; esac
  if [ "$port" != 5201 ] && listening "$port"; then
    echo "[ERROR] temporary test port is already in use: $port" >&2
    exit 1
  fi
done
add_rule() {
  proto=$1
  port=$2
  if ! iptables -C INPUT -i "$bridge" -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -i "$bridge" -p "$proto" --dport "$port" -j ACCEPT
    printf '%s\t%s\n' "$proto" "$port" >> "$created_firewall"
    echo "temporary firewall rule added: $bridge $proto/$port"
  else
    echo "existing firewall rule reused: $bridge $proto/$port"
  fi
}
for port in "$@"; do add_rule tcp "$port"; done
add_rule udp 5201
if ! listening 5201; then
  iperf3 -s -D -p 5201
  sleep 1
  pid=$(ps w | awk '$0 ~ /[i]perf3/ && $0 ~ /(^|[[:space:]])-s([[:space:]]|$)/ && $0 ~ /(^|[[:space:]])-p[[:space:]]+5201([[:space:]]|$)/ { print $1; exit }')
  case "$pid" in ''|*[!0-9]*) echo '[ERROR] temporary TCP/5201 server PID was not found' >&2; exit 1 ;; esac
  printf '%s\n' "$pid" >> "$server_pids"
  echo "temporary iperf3 server started: TCP/5201 pid=$pid"
else
  echo 'existing TCP/5201 server reused; it will not be stopped'
fi
for port in 5211 5212 5213 5214; do
  iperf3 -s -D -p "$port"
  sleep 1
  pid=$(ps w | awk -v needle="-p $port" '$0 ~ /[i]perf3/ && $0 ~ /(^|[[:space:]])-s([[:space:]]|$)/ && index($0, needle) > 0 { print $1; exit }')
  case "$pid" in ''|*[!0-9]*) echo "[ERROR] temporary TCP/$port server PID was not found" >&2; exit 1 ;; esac
  printf '%s\n' "$pid" >> "$server_pids"
  echo "temporary iperf3 server started: TCP/$port pid=$pid"
done
for port in 5201 5211 5212 5213 5214; do
  listening "$port" || { echo "[ERROR] TCP/$port is not listening" >&2; exit 1; }
done
REMOTE_SETUP
}

cleanup_test_setup() {
  [ "${TEST_SETUP_ACTIVE:-0}" -eq 1 ] || return 0
  if remote_script "$REMOTE_RUN_ID" "$SBAIR_IPERF_BRIDGE" <<'REMOTE_CLEANUP'
set -u
run_id=$1
bridge=$2
run_dir=/tmp/sbair-iperf3-run-$run_id
server_pids=$run_dir/server-pids
created_firewall=$run_dir/firewall-created
if [ -f "$server_pids" ]; then
  while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill "$pid" 2>/dev/null || true
  done < "$server_pids"
fi
if [ -f "$created_firewall" ]; then
  while IFS='	' read -r proto port; do
    case "$proto:$port" in
      tcp:*|udp:*)
        if iptables -C INPUT -i "$bridge" -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
          iptables -D INPUT -i "$bridge" -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
        ;;
    esac
  done < "$created_firewall"
fi
rm -f "$server_pids" "$created_firewall"
rmdir "$run_dir" 2>/dev/null || true
REMOTE_CLEANUP
  then
    TEST_SETUP_ACTIVE=0
    return 0
  fi
  TEST_SETUP_ACTIVE=0
  return 1
}

remote_snapshot() {
  local label=$1 iface=${2:-}
  remote_script "$label" "$iface" <<'REMOTE_SNAPSHOT'
set -u
label=$1
iface=${2:-}
valid_iface=1
case "$iface" in ''|*[!A-Za-z0-9_.:-]*) valid_iface=0; iface= ;; esac
section_file() {
  name=$1
  path=$2
  printf '@@BEGIN %s@@\n' "$name"
  if [ -r "$path" ]; then cat "$path" 2>&1 || true; else echo '[unavailable]'; fi
  printf '@@END %s@@\n' "$name"
}
section_cpu_frequency() {
  found=0
  for path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [ -r "$path" ] || continue
    printf '%s=%s\n' "$path" "$(cat "$path")"
    found=1
  done
  [ "$found" -eq 1 ] || echo '[unavailable]'
}
section_thermal() {
  found=0
  for path in /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$path" ] || continue
    printf '%s=%s\n' "$path" "$(cat "$path")"
    found=1
  done
  [ "$found" -eq 1 ] || echo '[unavailable]'
}
section_online() {
  found=0
  if [ -r /sys/devices/system/cpu/online ]; then
    printf 'online_file=%s\n' "$(cat /sys/devices/system/cpu/online)"
  fi
  for path in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$path" ] || continue
    cpu=${path##*/cpu}
    online=1
    if [ -r "$path/online" ] && [ "$(cat "$path/online" 2>/dev/null || echo 0)" = 0 ]; then online=0; fi
    [ "$online" -eq 1 ] || continue
    printf 'cpu=%s\n' "$cpu"
    found=1
  done
  [ "$found" -eq 1 ] || echo '[unavailable]'
}
section_sysctls() {
  for key in net.core.netdev_max_backlog net.core.netdev_budget net.core.netdev_budget_usecs; do
    path=/proc/sys/$(printf '%s' "$key" | tr . /)
    if [ -r "$path" ]; then printf '%s=%s\n' "$key" "$(cat "$path")"; else printf '%s=unavailable\n' "$key"; fi
  done
}
section_queues() {
  [ "$valid_iface" -eq 1 ] || { echo '[unavailable]'; return; }
  found=0
  for path in /sys/class/net/$iface/queues/rx-*/rps_cpus /sys/class/net/$iface/queues/rx-*/rps_flow_cnt /sys/class/net/$iface/queues/tx-*/xps_cpus /sys/class/net/$iface/queues/tx-*/xps_rxqs; do
    [ -r "$path" ] || continue
    printf '%s=%s\n' "$path" "$(cat "$path")"
    found=1
  done
  [ "$found" -eq 1 ] || echo '[unavailable]'
}
section_netdev_selected() {
  [ "$valid_iface" -eq 1 ] || { echo '[unavailable]'; return; }
  awk -v wanted="$iface" '$1 == wanted ":" { print }' /proc/net/dev 2>/dev/null || true
}
section_network_irq() {
  [ "$valid_iface" -eq 1 ] || { echo '[unavailable]'; return; }
  dev=/sys/class/net/$iface/device
  [ -e "$dev" ] || { echo '[no device symlink]'; return; }
  printf 'device_path=%s\n' "$(readlink -f "$dev" 2>/dev/null || readlink "$dev" 2>/dev/null || echo unknown)"
  printf 'driver=%s\n' "$(readlink -f "$dev/driver" 2>/dev/null || readlink "$dev/driver" 2>/dev/null || echo unknown)"
  if [ -r "$dev/irq" ]; then printf 'irq=%s\tsource=device/irq\n' "$(cat "$dev/irq")"; fi
  for path in "$dev"/msi_irqs/*; do
    [ -e "$path" ] || continue
    irq=${path##*/}
    case "$irq" in ''|*[!0-9]*) continue ;; esac
    printf 'irq=%s\tsource=msi_irqs\n' "$irq"
  done
}
section_wifi() {
  if command -v iw >/dev/null 2>&1; then
    echo '--- iw dev ---'
    iw dev 2>&1 || true
    if [ "$valid_iface" -eq 1 ]; then
      echo "--- iw dev $iface station dump ---"
      iw dev "$iface" station dump 2>&1 || true
    fi
  fi
  if [ "$valid_iface" -eq 1 ] && command -v hostapd_cli >/dev/null 2>&1; then
    echo "--- hostapd_cli -i $iface get_status ---"
    hostapd_cli -i "$iface" get_status 2>&1 || true
  fi
  if [ "$valid_iface" -eq 1 ] && command -v iwinfo >/dev/null 2>&1; then
    echo "--- iwinfo $iface info ---"
    iwinfo "$iface" info 2>&1 || true
    echo "--- iwinfo $iface assoclist ---"
    iwinfo "$iface" assoclist 2>&1 || true
  fi
}
printf 'snapshot_label=%s\nselected_interface=%s\n' "$label" "${iface:-unknown}"
section_file proc_stat /proc/stat
section_file interrupts /proc/interrupts
section_file softirqs /proc/softirqs
section_file softnet_stat /proc/net/softnet_stat
section_file netdev /proc/net/dev
printf '@@BEGIN cpu_online_list@@\n'; section_online; printf '@@END cpu_online_list@@\n'
printf '@@BEGIN cpu_frequency@@\n'; section_cpu_frequency; printf '@@END cpu_frequency@@\n'
printf '@@BEGIN thermal@@\n'; section_thermal; printf '@@END thermal@@\n'
printf '@@BEGIN sysctls@@\n'; section_sysctls; printf '@@END sysctls@@\n'
printf '@@BEGIN netdev_selected@@\n'; section_netdev_selected; printf '@@END netdev_selected@@\n'
printf '@@BEGIN queues@@\n'; section_queues; printf '@@END queues@@\n'
printf '@@BEGIN network_irq@@\n'; section_network_irq; printf '@@END network_irq@@\n'
printf '@@BEGIN wifi_telemetry@@\n'; section_wifi; printf '@@END wifi_telemetry@@\n'
REMOTE_SNAPSHOT
}

capture_snapshot() {
  local label=$1
  LAST_SNAPSHOT_FILE=$RUN_DIR/$label.raw
  say "capturing Air6 snapshot: $label"
  if ! remote_snapshot "$label" "$SELECTED_IFACE" > "$LAST_SNAPSHOT_FILE"; then
    die "failed to capture Air6 snapshot: $label"
  fi
}

extract_section() {
  local raw=$1 section=$2 output=$3
  awk -v start="@@BEGIN $section@@" -v end="@@END $section@@" '
    $0 == start { inside=1; next }
    $0 == end { inside=0 }
    inside { print }
  ' "$raw" > "$output"
}

read_kv() {
  local key=$1 file=$2
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$file"
}

numeric_value() {
  awk -v value="${1:-}" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/) }'
}

material_improvement() {
  numeric_value "$1" && numeric_value "$2" || return 1
  awk -v old="$1" -v new="$2" 'BEGIN { exit !(new > old * 1.10 && new - old >= 20) }'
}

analyze_snapshot_pair() {
  local label=$1 before_raw=$2 after_raw=$3 pair_dir parser_status=0
  pair_dir=$RUN_DIR/$label.analysis
  mkdir -p "$pair_dir"
  for section in proc_stat interrupts softirqs softnet_stat netdev_selected queues cpu_online_list cpu_frequency thermal sysctls network_irq wifi_telemetry; do
    extract_section "$before_raw" "$section" "$pair_dir/before.$section"
    extract_section "$after_raw" "$section" "$pair_dir/after.$section"
  done
  if ! parse_proc_stat_delta "$pair_dir/before.proc_stat" "$pair_dir/after.proc_stat" > "$pair_dir/cpu.delta"; then
    echo '[parser failure] /proc/stat delta; raw snapshots were preserved'
    parser_status=1
  fi
  if ! parse_softirq_delta "$pair_dir/before.softirqs" "$pair_dir/after.softirqs" > "$pair_dir/softirq.delta"; then
    echo '[parser failure] /proc/softirqs delta; raw snapshots were preserved'
    parser_status=1
  fi
  if ! parse_softnet_delta "$pair_dir/before.softnet_stat" "$pair_dir/after.softnet_stat" > "$pair_dir/softnet.delta"; then
    echo '[parser failure] /proc/net/softnet_stat delta; raw snapshots were preserved'
    parser_status=1
  fi
  if ! parse_irq_deltas "$pair_dir/before.interrupts" "$pair_dir/after.interrupts" > "$pair_dir/irq.delta"; then
    echo '[parser failure] /proc/interrupts delta; raw snapshots were preserved'
    parser_status=1
  fi
  LAST_HOT_CPU=$(awk -F= '$1 == "hottest_cpu" { print $2; exit }' "$pair_dir/cpu.delta")
  LAST_NET_RX=$(read_kv NET_RX_total_delta "$pair_dir/softirq.delta")
  LAST_NET_TX=$(read_kv NET_TX_total_delta "$pair_dir/softirq.delta")
  LAST_SOFTNET_DROP=$(awk -F= '$1 ~ /dropped_delta$/ { total += $2 } END { if (NR) print total; else print "unknown" }' "$pair_dir/softnet.delta")
  LAST_SOFTNET_SQUEEZE=$(awk -F= '$1 ~ /time_squeeze_delta$/ { total += $2 } END { if (NR) print total; else print "unknown" }' "$pair_dir/softnet.delta")
  [ -n "$LAST_NET_RX" ] || LAST_NET_RX=unknown
  [ -n "$LAST_NET_TX" ] || LAST_NET_TX=unknown
  [ -n "$LAST_HOT_CPU" ] || LAST_HOT_CPU=unknown
  [ -n "$LAST_SOFTNET_DROP" ] || LAST_SOFTNET_DROP=unknown
  [ -n "$LAST_SOFTNET_SQUEEZE" ] || LAST_SOFTNET_SQUEEZE=unknown
  echo "=== $label diagnostic deltas ==="
  echo "hottest CPU: $LAST_HOT_CPU"
  echo "softnet dropped delta: $LAST_SOFTNET_DROP"
  echo "softnet time_squeeze delta: $LAST_SOFTNET_SQUEEZE"
  echo "NET_RX delta: $LAST_NET_RX"
  echo "NET_TX delta: $LAST_NET_TX"
  cat "$pair_dir/cpu.delta"
  echo 'IRQ deltas:'
  cat "$pair_dir/irq.delta"
  echo "raw/parsed files: $pair_dir"
  return "$parser_status"
}

remote_bridge_candidates() {
  remote_script "$SBAIR_IPERF_BRIDGE" <<'REMOTE_CANDIDATES' || die 'failed to enumerate br-lan members and Wi-Fi candidates'
set -u
bridge=$1
case "$bridge" in ''|*[!A-Za-z0-9_.:-]*) echo '[ERROR] invalid bridge name' >&2; exit 1 ;; esac
[ -d "/sys/class/net/$bridge" ] || { echo "[ERROR] bridge not found: $bridge" >&2; exit 1; }
members=0
for path in /sys/class/net/$bridge/brif/*; do
  [ -e "$path" ] || continue
  iface=${path##*/}
  printf 'member\t%s\n' "$iface"
  members=1
  reason=
  [ -d "/sys/class/net/$iface/wireless" ] && reason=sysfs-wireless
  if command -v iw >/dev/null 2>&1 && iw dev "$iface" info 2>/dev/null | grep -Eq '(^|[[:space:]])type AP([[:space:]]|$)'; then
    [ -n "$reason" ] && reason="$reason,iw-ap" || reason=iw-ap
  fi
  [ -n "$reason" ] && printf 'candidate\t%s\t%s\n' "$iface" "$reason"
done
[ "$members" -eq 1 ] || echo '[no bridge members]'
REMOTE_CANDIDATES
}

remote_probe_stats() {
  remote_script "$SBAIR_IPERF_BRIDGE" <<'REMOTE_PROBE_STATS'
set -u
bridge=$1
for path in /sys/class/net/$bridge/brif/*; do
  [ -e "$path" ] || continue
  iface=${path##*/}
  case "$iface" in ''|*[!A-Za-z0-9_.:-]*) continue ;; esac
  line=$(awk -v wanted="$iface" '$1 == wanted ":" { print; exit }' /proc/net/dev 2>/dev/null || true)
  [ -n "$line" ] || continue
  set -- $line
  printf '%s\t%s\t%s\n' "$iface" "$2" "${10}"
done
REMOTE_PROBE_STATS
}

select_probe_interface() {
  local before=$1 after=$2 selected count max second iface delta
  selected=
  count=0
  max=-1
  second=-1
  while IFS='	' read -r iface delta; do
    [ -n "$iface" ] || continue
    case "$delta" in ''|*[!0-9]*) continue ;; esac
    if [ "$delta" -gt "$max" ]; then second=$max; max=$delta; selected=$iface
    elif [ "$delta" -gt "$second" ]; then second=$delta
    fi
    count=$((count + 1))
  done < <(awk -F '	' 'NR == FNR { before[$1] = $2; next } { if ($1 in before) print $1 "\t" ($2 - before[$1]) }' "$before" "$after")
  echo 'interface probe deltas (Air6 ingress rx_bytes):'
  awk -F '	' 'NR == FNR { before[$1] = $2; next } { if ($1 in before) printf "  %s rx_bytes_delta=%s\n", $1, $2 - before[$1] }' "$before" "$after"
  if [ "$count" -eq 0 ] || [ "$max" -le 0 ]; then
    INTERFACE_DECISION='ambiguous: no positive ingress delta'
    SELECTED_IFACE=
    return 0
  fi
  if [ "$second" -ge 0 ] && [ "$max" -eq "$second" ]; then
    INTERFACE_DECISION="ambiguous: tied ingress delta ($max bytes)"
    SELECTED_IFACE=
    return 0
  fi
  SELECTED_IFACE=$selected
  INTERFACE_DECISION="selected by largest ingress rx_bytes delta ($max bytes)"
}

discover_interface() {
  local raw candidate_file candidates candidate_count
  raw=$RUN_DIR/interface-discovery.txt
  remote_bridge_candidates > "$raw"
  echo '=== dynamic Wi-Fi interface discovery ==='
  cat "$raw"
  candidate_file=$RUN_DIR/wifi-candidates.tsv
  awk -F '	' '$1 == "candidate" && !seen[$2]++ { print $2 "\t" $3 }' "$raw" > "$candidate_file"
  candidate_count=$(awk 'NF { n++ } END { print n + 0 }' "$candidate_file")
  if [ "$candidate_count" -eq 1 ]; then
    SELECTED_IFACE=$(awk -F '	' 'NR == 1 { print $1 }' "$candidate_file")
    INTERFACE_DECISION='selected from an existing bridge member with sysfs/iw AP evidence'
    echo "selected Wi-Fi interface: $SELECTED_IFACE ($INTERFACE_DECISION)"
    return 0
  fi
  if [ "$candidate_count" -gt 1 ]; then
    echo "multiple Wi-Fi candidates ($candidate_count); running the required ingress probe"
    candidates=$(awk -F '	' '{ print "candidate\t" $0 }' "$candidate_file")
  else
    echo 'no reliable Wi-Fi candidate was exposed by sysfs/iw; probing bridge members for evidence only'
    candidates=$(awk -F '	' '$1 == "member" { print }' "$raw")
  fi
  [ -n "$candidates" ] || { INTERFACE_DECISION='ambiguous: bridge has no usable members'; SELECTED_IFACE=; return 0; }
  remote_setup_test
  local probe_before=$RUN_DIR/interface-probe.before.tsv probe_after=$RUN_DIR/interface-probe.after.tsv probe_output=$RUN_DIR/interface-probe.iperf
  remote_probe_stats > "$probe_before"
  if ! iperf3 -c "$AIR6_HOST" -p 5201 -f m -t 2 > "$probe_output" 2>&1; then
    echo '[WARN] interface probe traffic failed; raw output follows:'
    cat "$probe_output"
  fi
  remote_probe_stats > "$probe_after"
  select_probe_interface "$probe_before" "$probe_after"
  if [ -n "$SELECTED_IFACE" ]; then
    if ! awk -F '	' -v wanted="$SELECTED_IFACE" '$1 == wanted { found=1; exit } END { exit !found }' "$candidate_file"; then
      INTERFACE_DECISION="${INTERFACE_DECISION}; selected member lacks independent Wi-Fi evidence, tuning disabled"
      SELECTED_IFACE=
    fi
  fi
  echo "selected Wi-Fi interface: ${SELECTED_IFACE:-unknown} ($INTERFACE_DECISION)"
}

create_tuning_snapshot() {
  local iface=${1:-}
  remote_script "$REMOTE_TUNING_PATH" "$iface" <<'REMOTE_TUNING_SNAPSHOT'
set -eu
state=$1
iface=${2:-}
case "$state" in /tmp/sbair-iperf3-tuning.snapshot) : ;; *) echo '[ERROR] invalid tuning snapshot path' >&2; exit 1 ;; esac
case "$iface" in *[!A-Za-z0-9_.:-]*) echo '[ERROR] invalid interface in tuning snapshot' >&2; exit 1 ;; esac
[ ! -e "$state" ] && [ ! -L "$state" ] || { echo "[ERROR] outstanding tuning snapshot exists: $state" >&2; exit 1; }
umask 077
: > "$state"
printf 'version\t1\n' >> "$state"
for path in /sys/class/net/$iface/queues/rx-*/rps_cpus; do
  [ -r "$path" ] || continue
  printf 'rps\t%s\t%s\n' "$path" "$(cat "$path")" >> "$state"
done
path=/proc/sys/net/core/netdev_max_backlog
[ -r "$path" ] && printf 'sysctl\t%s\t%s\n' "$path" "$(cat "$path")" >> "$state"
chmod 600 "$state"
REMOTE_TUNING_SNAPSHOT
}

rollback_remote() {
  remote_script "$REMOTE_TUNING_PATH" <<'REMOTE_ROLLBACK'
set -u
state=$1
[ -f "$state" ] || { echo '[INFO] no outstanding Air6 tuning snapshot'; exit 0; }
status=0
while IFS='	' read -r kind path value; do
  case "$kind:$path" in
    rps:/sys/class/net/*/queues/rx-*/rps_cpus|irq:/proc/irq/*/smp_affinity|irq:/proc/irq/*/smp_affinity_list)
      case "$value" in ''|*[!A-Za-z0-9,_-]*) echo "[ERROR] invalid saved value for $path" >&2; status=1; continue ;; esac
      actual=$(cat "$path" 2>/dev/null || echo __unreadable__)
      if [ "$actual" = "$value" ]; then
        echo "[OK] already restored $path=$actual"
        continue
      fi
      if ! printf '%s\n' "$value" > "$path" 2>/dev/null; then echo "[ERROR] restore write failed: $path" >&2; status=1; continue; fi
      actual=$(cat "$path" 2>/dev/null || echo __unreadable__)
      if [ "$actual" = "$value" ]; then echo "[OK] restored $path=$actual"; else echo "[ERROR] restore mismatch $path expected=$value actual=$actual" >&2; status=1; fi
      ;;
    sysctl:/proc/sys/net/core/netdev_max_backlog)
      case "$value" in ''|*[!0-9]*) echo "[ERROR] invalid saved value for $path" >&2; status=1; continue ;; esac
      actual=$(cat "$path" 2>/dev/null || echo __unreadable__)
      if [ "$actual" = "$value" ]; then
        echo "[OK] already restored net.core.netdev_max_backlog=$actual"
        continue
      fi
      if ! printf '%s\n' "$value" > "$path" 2>/dev/null; then echo "[ERROR] restore write failed: $path" >&2; status=1; continue; fi
      actual=$(cat "$path" 2>/dev/null || echo __unreadable__)
      if [ "$actual" = "$value" ]; then echo "[OK] restored net.core.netdev_max_backlog=$actual"; else echo "[ERROR] restore mismatch $path expected=$value actual=$actual" >&2; status=1; fi
      ;;
  esac
done < "$state"
if [ "$status" -eq 0 ]; then
  rm -f "$state"
  echo '[OK] Air6 runtime tuning snapshot restored and removed'
else
  echo '[ERROR] snapshot retained for another rollback attempt' >&2
fi
exit "$status"
REMOTE_ROLLBACK
}

remote_check_rps() {
  local iface=$1
  remote_script "$iface" <<'REMOTE_CHECK_RPS'
set -u
iface=$1
case "$iface" in ''|*[!A-Za-z0-9_.:-]*) exit 1 ;; esac
for path in /sys/devices/system/cpu/cpu[0-9]*; do
  [ -d "$path" ] || continue
  cpu=${path##*/cpu}
  online=1
  if [ -r "$path/online" ] && [ "$(cat "$path/online" 2>/dev/null || echo 0)" = 0 ]; then online=0; fi
  [ "$online" -eq 1 ] && printf 'online_cpu=%s\n' "$cpu"
done
for path in /sys/class/net/$iface/queues/rx-*/rps_cpus; do
  [ -r "$path" ] || continue
  if [ -w "$path" ]; then writable=1; else writable=0; fi
  printf 'rps_queue=%s\twritable=%s\tvalue=%s\n' "$path" "$writable" "$(cat "$path")"
done
REMOTE_CHECK_RPS
}

remote_apply_rps() {
  local iface=$1 exclude=${2:-}
  remote_script "$iface" "$exclude" <<'REMOTE_APPLY_RPS'
set -eu
iface=$1
exclude=${2:-}
case "$iface" in ''|*[!A-Za-z0-9_.:-]*) echo '[ERROR] invalid interface for RPS' >&2; exit 1 ;; esac
mask=0
online_count=0
for path in /sys/devices/system/cpu/cpu[0-9]*; do
  [ -d "$path" ] || continue
  cpu=${path##*/cpu}
  online=1
  if [ -r "$path/online" ] && [ "$(cat "$path/online" 2>/dev/null || echo 0)" = 0 ]; then online=0; fi
  [ "$online" -eq 1 ] || continue
  online_count=$((online_count + 1))
  if [ "$cpu" != "$exclude" ]; then mask=$((mask | (1 << cpu))); fi
done
[ "$online_count" -gt 1 ] || { echo '[SKIP] fewer than two CPUs are online'; exit 2; }
[ "$mask" -ne 0 ] || { echo '[SKIP] no online CPU remains after excluding the busy CPU'; exit 2; }
mask_text=$(printf '%x' "$mask")
changed=0
for path in /sys/class/net/$iface/queues/rx-*/rps_cpus; do
  [ -r "$path" ] || continue
  [ -w "$path" ] || continue
  printf '%s\n' "$mask_text" > "$path"
  actual=$(cat "$path")
  normalized=$(printf '%s\n' "$actual" | tr '[:upper:]' '[:lower:]' | sed 's/^0*//')
  [ -n "$normalized" ] || normalized=0
  printf 'rps_applied=%s\treadback=%s\tnormalized=%s\n' "$path" "$actual" "$normalized"
  [ "$normalized" = "$mask_text" ] || { echo "[ERROR] RPS readback mismatch: $path" >&2; exit 1; }
  changed=1
done
[ "$changed" -eq 1 ] || { echo '[SKIP] no writable RX rps_cpus queue exists'; exit 2; }
printf 'rps_mask=%s\n' "$mask_text"
REMOTE_APPLY_RPS
}

remote_apply_backlog() {
  local pressure=$1
  remote_script "$pressure" <<'REMOTE_APPLY_BACKLOG'
set -eu
pressure=$1
path=/proc/sys/net/core/netdev_max_backlog
[ -r "$path" ] || { echo '[SKIP] net.core.netdev_max_backlog is unavailable'; exit 2; }
current=$(cat "$path")
case "$current" in ''|*[!0-9]*) echo '[SKIP] netdev_max_backlog is not numeric'; exit 2 ;; esac
if [ "$current" -ge 5000 ]; then
  echo "backlog_kept=$current (already >= 5000)"
  exit 0
fi
if [ "$pressure" != 1 ]; then
  echo "[SKIP] baseline showed no softnet drop/time_squeeze pressure (current=$current)"
  exit 2
fi
printf '5000\n' > "$path"
readback=$(cat "$path")
echo "backlog_applied=$readback"
[ "$readback" = 5000 ] || { echo '[ERROR] backlog readback mismatch' >&2; exit 1; }
REMOTE_APPLY_BACKLOG
}

remote_add_irq_snapshot() {
  local irq=$1
  remote_script "$REMOTE_TUNING_PATH" "$irq" <<'REMOTE_IRQ_SNAPSHOT'
set -eu
state=$1
irq=$2
case "$irq" in ''|*[!0-9]*) echo '[ERROR] invalid IRQ number' >&2; exit 1 ;; esac
for path in /proc/irq/$irq/smp_affinity_list /proc/irq/$irq/smp_affinity; do
  if [ -w "$path" ] && [ -r "$path" ]; then
    if ! grep -Eq '^irq[[:space:]]' "$state" 2>/dev/null; then printf 'irq\t%s\t%s\n' "$path" "$(cat "$path")" >> "$state"; fi
    printf 'irq_write_path=%s\toriginal=%s\n' "$path" "$(cat "$path")"
    exit 0
  fi
done
echo '[SKIP] no writable IRQ affinity interface' >&2
exit 2
REMOTE_IRQ_SNAPSHOT
}

remote_restore_irq_only() {
  remote_script "$REMOTE_TUNING_PATH" <<'REMOTE_RESTORE_IRQ'
set -u
state=$1
status=0
while IFS='	' read -r kind path value; do
  [ "$kind" = irq ] || continue
  if ! printf '%s\n' "$value" > "$path" 2>/dev/null; then status=1; continue; fi
  [ "$(cat "$path" 2>/dev/null || echo __unreadable__)" = "$value" ] || status=1
done < "$state"
exit "$status"
REMOTE_RESTORE_IRQ
}

remote_apply_irq() {
  local irq=$1 cpu=$2
  remote_script "$irq" "$cpu" <<'REMOTE_APPLY_IRQ'
set -eu
irq=$1
cpu=$2
case "$irq:$cpu" in ''|*[!0-9]*:*|*:[!0-9]*) echo '[ERROR] invalid IRQ/CPU' >&2; exit 1 ;; esac
path=
for candidate in /proc/irq/$irq/smp_affinity_list /proc/irq/$irq/smp_affinity; do
  if [ -w "$candidate" ] && [ -r "$candidate" ]; then path=$candidate; break; fi
done
[ -n "$path" ] || { echo '[SKIP] no writable IRQ affinity interface'; exit 2; }
if [ "${path##*/}" = smp_affinity_list ]; then value=$cpu; else value=$(printf '%x' "$((1 << cpu))"); fi
printf '%s\n' "$value" > "$path"
readback=$(cat "$path")
effective=$(cat "/proc/irq/$irq/effective_affinity_list" 2>/dev/null || echo unavailable)
printf 'irq_applied_path=%s\trequested=%s\treadback=%s\teffective=%s\n' "$path" "$value" "$readback" "$effective"
if [ "${path##*/}" = smp_affinity_list ]; then
  [ "$readback" = "$value" ] || { echo '[SKIP] kernel rewrote IRQ affinity; not treating the change as active' >&2; exit 2; }
else
  expected=$(printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^0*//')
  actual=$(printf '%s\n' "$readback" | tr '[:upper:]' '[:lower:]' | sed 's/^0*//')
  [ -n "$expected" ] || expected=0
  [ -n "$actual" ] || actual=0
  [ "$actual" = "$expected" ] || { echo '[SKIP] kernel rewrote IRQ affinity; not treating the change as active' >&2; exit 2; }
fi
if [ -z "$effective" ] || [ "$effective" = unavailable ]; then
  echo '[SKIP] kernel did not expose effective IRQ affinity' >&2
  exit 2
fi
effective_ok=$(printf '%s\n' "$effective" | awk -v wanted="$cpu" '
  {
    count = split($0, part, ",")
    for (i = 1; i <= count; i++) {
      if (part[i] == wanted) ok = 1
      else if (part[i] ~ /^[0-9]+-[0-9]+$/) {
        split(part[i], range, "-")
        if (wanted >= range[1] && wanted <= range[2]) ok = 1
      }
    }
  }
  END { print ok + 0 }
')
[ "$effective_ok" = 1 ] || { echo '[SKIP] effective IRQ affinity does not contain requested CPU' >&2; exit 2; }
REMOTE_APPLY_IRQ
}

record_result() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "${2:-unknown}" "${3:-unknown}" "${4:-unknown}" "${5:-unknown}" >> "$TABLE_FILE"
}

show_result_table() {
  echo
  echo '=== compact comparison table (receiver throughput, Mbits/sec) ==='
  awk -F '	' 'NR == 1 { next } { printf "%-24s %12s %12s %10s %14s\n", $1, $2, $3, $4, $5 }' "$TABLE_FILE"
  echo 'mode                     Mac->Air6    Air6->Mac      Retr    softnet drop'
  echo '--------------------------------------------------------------------------'
  awk -F '	' 'NR > 1 { printf "%-24s %12s %12s %10s %14s\n", $1, $2, $3, $4, $5 }' "$TABLE_FILE"
}

run_tcp_case() {
  local label=$1 direction=$2 port=$3 output result status=0 extra
  local args=()
  output=$RUN_DIR/$label.iperf
  result=$RUN_DIR/$label.result
  capture_snapshot "$label.before"
  args=(-c "$AIR6_HOST" -p "$port" -P 4 -f m -t "$IPERF_DURATION")
  [ "$direction" = reverse ] && args+=(-R)
  # Extra client flags are passed after the fixed measurement options by the
  # caller through the fourth and later arguments.
  shift 3
  for extra in "$@"; do args+=("$extra"); done
  echo "=== $label ($direction) ==="
  if iperf3 "${args[@]}" > "$output" 2>&1; then :; else status=$?; fi
  capture_snapshot "$label.after"
  analyze_snapshot_pair "$label" "$RUN_DIR/$label.before.raw" "$RUN_DIR/$label.after.raw"
  cat "$output"
  if [ "$status" -ne 0 ]; then
    echo "[ERROR] iperf3 failed for $label (status=$status)" >&2
    return "$status"
  fi
  if parse_tcp_summary "$output" > "$result"; then
    LAST_SENDER=$(read_kv sender_mbits "$result")
    LAST_RECEIVER=$(read_kv receiver_mbits "$result")
    LAST_RETRANS=$(read_kv retrans "$result")
  else
    echo "[WARN] could not safely parse $label; raw output is preserved at $output" >&2
    LAST_SENDER=unknown
    LAST_RECEIVER=unknown
    LAST_RETRANS=unknown
  fi
  LAST_TCP_RESULT=$result
}

run_tcp_independent_case() {
  local label=$1 direction=$2 output result status failed=0 i port pid extra
  local args=()
  local pids=()
  capture_snapshot "$label.before"
  for i in 0 1 2 3; do
    port=$((5211 + i))
    output=$RUN_DIR/$label.$port.iperf
    args=(-c "$AIR6_HOST" -p "$port" -f m -t "$IPERF_DURATION")
    [ "$direction" = reverse ] && args+=(-R)
    echo "starting independent Mac client: TCP/$port ($direction)"
    iperf3 "${args[@]}" > "$output" 2>&1 &
    pids[$i]=$!
  done
  for i in 0 1 2 3; do
    pid=${pids[$i]}
    if wait "$pid"; then :; else status=$?; failed=1; echo "[ERROR] independent client $i failed (status=$status)" >&2; fi
  done
  capture_snapshot "$label.after"
  analyze_snapshot_pair "$label" "$RUN_DIR/$label.before.raw" "$RUN_DIR/$label.after.raw"
  LAST_RECEIVER=unknown
  LAST_SENDER=unknown
  LAST_RETRANS=unknown
  total_receiver=0
  total_retrans=0
  parsed_count=0
  retrans_count=0
  for i in 0 1 2 3; do
    port=$((5211 + i))
    output=$RUN_DIR/$label.$port.iperf
    result=$RUN_DIR/$label.$port.result
    cat "$output"
    if parse_tcp_summary "$output" > "$result"; then
      value=$(read_kv receiver_mbits "$result")
      if numeric_value "$value"; then total_receiver=$(awk -v a="$total_receiver" -v b="$value" 'BEGIN { printf "%.3f", a + b }'); parsed_count=$((parsed_count + 1)); fi
      value=$(read_kv retrans "$result")
      if numeric_value "$value"; then total_retrans=$(awk -v a="$total_retrans" -v b="$value" 'BEGIN { printf "%.0f", a + b }'); retrans_count=$((retrans_count + 1)); fi
    else
      echo "[WARN] could not safely parse $output; raw output is preserved" >&2
    fi
  done
  [ "$parsed_count" -eq 4 ] && LAST_RECEIVER=$total_receiver
  [ "$retrans_count" -eq 4 ] && LAST_RETRANS=$total_retrans
  LAST_TCP_RESULT=$RUN_DIR/$label.aggregate.result
  printf 'receiver_mbits=%s\nretrans=%s\n' "$LAST_RECEIVER" "$LAST_RETRANS" > "$LAST_TCP_RESULT"
  [ "$failed" -eq 0 ] || return 1
}

run_standard_pair() {
  local mode=$1 prefix=$2 up down retrans drop
  run_tcp_case "$prefix-up" normal 5201
  up=$LAST_RECEIVER
  retrans=$LAST_RETRANS
  drop=$LAST_SOFTNET_DROP
  PAIR_HOT_CPU=$LAST_HOT_CPU
  run_tcp_case "$prefix-down" reverse 5201
  down=$LAST_RECEIVER
  if numeric_value "$retrans" && numeric_value "$LAST_RETRANS"; then retrans=$(awk -v a="$retrans" -v b="$LAST_RETRANS" 'BEGIN { printf "%.0f", a + b }'); else retrans=unknown; fi
  record_result "$mode" "$up" "$down" "$retrans" "$drop"
  PAIR_UP=$up
  PAIR_DOWN=$down
  PAIR_RETRANS=$retrans
  PAIR_DROP=$drop
}

run_process_comparison() {
  echo '=== mandatory single-process versus independent-process comparison ==='
  run_standard_pair 'baseline (-P4)' tcp-p4
  P4_UP=$PAIR_UP
  P4_DOWN=$PAIR_DOWN
  P4_RETRANS=$PAIR_RETRANS
  P4_DROP=$PAIR_DROP
  P4_HOT_CPU=$PAIR_HOT_CPU
  run_tcp_independent_case independent-up normal
  INDEPENDENT_UP=$LAST_RECEIVER
  independent_up_retrans=$LAST_RETRANS
  run_tcp_independent_case independent-down reverse
  INDEPENDENT_DOWN=$LAST_RECEIVER
  if numeric_value "$independent_up_retrans" && numeric_value "$LAST_RETRANS"; then independent_retrans=$(awk -v a="$independent_up_retrans" -v b="$LAST_RETRANS" 'BEGIN { printf "%.0f", a + b }'); else independent_retrans=unknown; fi
  record_result '4 independent proc' "$INDEPENDENT_UP" "$INDEPENDENT_DOWN" "$independent_retrans" "$LAST_SOFTNET_DROP"
  if material_improvement "$P4_UP" "$INDEPENDENT_UP" || material_improvement "$P4_DOWN" "$INDEPENDENT_DOWN"; then
    echo '[CLASSIFICATION] IPERF_SINGLE_PROCESS_LIMIT: independent processes materially outperform -P4'
    echo '[NOTE] This does not prove that Wi-Fi itself is limited to the original speed.'
  else
    echo '[EVIDENCE] independent processes did not materially outperform -P4'
  fi
}

run_udp_case() {
  local label=$1 direction=$2 rate=$3 output result status=0
  local args=(-c "$AIR6_HOST" -p 5201 -u -b "$rate" -f m -t "$IPERF_UDP_DURATION")
  output=$RUN_DIR/$label.iperf
  result=$RUN_DIR/$label.result
  capture_snapshot "$label.before"
  [ "$direction" = reverse ] && args+=(-R)
  echo "=== UDP $direction requested=$rate ==="
  if iperf3 "${args[@]}" > "$output" 2>&1; then :; else status=$?; fi
  capture_snapshot "$label.after"
  analyze_snapshot_pair "$label" "$RUN_DIR/$label.before.raw" "$RUN_DIR/$label.after.raw"
  cat "$output"
  if [ "$status" -ne 0 ]; then
    echo "[ERROR] iperf3 UDP failed for $label (status=$status)" >&2
    return "$status"
  fi
  if parse_udp_summary "$output" > "$result"; then
    sender=$(read_kv sender_mbits "$result")
    receiver=$(read_kv receiver_mbits "$result")
    lost=$(read_kv receiver_lost "$result")
    total=$(read_kv receiver_total "$result")
    loss=$(read_kv receiver_loss_pct "$result")
    jitter=$(read_kv receiver_jitter_ms "$result")
    [ -n "$sender" ] || sender=unknown
    [ -n "$receiver" ] || receiver=unknown
    [ -n "$lost" ] || lost=unknown
    [ -n "$total" ] || total=unknown
    [ -n "$loss" ] || loss=unknown
    [ -n "$jitter" ] || jitter=unknown
    echo "UDP result: requested=$rate sender=$sender Mbits/sec receiver=$receiver Mbits/sec receiver_lost=$lost receiver_total=$total receiver_loss=$loss% receiver_jitter=$jitter ms"
    if numeric_value "$loss" && awk -v loss="$loss" 'BEGIN { exit !(loss > 0) }'; then
      if [ "$direction" = reverse ]; then
        [ -n "${UDP_FIRST_REVERSE_LOSS:-}" ] || UDP_FIRST_REVERSE_LOSS="$rate ($loss%)"
      else
        [ -n "${UDP_FIRST_FORWARD_LOSS:-}" ] || UDP_FIRST_FORWARD_LOSS="$rate ($loss%)"
      fi
    fi
  else
    echo "[WARN] could not safely parse UDP result; raw output is preserved at $output" >&2
  fi
}

run_udp_sweep() {
  local rate
  UDP_FIRST_FORWARD_LOSS=
  UDP_FIRST_REVERSE_LOSS=
  echo '=== UDP receiver-authoritative rate sweep ==='
  echo 'The receiver summary, not the sender summary, determines loss.'
  for rate in 100M 200M 300M 400M 500M 600M 800M 1000M; do
    run_udp_case "udp-forward-${rate%M}" forward "$rate"
  done
  for rate in 100M 200M 300M 400M 500M 600M 800M 1000M; do
    run_udp_case "udp-reverse-${rate%M}" reverse "$rate"
  done
  echo "first receiver loss > 0% (Mac -> Air6): ${UDP_FIRST_FORWARD_LOSS:-none observed/parse unavailable}"
  echo "first receiver loss > 0% (Air6 -> Mac): ${UDP_FIRST_REVERSE_LOSS:-none observed/parse unavailable}"
}

run_zerocopy_tests() {
  if ! iperf3 -h 2>&1 | grep -Eq '(^|[[:space:]])-Z([,[:space:]]|$)|--zerocopy'; then
    echo '[SKIP] Air6/Mac iperf3 help did not advertise -Z/--zerocopy'
    return 0
  fi
  echo '[INFO] iperf3 zerocopy option is available; running a temporary comparison'
  if run_tcp_case zerocopy-up normal 5201 -Z; then
    ZC_UP=$LAST_RECEIVER
    ZC_UP_RETRANS=$LAST_RETRANS
  else
    echo '[WARN] zerocopy Mac -> Air6 failed; continuing without treating it as evidence'
    ZC_UP=unknown
    ZC_UP_RETRANS=unknown
  fi
  if run_tcp_case zerocopy-down reverse 5201 -Z; then
    ZC_DOWN=$LAST_RECEIVER
    ZC_DOWN_RETRANS=$LAST_RETRANS
  else
    echo '[WARN] zerocopy Air6 -> Mac failed; continuing without treating it as evidence'
    ZC_DOWN=unknown
    ZC_DOWN_RETRANS=unknown
  fi
  record_result 'zerocopy (-Z)' "$ZC_UP" "$ZC_DOWN" unknown unknown
  if material_improvement "$P4_DOWN" "$ZC_DOWN" || material_improvement "$P4_UP" "$ZC_UP"; then
    echo '[CLASSIFICATION] USERSPACE_KERNEL_COPY_COST: zerocopy materially improved throughput'
  else
    echo '[EVIDENCE] zerocopy did not materially improve the measured directions'
  fi
}

run_reference_case() {
  local label=$1 direction=$2 output result status=0
  local args=(-c "$REFERENCE_HOST" -p 5201 -P 4 -f m -t "$IPERF_DURATION")
  output=$RUN_DIR/$label.iperf
  result=$RUN_DIR/$label.result
  capture_snapshot "$label.before"
  [ "$direction" = reverse ] && args+=(-R)
  echo "=== optional external reference $direction ($REFERENCE_HOST) ==="
  if iperf3 "${args[@]}" > "$output" 2>&1; then :; else status=$?; fi
  capture_snapshot "$label.after"
  analyze_snapshot_pair "$label" "$RUN_DIR/$label.before.raw" "$RUN_DIR/$label.after.raw"
  cat "$output"
  if [ "$status" -ne 0 ]; then
    echo "[WARN] optional reference benchmark failed (status=$status); raw output is preserved" >&2
    return 0
  fi
  if parse_tcp_summary "$output" > "$result"; then
    reference_receiver=$(read_kv receiver_mbits "$result")
    echo "reference receiver throughput: $reference_receiver Mbits/sec"
    [ "$direction" = reverse ] && REFERENCE_DOWN=$reference_receiver || REFERENCE_UP=$reference_receiver
  else
    echo '[WARN] optional reference result could not be parsed; raw output is preserved' >&2
  fi
}

discover_irq_from_baseline() {
  local pair_dir=$RUN_DIR/tcp-p4-up.analysis candidates candidate line irq delta max second label percpu concentration
  IRQ_NUMBER=
  IRQ_HOT_CPU=
  IRQ_TARGET_CPU=
  IRQ_CAN_TUNE=0
  [ -d "$pair_dir" ] || { echo '[SKIP] no baseline analysis is available for IRQ discovery'; return 0; }
  candidates=$RUN_DIR/irq-candidates.tsv
  : > "$candidates"
  awk -F '	' '$1 ~ /^irq=/ { sub(/^irq=/, "", $1); print $1 }' "$pair_dir/before.network_irq" | sort -nu > "$RUN_DIR/irq-numbers"
  while IFS= read -r irq; do
    [ -n "$irq" ] || continue
    line=$(awk -v wanted="irq=$irq" '$1 == wanted { print; exit }' "$pair_dir/irq.delta")
    [ -n "$line" ] || continue
    delta=$(printf '%s\n' "$line" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^delta=/) { sub(/^delta=/, "", $i); print $i; exit } }')
    case "$delta" in ''|*[!0-9]*) continue ;; esac
    [ "$delta" -ge 100 ] || continue
    label=$(printf '%s\n' "$line" | sed 's/.* label=//;s/ percpu_delta=.*//')
    percpu=$(printf '%s\n' "$line" | sed 's/.* percpu_delta=//')
    if printf '%s\n' "$label" | grep -Eiq 'timer|ipi|arch_timer|hrtimer|rescheduling|function_call|tlb|pmu'; then continue; fi
    case "$label" in *,*) continue ;; esac
    printf '%s\t%s\t%s\t%s\n' "$irq" "$delta" "$label" "$percpu" >> "$candidates"
  done < "$RUN_DIR/irq-numbers"
  echo 'high-confidence IRQ candidates (direct interface IRQ correlation plus traffic delta):'
  cat "$candidates"
  [ -s "$candidates" ] || { echo '[SKIP] no directly correlated network/Wi-Fi IRQ rose substantially'; return 0; }
  max=$(awk -F '	' 'BEGIN { m=-1 } { if ($2 > m) m=$2 } END { print m }' "$candidates")
  second=$(awk -F '	' -v max="$max" 'BEGIN { m=-1 } { if ($2 < max && $2 > m) m=$2 } END { print m }' "$candidates")
  if [ "$second" -ge 0 ] && [ "$max" -lt $((second * 2)) ]; then
    echo '[SKIP] multiple network IRQs have similar deltas; IRQ affinity is ambiguous'
    return 0
  fi
  line=$(awk -F '	' -v max="$max" '$2 == max { print; exit }' "$candidates")
  IRQ_NUMBER=$(printf '%s\n' "$line" | awk -F '	' '{ print $1 }')
  IRQ_TOTAL_DELTA=$(printf '%s\n' "$line" | awk -F '	' '{ print $2 }')
  IRQ_LABEL=$(printf '%s\n' "$line" | awk -F '	' '{ print $3 }')
  IRQ_PERCPU=$(printf '%s\n' "$line" | awk -F '	' '{ print $4 }')
  IRQ_HOT_CPU=$(awk -F, 'BEGIN { max=-1; cpu="" } { for (i=1; i<=NF; i++) if ($i > max) { max=$i; cpu=i-1 } } END { print cpu }' <<EOF
$IRQ_PERCPU
EOF
)
  concentration=$(awk -F, 'BEGIN { max=-1; total=0 } { for (i=1; i<=NF; i++) { total += $i; if ($i > max) max=$i } } END { if (total > 0) printf "%.1f", 100 * max / total; else print "0.0" }' <<EOF
$IRQ_PERCPU
EOF
)
  echo "selected IRQ concentration: hot CPU handled ${concentration}% of this IRQ delta"
  if awk -v concentration="$concentration" 'BEGIN { exit !(concentration < 60) }'; then
    echo '[SKIP] selected network IRQ is not significantly concentrated on one CPU'
    IRQ_NUMBER=
    IRQ_HOT_CPU=
    return 0
  fi
  echo "selected IRQ: $IRQ_NUMBER label=$IRQ_LABEL delta=$IRQ_TOTAL_DELTA interrupt-hot-CPU=$IRQ_HOT_CPU per-CPU=$IRQ_PERCPU"
  affinity=$(remote_script "$IRQ_NUMBER" <<'REMOTE_IRQ_CHECK'
set -u
irq=$1
for path in /proc/irq/$irq/smp_affinity_list /proc/irq/$irq/smp_affinity; do
  if [ -r "$path" ]; then
    if [ -w "$path" ]; then writable=1; else writable=0; fi
    printf 'path=%s\twritable=%s\tvalue=%s\n' "$path" "$writable" "$(cat "$path")"
  fi
done
for path in /proc/irq/$irq/effective_affinity_list /proc/irq/$irq/effective_affinity; do
  [ -r "$path" ] && printf 'effective=%s\tvalue=%s\n' "$path" "$(cat "$path")"
done
REMOTE_IRQ_CHECK
  ) || { echo '[SKIP] could not inspect selected IRQ affinity'; return 0; }
  echo "$affinity"
  printf '%s\n' "$affinity" | grep -Eq '^path=.*writable=1' || { echo '[SKIP] selected IRQ affinity interface is not writable'; return 0; }
  IRQ_CAN_TUNE=1
}

choose_least_loaded_cpu() {
  local analysis=$1 online=$2 exclude=$3
  awk -v exclude="cpu$exclude" '
    NR == FNR { split($1, online_cpu, "="); if (online_cpu[1] == "cpu") online["cpu" online_cpu[2]] = 1; next }
    $1 ~ /^cpu[0-9]+$/ && ($1 in online) && $1 != exclude {
      busy=""; for (i=1; i<=NF; i++) if ($i ~ /^busy_pct=/) { sub(/^busy_pct=/, "", $i); busy=$i }
      if (busy != "" && (best == "" || busy < best)) { best=busy; selected=substr($1, 4) }
    }
    END { if (selected != "") print selected }
  ' "$online" "$analysis"
}

baseline_pressure() {
  BASELINE_DROP=0
  BASELINE_SQUEEZE=0
  BASELINE_BACKLOG=unknown
  numeric_value "$P4_DROP" && [ "$P4_DROP" -gt 0 ] && BASELINE_DROP=1
  if [ -f "$RUN_DIR/tcp-p4-up.analysis/before.sysctls" ]; then
    BASELINE_BACKLOG=$(read_kv net.core.netdev_max_backlog "$RUN_DIR/tcp-p4-up.analysis/before.sysctls")
    [ -n "$BASELINE_BACKLOG" ] || BASELINE_BACKLOG=unknown
  fi
  if [ -f "$RUN_DIR/tcp-p4-up.analysis/softnet.delta" ]; then
    squeeze=$(awk -F= '$1 ~ /time_squeeze_delta$/ { s += $2 } END { print s + 0 }' "$RUN_DIR/tcp-p4-up.analysis/softnet.delta")
    [ "$squeeze" -gt 0 ] && BASELINE_SQUEEZE=1
  fi
  [ "$BASELINE_DROP" -eq 1 ] || [ "$BASELINE_SQUEEZE" -eq 1 ]
}

run_diagnostic_measurements() {
  run_process_comparison
  baseline_pressure || echo '[EVIDENCE] baseline softnet dropped/time_squeeze did not increase'
  run_zerocopy_tests
  run_udp_sweep
  if [ -n "$REFERENCE_HOST" ]; then
    command -v route >/dev/null 2>&1 && route -n get "$REFERENCE_HOST" || true
    run_reference_case reference-up forward
    run_reference_case reference-down reverse
  fi
}

run_experiment_stages() {
  local rps_info online_count rps_status backlog_status pressure irq_status baseline_online
  echo '=== STAGE 0: baseline ==='
  run_diagnostic_measurements
  if [ -z "$SELECTED_IFACE" ]; then
    echo "[SKIP] RPS/backlog/IRQ tuning: Wi-Fi interface decision is $INTERFACE_DECISION"
    return 0
  fi
  rps_info=$(remote_check_rps "$SELECTED_IFACE") || { echo '[SKIP] RPS: could not inspect RX queue controls'; return 0; }
  echo '=== RPS capability ==='
  echo "$rps_info"
  online_count=$(printf '%s\n' "$rps_info" | awk '/^online_cpu=/{ n++ } END { print n + 0 }')
  if [ "$online_count" -le 1 ] || ! printf '%s\n' "$rps_info" | grep -Eq '^rps_queue=.*writable=1'; then
    echo '[SKIP] RPS: more than one online CPU and a writable RX rps_cpus queue are required'
    return 0
  fi
  baseline_online=$RUN_DIR/tcp-p4-up.analysis/before.cpu_online_list
  exclude=${P4_HOT_CPU:-}
  [ "$exclude" = unknown ] && exclude=
  echo "=== STAGE 1: RPS on $SELECTED_IFACE ==="
  if remote_apply_rps "$SELECTED_IFACE" "$exclude"; then
    run_standard_pair RPS rps
  else
    rps_status=$?
    [ "$rps_status" -eq 2 ] && echo '[SKIP] RPS was not accepted by the target' || die 'RPS experiment failed; rollback will run'
    return 0
  fi
  RPS_UP=$PAIR_UP
  RPS_DOWN=$PAIR_DOWN
  RPS_DROP=$PAIR_DROP
  if baseline_pressure; then pressure=1; else pressure=0; fi
  echo '=== STAGE 2: RPS + backlog ==='
  if remote_apply_backlog "$pressure"; then
    run_standard_pair 'RPS+backlog' rps-backlog
    BACKLOG_UP=$PAIR_UP
    BACKLOG_DOWN=$PAIR_DOWN
    BACKLOG_DROP=$PAIR_DROP
  else
    backlog_status=$?
    if [ "$backlog_status" -eq 2 ]; then
      echo '[SKIP] backlog stage was not applicable; keeping only the RPS stage'
    else
      die 'backlog experiment failed; rollback will run'
    fi
  fi
  discover_irq_from_baseline
  if [ "$IRQ_CAN_TUNE" -ne 1 ]; then
    IRQ_TARGET_CPU=
    echo '[SKIP] STAGE 3 IRQ affinity: no high-confidence writable network/Wi-Fi IRQ'
    return 0
  fi
  baseline_online=$RUN_DIR/tcp-p4-up.analysis/before.cpu_online_list
  IRQ_TARGET_CPU=$(choose_least_loaded_cpu "$RUN_DIR/tcp-p4-up.analysis/cpu.delta" "$baseline_online" "$IRQ_HOT_CPU")
  if [ -z "$IRQ_TARGET_CPU" ]; then
    echo '[SKIP] STAGE 3 IRQ affinity: no other online CPU was a reasonable target'
    return 0
  fi
  echo "=== STAGE 3: RPS + backlog + IRQ affinity ($IRQ_NUMBER -> CPU$IRQ_TARGET_CPU) ==="
  if remote_add_irq_snapshot "$IRQ_NUMBER"; then :; else
    irq_status=$?
    if [ "$irq_status" -eq 2 ]; then
      IRQ_TARGET_CPU=
      echo '[SKIP] IRQ affinity snapshot could not be extended'
    else
      die 'IRQ affinity snapshot failed; rollback will run'
    fi
    return 0
  fi
  if remote_apply_irq "$IRQ_NUMBER" "$IRQ_TARGET_CPU"; then
    run_standard_pair '+IRQ affinity' rps-backlog-irq
  else
    irq_status=$?
    remote_restore_irq_only || die 'IRQ affinity refusal could not be restored; run rollback explicitly'
    if [ "$irq_status" -eq 2 ]; then
      IRQ_TARGET_CPU=
      echo '[SKIP] IRQ affinity was refused/rewritten; it was not treated as active'
    else
      die 'IRQ affinity experiment failed; rollback will run'
    fi
  fi
}

report_classification() {
  local found=0 baseline_hot_busy
  echo '=== evidence-based classification ==='
  if material_improvement "${P4_UP:-unknown}" "${INDEPENDENT_UP:-unknown}" || material_improvement "${P4_DOWN:-unknown}" "${INDEPENDENT_DOWN:-unknown}"; then
    echo 'IPERF_SINGLE_PROCESS_LIMIT: independent Air6 server processes materially outperformed one -P4 server process.'
    found=1
  fi
  if material_improvement "${P4_UP:-unknown}" "${RPS_UP:-unknown}" && numeric_value "${P4_DROP:-unknown}" && numeric_value "${RPS_DROP:-unknown}" && [ "$RPS_DROP" -lt "$P4_DROP" ]; then
    echo 'RX_CPU_STEERING_LIMIT: RPS improved Mac -> Air6 with lower softnet drops.'
    found=1
  fi
  if [ "${BASELINE_DROP:-0}" -eq 1 ] || [ "${BASELINE_SQUEEZE:-0}" -eq 1 ]; then
    backlog_changed=0
    numeric_value "$BASELINE_BACKLOG" && [ "$BASELINE_BACKLOG" -lt 5000 ] && backlog_changed=1
    if [ "$backlog_changed" -eq 1 ]; then
      if material_improvement "${P4_UP:-unknown}" "${BACKLOG_UP:-unknown}" || { numeric_value "${P4_DROP:-unknown}" && numeric_value "${BACKLOG_DROP:-unknown}" && [ "$BACKLOG_DROP" -lt "$P4_DROP" ]; }; then
        echo 'SOFTNET_BACKLOG_LIMIT: baseline pressure was reduced by the backlog stage with a material or corroborating improvement.'
        found=1
      fi
    fi
  fi
  if [ -n "${IRQ_TARGET_CPU:-}" ] && material_improvement "${P4_UP:-unknown}" "${PAIR_UP:-unknown}"; then
    echo "IRQ_CPU_CONCENTRATION: selected IRQ $IRQ_NUMBER was moved to CPU$IRQ_TARGET_CPU and the staged result improved."
    found=1
  fi
  baseline_hot_busy=$(awk '$1 ~ /^cpu[0-9]+$/ { for (i=1; i<=NF; i++) if ($i ~ /^busy_pct=/) { sub(/^busy_pct=/, "", $i); if ($i > max) max=$i } } END { if (max != "") print max }' "$RUN_DIR/tcp-p4-up.analysis/cpu.delta" 2>/dev/null || true)
  if ! material_improvement "${P4_UP:-unknown}" "${INDEPENDENT_UP:-unknown}" &&
     ! material_improvement "${P4_DOWN:-unknown}" "${INDEPENDENT_DOWN:-unknown}" &&
     [ "${BASELINE_DROP:-0}" -eq 0 ] && [ "${BASELINE_SQUEEZE:-0}" -eq 0 ] &&
     numeric_value "$baseline_hot_busy" && awk -v busy="$baseline_hot_busy" 'BEGIN { exit !(busy < 80) }'; then
    echo 'WIFI_DRIVER_OR_MAC_LIMIT: baseline CPU/softnet pressure was absent and independent iperf3 processes did not improve throughput.'
    found=1
  fi
  if material_improvement "${P4_UP:-unknown}" "${REFERENCE_UP:-unknown}"; then
    echo 'LOCAL_ENDPOINT_LIMIT: optional external forwarded benchmark exceeded the Air6-local endpoint.'
    found=1
  fi
  if [ "$found" -eq 0 ]; then
    echo 'INCONCLUSIVE: no classification met the material-improvement/evidence thresholds.'
  fi
  echo 'Air6-local iperf path is Mac Wi-Fi -> Air6 kernel -> Air6 iperf3 userspace; it is not the maximum AP forwarding path.'
  echo 'No Wi-Fi settings, persistent sysctl, init script, firewall configuration, or reboot was used by the experiment.'
}

diagnose_command() {
  require_command iperf3
  check_ssh
  preflight
  make_run_dir
  discover_interface
  [ "$TEST_SETUP_ACTIVE" -eq 1 ] || remote_setup_test
  capture_snapshot diagnose.initial
  run_diagnostic_measurements
  cleanup_test_setup || die 'temporary diagnostic cleanup failed; inspect Air6 temporary run state'
  show_result_table
  echo "selected Wi-Fi interface: ${SELECTED_IFACE:-unknown} ($INTERFACE_DECISION)"
  echo "Mac-side raw diagnostic artifacts: $RUN_DIR"
  report_classification
}

experiment_command() {
  local rollback_status=0 cleanup_status=0
  require_command iperf3
  check_ssh
  preflight
  make_run_dir
  discover_interface
  # This is the complete runtime snapshot before any tuning write. The only
  # earlier write possible in the ambiguous-interface fallback is temporary
  # iperf firewall/server setup needed to identify the ingress netdev.
  capture_snapshot experiment.initial
  create_tuning_snapshot "$SELECTED_IFACE"
  EXPERIMENT_ACTIVE=1
  [ "$TEST_SETUP_ACTIVE" -eq 1 ] || remote_setup_test
  run_experiment_stages
  echo '=== automatic rollback ==='
  if rollback_remote; then
    EXPERIMENT_ACTIVE=0
    echo '[OK] exact original runtime tuning values were restored'
  else
    rollback_status=$?
    echo '[ERROR] automatic rollback failed; run rollback explicitly' >&2
  fi
  cleanup_test_setup || cleanup_status=1
  show_result_table
  echo "selected Wi-Fi interface: ${SELECTED_IFACE:-unknown} ($INTERFACE_DECISION)"
  echo "Mac-side raw diagnostic artifacts: $RUN_DIR"
  report_classification
  [ "$rollback_status" -eq 0 ] || exit "$rollback_status"
  [ "$cleanup_status" -eq 0 ] || exit "$cleanup_status"
}

rollback_command() {
  check_ssh
  echo '=== restoring outstanding Air6 runtime tuning snapshot ==='
  rollback_remote || die 'rollback failed; the target snapshot was retained for another attempt'
}

case "$COMMAND" in
  install) install_command ;;
  check) check_command ;;
  start) start_command ;;
  stop) stop_command ;;
  test) test_command ;;
  diagnose) diagnose_command ;;
  experiment) experiment_command ;;
  rollback) rollback_command ;;
esac
