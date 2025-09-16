#!/usr/bin/env bash
# install-bt-spoof.sh — optimized, robust installer for bt-mac-spoof
# Usage:
#   sudo ./install-bt-spoof.sh --mac 50:E0:85:65:80:00
#   sudo ./install-bt-spoof.sh --interactive
#   sudo ./install-bt-spoof.sh --dry-run
#   sudo ./install-bt-spoof.sh --status
#   sudo ./install-bt-spoof.sh --restore
#   sudo ./install-bt-spoof.sh --uninstall
#
# Design: safe, atomic, idempotent, minimal dependencies.

set -Eeuo pipefail
IFS=$'\n\t'

# --------- Config paths ----------
HCI="hci0"
SCRIPT_PATH="/usr/local/bin/set-bt-mac.sh"
SERVICE_PATH="/etc/systemd/system/bt-mac-spoof.service"
CONF_PATH="/etc/bt-mac-spoof.conf"
ORIG_DIR="/var/lib/bt-mac-spoof"
ORIG_FILE="${ORIG_DIR}/orig_mac"
JOURNAL_LINES=30
LOCK_FD=9
LOCK_FILE="/var/lock/install-bt-mac.lock"

# --------- Defaults ----------
DEFAULT_MAC="50:E0:85:65:80:00"

# --------- Helpers ----------
log()  { printf '%s\n' "$*"; }
info() { printf '\033[34m[+]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[✗]\033[0m %s\n' "$*"; }

die()  { err "$*"; exit 1; }

# ensure only root runs operations that change system files
ensure_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }

# simple MAC validator
validate_mac() {
  local mac="$1"
  [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

# acquire exclusive lock for whole installer (prevents races)
ensure_lock() {
  # create lock dir
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec {LOCK_FD}>"$LOCK_FILE"
  flock -n "$LOCK_FD" || die "another install process is running"
}

cleanup() {
  # release lock (fd closed automatically on exit), remove temps if any
  true
}
trap cleanup EXIT

# atomic write helper using mktemp + install
atomic_write() {
  local dest="$1"; shift
  local tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m "$@" "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# write file helper (mode as 3rd arg)
write_file_atomic() {
  local dest="$1"; local mode="${2:-0644}"
  local tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || die "mktemp failed"
  # caller should feed content via stdin
  cat >"$tmp"
  install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

# show service journal tail
show_journal() {
  journalctl -u bt-mac-spoof.service -n "${JOURNAL_LINES}" --no-pager || true
}

# --------- CLI parse ----------
ACTION="install"  # default action
TARGET_MAC=""
FORCE=0
DRY_RUN=0
INTERACTIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --mac) TARGET_MAC="$2"; shift 2;;
    --mac=*) TARGET_MAC="${1#*=}"; shift;;
    --force|-f) FORCE=1; shift;;
    --dry-run|--test) DRY_RUN=1; shift;;
    --interactive|-i) INTERACTIVE=1; shift;;
    --uninstall) ACTION="uninstall"; shift;;
    --status) ACTION="status"; shift;;
    --restore) ACTION="restore"; shift;;
    -h|--help) cat <<'USAGE'
install-bt-spoof.sh - optimized installer

Usage examples:
  sudo ./install-bt-spoof.sh --mac 50:E0:85:65:80:00
  sudo ./install-bt-spoof.sh --interactive
  sudo ./install-bt-spoof.sh --dry-run
  sudo ./install-bt-spoof.sh --status
  sudo ./install-bt-spoof.sh --restore
  sudo ./install-bt-spoof.sh --uninstall

Flags:
  --mac <MAC>      Set target MAC (format: AA:BB:CC:DD:EE:FF)
  --interactive    Ask for MAC and confirmation
  --dry-run        Show what would be done (no changes)
  --force          Overwrite existing installation without prompt
  --status         Show current install/status
  --restore        Attempt to restore saved original MAC (best-effort)
  --uninstall      Remove installed files (keeps orig_mac unless --force used)
USAGE
      exit 0;;
    *) die "unknown arg: $1";;
  esac
done

# Acquire lock
ensure_lock

# --------- Status action ----------
show_status() {
  log "bt-mac-spoof status"
  printf " Service: %s / %s\n" "$(systemctl is-enabled bt-mac-spoof.service 2>/dev/null || echo disabled)" \
                               "$(systemctl is-active bt-mac-spoof.service 2>/dev/null || echo inactive)"
  printf " Config : %s\n" "[ ${CONF_PATH} ] $( [ -f "${CONF_PATH}" ] && echo exists || echo missing )"
  printf " Script : %s\n" "[ ${SCRIPT_PATH} ] $( [ -f "${SCRIPT_PATH}" ] && echo exists || echo missing )"
  printf " Saved orig: %s\n" "[ ${ORIG_FILE} ] $( [ -f "${ORIG_FILE}" ] && cat "${ORIG_FILE}" 2>/dev/null || echo '(not saved)')"
}

