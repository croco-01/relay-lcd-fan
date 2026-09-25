#!/usr/bin/env bash
#
# setup.sh - Robust installer + beginner hardware test
# for Node-RED Bulb (GPIO23) & Fan (GPIO24) Controller.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh                 # full install + interactive test
#   ./setup.sh --skip-test     # install only, no GPIO test
#   ./setup.sh --non-interactive --yes  # CI / unattended install
#
set -euo pipefail

# ----------------------------- Config ---------------------------------------
BULB_GPIO=23
BULB_PIN="Physical Pin 16 (top row, 8th from left)"
FAN_GPIO=24
FAN_PIN="Physical Pin 18 (top row, 9th from left)"
NODE_MAJOR_REQUIRED=18
DASHBOARD_PKG="@flowfuse/node-red-dashboard@1.31.0"
MAX_RETRIES=3

SKIP_TEST=false
NON_INTERACTIVE=false
ASSUME_YES=false
SUDO=""

# ----------------------------- Args -----------------------------------------
for arg in "$@"; do
  case "$arg" in
    --skip-test) SKIP_TEST=true ;;
    --non-interactive) NON_INTERACTIVE=true ;;
    --yes|-y) ASSUME_YES=true ;;
    -h|--help)
      sed -n '1,12p' "$0"
      echo "Options: --skip-test --non-interactive --yes -h/--help"
      exit 0
      ;;
    *) echo "Unknown option: $arg (use --help)" >&2; exit 2 ;;
  esac
done
if [[ "$NON_INTERACTIVE" == true ]]; then
  SKIP_TEST=true
fi