if [ "$ACTION" = "status" ]; then
  show_status
  exit 0
fi

# --------- Restore original MAC (best-effort) ----------
if [ "$ACTION" = "restore" ]; then
  ensure_root
  if [ ! -f "${ORIG_FILE}" ]; then die "no saved original MAC at ${ORIG_FILE}"; fi
  ORIG="$(cat "${ORIG_FILE}")"
  info "Attempting best-effort restore to ${ORIG}"
  hciconfig "${HCI}" down || true
  if command -v btmgmt >/dev/null 2>&1; then
    btmgmt -i "${HCI}" static-addr "${ORIG}" >/dev/null 2>&1 || btmgmt -i "${HCI}" public-addr "${ORIG}" >/dev/null 2>&1 || warn "btmgmt restore failed"
  elif command -v bdaddr >/dev/null 2>&1; then
    bdaddr -i "${HCI}" "${ORIG}" >/dev/null 2>&1 || warn "bdaddr restore failed"
  else
    warn "no tool available to restore automatically; you may need manual steps"
  fi
  hciconfig "${HCI}" up || true
  ok "Restore attempted; check current MAC: hciconfig -a | awk '/BD Address/ {print \$3}'"
  exit 0
fi

# --------- Uninstall ----------
if [ "$ACTION" = "uninstall" ]; then
  ensure_root
  info "Uninstalling bt-mac-spoof (files kept if not present)"
  systemctl stop bt-mac-spoof.service 2>/dev/null || true
  systemctl disable bt-mac-spoof.service 2>/dev/null || true
  rm -f "${SERVICE_PATH}" "${SCRIPT_PATH}" "${CONF_PATH}"
  systemctl daemon-reload
  ok "Uninstalled (original MAC saved at ${ORIG_FILE} unless you delete it)"
  exit 0
fi

# --------- Interactive input ----------
if [ "$INTERACTIVE" -eq 1 ]; then
  # read existing config if present
  if [ -f "${CONF_PATH}" ]; then
    EXISTING="$(grep '^TARGET_MAC=' "${CONF_PATH}" 2>/dev/null | cut -d'=' -f2 | tr -d '"')"
  else
    EXISTING=""
  fi
  default="${EXISTING:-${DEFAULT_MAC}}"
  printf 'Target MAC [%s]: ' "$default"
  read -r input || die "input aborted"
  TARGET_MAC="${input:-$default}"
fi

# If not interactive and no MAC specified => error
if [ -z "${TARGET_MAC:-}" ]; then
  die "no target MAC given; use --mac or --interactive"
fi

# Validate MAC format
if ! validate_mac "$TARGET_MAC"; then
  die "invalid MAC format: ${TARGET_MAC}"
fi

# DRY RUN: show plan and exit
if [ "$DRY_RUN" -eq 1 ]; then
  info "DRY RUN: would create/ensure the following (no changes):"
  echo " - config: ${CONF_PATH}  (TARGET_MAC=${TARGET_MAC})"
  echo " - runtime script: ${SCRIPT_PATH}"
  echo " - systemd unit: ${SERVICE_PATH}"
  echo " - saved original: ${ORIG_FILE} (created on first apply)"
  exit 0
fi

# --------- Install flow ----------
ensure_root

# basic precheck: hciconfig must exist (bluez)
command -v hciconfig >/dev/null 2>&1 || die "hciconfig not found (install package 'bluez')"

# create secure directory for saved original
mkdir -p "${ORIG_DIR}"
chown root:root "${ORIG_DIR}"
chmod 0700 "${ORIG_DIR}"

# 1) write config atomically
info "Writing config -> ${CONF_PATH}"
cat >"${CONF_PATH}.tmp" <<EOF
# bt-mac-spoof config (auto-generated)
TARGET_MAC="${TARGET_MAC}"
HCI="${HCI}"
EOF
install -o root -g root -m 0644 "${CONF_PATH}.tmp" "${CONF_PATH}"
rm -f "${CONF_PATH}.tmp"
ok "Wrote ${CONF_PATH}"

# 2) generate runtime script (atomic)
info "Generating runtime script -> ${SCRIPT_PATH}"
cat >"${SCRIPT_PATH}.tmp" <<'EOF'
#!/usr/bin/env bash
# runtime script (auto-generated by install-bt-spoof.sh)
set -Eeuo pipefail
IFS=$'\n\t'

CONF="/etc/bt-mac-spoof.conf"
ORIG_DIR="/var/lib/bt-mac-spoof"
ORIG_FILE="${ORIG_DIR}/orig_mac"
LOG="[bt-mac-spoof]"

# read config
TARGET_MAC=""
HCI="hci0"
if [ -f "${CONF}" ]; then
  while IFS='=' read -r k v; do
    k=$(echo "$k" | tr -d '[:space:]')
    v=$(echo "$v" | sed -e 's/^"//' -e 's/"$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$k" in
      TARGET_MAC) TARGET_MAC="${v}" ;;
      HCI) HCI="${v}" ;;
    esac
  done < <(grep -E '^\s*[A-Z_]+=.*' "${CONF}" 2>/dev/null || true)
fi

# validate
if [ -z "${TARGET_MAC}" ]; then
  echo "${LOG} TARGET_MAC missing; abort" >&2
  exit 0
fi
if ! [[ "${TARGET_MAC}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
  echo "${LOG} TARGET_MAC invalid: ${TARGET_MAC}" >&2
  exit 0
fi

mkdir -p "${ORIG_DIR}"
chown root:root "${ORIG_DIR}" || true
chmod 0700 "${ORIG_DIR}" || true

# save original once
if [ ! -f "${ORIG_FILE}" ]; then
  ORIG=$(hciconfig "${HCI}" 2>/dev/null | awk '/BD Address/ {print $3}' || true)
  if [ -n "${ORIG}" ]; then
    echo "${ORIG}" > "${ORIG_FILE}" || true
    chmod 0600 "${ORIG_FILE}" || true
    echo "${LOG} saved original ${ORIG}"
  fi
fi

# bring down
echo "${LOG} bringing ${HCI} down"
hciconfig "${HCI}" down || true

# set address: explicit tools preferred
if command -v bdaddr >/dev/null 2>&1; then
  bdaddr -i "${HCI}" "${TARGET_MAC}" >/dev/null 2>&1 || echo "${LOG} bdaddr failed" >&2
elif command -v btmgmt >/dev/null 2>&1; then
  btmgmt -i "${HCI}" static-addr "${TARGET_MAC}" >/dev/null 2>&1 || btmgmt -i "${HCI}" public-addr "${TARGET_MAC}" >/dev/null 2>&1 || echo "${LOG} btmgmt failed" >&2
elif command -v bluemoon >/dev/null 2>&1; then
  bluemoon -A >/dev/null 2>&1 || echo "${LOG} bluemoon failed" >&2
else
  echo "${LOG} no tool to set MAC; bringing up and exiting" >&2
  hciconfig "${HCI}" up || true
  exit 0
fi

# bring up & verify
hciconfig "${HCI}" up || true
CUR=$(hciconfig "${HCI}" 2>/dev/null | awk '/BD Address/ {print $3}' || true)
if [ "${CUR}" = "${TARGET_MAC}" ]; then
  echo "${LOG} applied ${TARGET_MAC}"
else
  echo "${LOG} apply mismatch: current=${CUR} expected=${TARGET_MAC}" >&2
fi
EOF

install -m 0755 "${SCRIPT_PATH}.tmp" "${SCRIPT_PATH}"
rm -f "${SCRIPT_PATH}.tmp"
chown root:root "${SCRIPT_PATH}"
ok "Installed runtime script"

# 3) write systemd unit
info "Writing systemd unit -> ${SERVICE_PATH}"
cat >"${SERVICE_PATH}.tmp" <<EOF
[Unit]
Description=Apply Bluetooth MAC spoof at boot (optimized)
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
install -m 0644 "${SERVICE_PATH}.tmp" "${SERVICE_PATH}"
rm -f "${SERVICE_PATH}.tmp"
ok "Installed unit"

# 4) quick syntax check for generated script
bash -n "${SCRIPT_PATH}" || die "syntax check failed for ${SCRIPT_PATH}"

# 5) enable & start
info "Enabling and starting service"
systemctl daemon-reload
systemctl enable --now bt-mac-spoof.service

# 6) run once to apply immediately (safe)
info "Applying now (service run)"
systemctl restart bt-mac-spoof.service || warn "service run returned non-zero (check journal)"

# 7) summary
OLD="(unknown)"; [ -f "${ORIG_FILE}" ] && OLD="$(cat "${ORIG_FILE}" 2>/dev/null || echo '(unreadable)')"
CUR="$(hciconfig "${HCI}" 2>/dev/null | awk '/BD Address/ {print $3}' || echo '(unknown)')"
echo
echo "===== bt-mac-spoof summary ====="
printf "Saved original : %s\n" "${OLD}"
printf "Target MAC     : %s\n" "${TARGET_MAC}"
if [ "${CUR}" = "${TARGET_MAC}" ]; then
  printf "Current MAC    : %s (applied)\n" "${CUR}"
else
  printf "Current MAC    : %s (expected %s)\n" "${CUR}" "${TARGET_MAC}"
fi
printf "Service enabled: %s\n" "$(systemctl is-enabled bt-mac-spoof.service 2>/dev/null || echo disabled)"
printf "Service active : %s\n" "$(systemctl is-active bt-mac-spoof.service 2>/dev/null || echo inactive)"
echo
echo "Recent journal (${JOURNAL_LINES} lines):"
show_journal
echo "================================"
ok "Install complete. To uninstall: sudo $0 --uninstall"