# ----------------------------- Logging --------------------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_RESET=""
fi
info() { printf "%s[INFO]%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf "%s[ OK ]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf "%s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
step() { printf "\n%s==== %s ====%s\n" "$C_BLUE" "$*" "$C_RESET"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    err "This script needs root for apt install. Install sudo or run as root."
    exit 1
  fi
fi

cleanup_safe() {
  # Always leave relays in safe OFF state matching flow.json (ip pu).
  if command -v pinctrl >/dev/null 2>&1; then
    pinctrl set "$BULB_GPIO" ip pu >/dev/null 2>&1 || true
    pinctrl set "$FAN_GPIO" ip pu >/dev/null 2>&1 || true
  fi
}
trap cleanup_safe EXIT

ask_yes_no() {
  # $1 = prompt, $2 = default ("y" or "n"). Returns 0 for yes.
  local prompt="$1" def="${2:-n}" ans=""
  if [[ "$NON_INTERACTIVE" == true ]]; then
    [[ "$def" == "y" ]] && return 0 || return 1
  fi
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  while true; do
    if [[ "$def" == "y" ]]; then
      printf "%s [Y/n]: " "$prompt"
    else
      printf "%s [y/N]: " "$prompt"
    fi
    read -r ans || ans=""
    ans="${ans:-$def}"
    case "$ans" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

press_enter() {
  if [[ "$NON_INTERACTIVE" == true || "$ASSUME_YES" == true ]]; then return 0; fi
  printf "%s (press ENTER when ready)... " "$1"
  read -r _ || true
}

retry() {
  local n=0
  while [[ $n -lt $MAX_RETRIES ]]; do
    if "$@"; then return 0; fi
    n=$((n + 1))
    warn "Command failed (attempt $n/$MAX_RETRIES): $*"
    sleep 3
  done
  return 1
}

# ----------------------------- Prechecks ------------------------------------
step "1/6 Pre-flight checks"
if [[ ! -f /etc/debian_version ]] && [[ ! -f /etc/os-release ]]; then
  warn "Not a Debian-based OS. apt install may fail. Continuing anyway."
fi
if [[ -f /proc/device-tree/model ]]; then
  info "Device: $(tr -d '\0' < /proc/device-tree/model)"
else
  warn "Cannot detect Raspberry Pi model. If this is not a Pi, GPIO test will fail."
  warn "Install will continue, hardware test should be skipped with --skip-test."
fi
if ! command -v apt-get >/dev/null 2>&1; then
  err "apt-get not found. This script requires Raspberry Pi OS / Debian / Ubuntu."
  exit 1
fi
if ! retry $SUDO apt-get update; then
  err "apt-get update failed after $MAX_RETRIES attempts. Check network."
  exit 1
fi
ok "Pre-flight checks passed."

# ----------------------------- Base packages --------------------------------
step "2/6 Installing system packages"
# raspi-utils provides `pinctrl` on Bookworm. gpiod is a fallback debug tool.
if ! retry $SUDO apt-get install -y curl git python3 raspi-utils ca-certificates gnupg; then
  warn "Primary package set failed, retrying with minimal set."
  retry $SUDO apt-get install -y curl git python3 ca-certificates || {
    err "Failed to install base packages."
    exit 1
  }
fi
if ! command -v pinctrl >/dev/null 2>&1; then
  warn "'pinctrl' still not found. Trying gpiod + rpi.gpio fallback info."
  $SUDO apt-get install -y gpiod libgpiod-dev 2>/dev/null || true
fi
if ! command -v pinctrl >/dev/null 2>&1; then
  err "'pinctrl' command not found. Install raspi-utils manually:"
  err "  sudo apt-get install -y raspi-utils"
  err "Then re-run ./setup.sh"
  exit 1
fi
ok "pinctrl found: $(command -v pinctrl)"

# ----------------------------- Node.js --------------------------------------
step "3/6 Ensuring Node.js >= ${NODE_MAJOR_REQUIRED}"
install_nodejs() {
  info "Installing Node.js 20 LTS via NodeSource."
  curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO bash - || return 1
  $SUDO apt-get install -y nodejs || return 1
}
NEED_NODE=true
if command -v node >/dev/null 2>&1; then
  NODE_VER="$(node -v | sed 's/^v//;s/\..*//')"
  if [[ "$NODE_VER" =~ ^[0-9]+$ ]] && [[ "$NODE_VER" -ge "$NODE_MAJOR_REQUIRED" ]]; then
    NEED_NODE=false
    ok "Node.js $(node -v) already installed."
  else
    warn "Node.js $(node -v) too old, upgrading."
  fi
else
  info "Node.js not found."
fi
if [[ "$NEED_NODE" == true ]]; then
  retry install_nodejs || { err "Node.js install failed."; exit 1; }
  ok "Node.js $(node -v) installed."
fi
command -v npm >/dev/null 2>&1 || { err "npm not found after Node install."; exit 1; }

# ----------------------------- Node-RED -------------------------------------
step "4/6 Installing Node-RED + Dashboard"
if ! command -v node-red >/dev/null 2>&1; then
  info "Installing Node-RED globally (this takes a few minutes)."
  if ! retry $SUDO npm install -g --unsafe-perm node-red; then
    err "Node-RED install failed. Check npm logs above."
    exit 1
  fi
fi
ok "Node-RED: $(node-red --version 2>/dev/null || echo installed)"

NODERED_DIR="$HOME/.node-red"
mkdir -p "$NODERED_DIR"
info "Installing dashboard $DASHBOARD_PKG into $NODERED_DIR (skips if already present)."
if [[ -d "$NODERED_DIR/node_modules/@flowfuse/node-red-dashboard" ]]; then
  ok "Dashboard already installed, skipping."
else
  (cd "$NODERED_DIR" && retry npm install "$DASHBOARD_PKG") || {
    err "Dashboard install failed. Try manually:"
    err "  cd ~/.node-red && npm install $DASHBOARD_PKG"
    exit 1
  }
fi
ok "System + Node-RED install complete."

# ----------------------------- Interactive GPIO test ------------------------
BULB_RESULT="SKIPPED"
FAN_RESULT="SKIPPED"

gpio_on()  { pinctrl set "$1" op dl; }
gpio_off() { pinctrl set "$1" ip pu; }

test_device() {
  # $1 = friendly name, $2 = gpio, $3 = pin label
  local name="$1" gpio="$2" pin="$3" attempt=1 on_ok=false off_ok=false
  echo ""
  echo "------------------------------------------------------------"
  echo " Testing $name (GPIO $gpio / $pin)"
  echo "------------------------------------------------------------"
  echo "Expected wiring:"
  echo "  Relay VCC -> 5V (Pin 2, red rail)"
  echo "  Relay GND -> GND (Pin 6, blue rail)"
  echo "  Relay IN  -> $pin (GPIO $gpio)"
  echo "Flow commands: ON='pinctrl set $gpio op dl', OFF='pinctrl set $gpio ip pu'"
  echo ""

  if ! ask_yes_no "Did you connect relay IN to $pin (GPIO $gpio)?" "n"; then
    echo "Skipping $name. Please wire it and re-run ./setup.sh to test."
    printf -v "${4}" "SKIPPED"
    return 0
  fi
  press_enter "Please finish $name load wiring, then continue"

  while [[ $attempt -le $MAX_RETRIES ]]; do
    echo ""
    info "[$name] Attempt $attempt/$MAX_RETRIES: turning ON (pinctrl set $gpio op dl)..."
    if ! gpio_on "$gpio"; then
      err "pinctrl failed. Are you running on a Raspberry Pi?"
      return 1
    fi
    if ask_yes_no ">>> Did the $name turn ON?" "n"; then
      on_ok=true
      break
    else
      warn "ON not confirmed. Check: relay VCC=5V? GND connected? IN wire on correct pin?"
      gpio_off "$gpio" || true
      if ! ask_yes_no "Retry $name ON test?" "y"; then break; fi
      attempt=$((attempt + 1))
    fi
  done

  if [[ "$on_ok" != true ]]; then
    err "$name ON test FAILED or skipped."
    printf -v "${4}" "FAIL-ON"
    gpio_off "$gpio" || true
    return 0
  fi

  info "[$name] Turning OFF (pinctrl set $gpio ip pu)..."
  gpio_off "$gpio"
  if ask_yes_no ">>> Did the $name turn OFF?" "y"; then
    off_ok=true
  fi

  if [[ "$off_ok" == true ]]; then
    ok "$name test PASSED (ON + OFF confirmed)."
    printf -v "${4}" "PASS"
  else
    err "$name turns ON but did not confirm OFF. Check relay type (active-LOW?) and wiring."
    printf -v "${4}" "FAIL-OFF"
  fi
}

step "5/6 Hardware manual test (beginner friendly)"
if [[ "$SKIP_TEST" == true ]]; then
  info "Skipping GPIO test (--skip-test / --non-interactive)."
else
  if [[ ! -t 0 ]]; then
    warn "No interactive terminal, skipping GPIO test."
  else
    info "We will now test Bulb then Fan one by one."
    info "You will be asked to confirm wiring and ON/OFF with y/n."
    press_enter "Ready to start?"
    # Ensure safe state before test
    gpio_off "$BULB_GPIO" || true
    gpio_off "$FAN_GPIO" || true
    test_device "Bulb" "$BULB_GPIO" "$BULB_PIN" BULB_RESULT
    test_device "Fan" "$FAN_GPIO" "$FAN_PIN" FAN_RESULT
    gpio_off "$BULB_GPIO" || true
    gpio_off "$FAN_GPIO" || true
  fi
fi

# ----------------------------- Summary --------------------------------------
step "6/6 Summary"
echo "Bulb (GPIO $BULB_GPIO): $BULB_RESULT"
echo "Fan  (GPIO $FAN_GPIO): $FAN_RESULT"
echo ""
if [[ "$BULB_RESULT" == "PASS" && "$FAN_RESULT" == "PASS" ]]; then
  ok "All hardware tests passed. You can import the flow."
elif [[ "$BULB_RESULT" == SKIPPED* || "$FAN_RESULT" == SKIPPED* ]]; then
  warn "One or more tests skipped. Re-run ./setup.sh (without --skip-test) after wiring."
else
  warn "One or more tests did not pass. Check wiring/power/relay jumper (active-LOW?) and retry."
fi
echo ""
echo "Next steps:"
echo "  1. Start Node-RED:  node-red"
echo "  2. Import flow.json (Node-RED menu -> Import)"
echo "  3. Click Deploy"
echo "  4. Open: http://<YOUR_PI_IP_ADDRESS>:1880/dashboard/home"
echo "  Control Panel = Bulb/Fan switches, Status = ON/OFF texts."
echo ""
ok "setup.sh finished without errors."
