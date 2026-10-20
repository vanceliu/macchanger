#!/bin/bash
# macchanger.sh - Change macOS network interface MAC address (macOS 15 / 26)

VERSION="0.3.0_mac26"
MAX_ROUNDS=5          # Wi-Fi off/on retry rounds
WINDOW_TRIES=40       # attempts per round, 0.1s apart

RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'; RS='\033[0m'
BOLD=$(tput bold 2>/dev/null); NORMAL=$(tput sgr0 2>/dev/null)
ERROR="${BOLD}${RED}ERROR:${RS}${NORMAL}   "
INFO="${BOLD}${BLUE}INFO:${RS}${NORMAL}    "
WARNING="${BOLD}${YELLOW}WARNING:${RS}${NORMAL} "
OK="${BOLD}${GREEN}OK:${RS}${NORMAL}      "

die() { printf "%b%s\n" "$ERROR" "$1"; exit 1; }
info() { printf "%b%s\n" "$INFO" "$1"; }
warn() { printf "%b%s\n" "$WARNING" "$1"; }

[[ "$(uname)" == "Darwin" ]] || die "This script only runs on macOS."

ensureDeviceExists() {
  [[ -n "$1" ]] || die "Specify a device (e.g. en0). List devices with: networksetup -listallhardwareports"
  ifconfig "$1" >/dev/null 2>&1 || die "Device $1 not found."
}

ensureRoot() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 $*"
}

# Returns the Hardware Port name
getType() {
  networksetup -listallhardwareports | awk -v iface="$1" '
    /^Hardware Port:/ { sub(/^Hardware Port: /, ""); port=$0 }
    /^Device:/ && $2==iface { print port; exit }'
}

isWifi() { [[ "$(getType "$1")" == "Wi-Fi" ]]; }

currentMac() { ifconfig "$1" 2>/dev/null | awk '/ether/{print tolower($2); exit}'; }

getPermanent() { networksetup -getmacaddress "$1" 2>/dev/null | awk '{print tolower($3)}'; }

normalizeMac() {
  local m
  m=$(printf "%s" "$1" | tr 'A-F-' 'a-f:')
  [[ "$m" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || return 1
  printf "%s" "$m"
}

# Locally administered, unicast
generateMac() {
  local hex first
  hex=$(openssl rand -hex 6)
  first=$(( (16#${hex:0:2} & 0xFC) | 0x02 ))
  printf "%02x:%s:%s:%s:%s:%s" "$first" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}" "${hex:8:2}" "${hex:10:2}"
}

warnMulticast() {
  local first=$((16#${1:0:2}))
  (( first % 2 == 0 )) || warn "This is a multicast address (odd first byte); setting it usually fails."
}

# Must be set after Wi-Fi restarts, before it auto-joins a network
setMacWifi() {
  local iface=$1 mac=$2 round try
  for (( round=1; round<=MAX_ROUNDS; round++ )); do
    info "Round $round/$MAX_ROUNDS: restarting Wi-Fi and setting MAC..."
    networksetup -setairportpower "$iface" off
    sleep 1
    networksetup -setairportpower "$iface" on
    for (( try=1; try<=WINDOW_TRIES; try++ )); do
      ifconfig "$iface" ether "$mac" 2>/dev/null
      if [[ "$(currentMac "$iface")" == "$mac" ]]; then
        networksetup -detectnewhardware 2>/dev/null
        return 0
      fi
      sleep 0.1
    done
  done
  return 1
}

# Interface must be up
setMacWired() {
  local iface=$1 mac=$2
  ifconfig "$iface" ether "$mac" 2>/dev/null
  [[ "$(currentMac "$iface")" == "$mac" ]] && return 0
  ifconfig "$iface" down; ifconfig "$iface" ether "$mac" 2>/dev/null; ifconfig "$iface" up
  [[ "$(currentMac "$iface")" == "$mac" ]]
}

setMac() {
  local iface=$1 mac=$2 old
  old=$(currentMac "$iface")
  [[ -n "$old" ]] || die "$iface has no configurable MAC address."
  warnMulticast "$mac"

  if [[ "$old" == "$mac" ]]; then
    info "MAC is already $mac; nothing to change."
  elif isWifi "$iface"; then
    if ! setMacWifi "$iface" "$mac"; then
      printf "%b%s\n" "$ERROR" "Failed to set Wi-Fi MAC (Wi-Fi reconnected too fast, or the driver rejected the address)."
      echo "  Manual fallback: Option-click the Wi-Fi menu bar icon -> Disconnect, then immediately run:"
      echo "    sudo ifconfig $iface ether $mac"
      exit 1
    fi
  else
    setMacWired "$iface" "$mac" || die "This driver does not support changing the MAC (common with USB / Thunderbolt Ethernet adapters)."
  fi

  printf "%b%s\n" "$OK" "MAC changed"
  printf "${BOLD}Permanent MAC address:${NORMAL} %s\n" "$(getPermanent "$iface")"
  printf "${BOLD}Old MAC address:${NORMAL}       %s\n" "$old"
  printf "${BOLD}New MAC address:${NORMAL}       %s\n" "$(currentMac "$iface")"
  if isWifi "$iface"; then
    echo
    warn "Reconnect to Wi-Fi manually. If the network's Private Wi-Fi Address is not Off, macOS may replace this MAC on reconnect"
    echo "         (System Settings -> Wi-Fi -> Details... -> Private Wi-Fi Address -> Off). The MAC resets after reboot."
  fi
}

usage() {
  cat <<USAGE
Usage: sudo bash $0 [option] [device]
Options:
  -m, --mac MAC DEV    Set a specific MAC, e.g. sudo bash $0 -m a4:cf:99:64:9c:de en0
  -r, --random DEV     Set a random MAC (locally administered, unicast)
  -p, --permanent DEV  Restore the permanent (hardware) MAC
  -s, --show DEV       Show current / permanent MAC
  -v, --version        Show version
USAGE
}

case "$1" in
  -v|--version)
    echo "macchanger3 version $VERSION (for macOS 15 / 26)" ;;
  -s|--show)
    ensureDeviceExists "$2"
    printf "${BOLD}Type of device:${NORMAL}         %s\n" "$(getType "$2")"
    printf "${BOLD}Permanent MAC address:${NORMAL}  %s\n" "$(getPermanent "$2")"
    printf "${BOLD}Current MAC address:${NORMAL}    %s\n" "$(currentMac "$2")" ;;
  -m|--mac)
    ensureRoot "$@"
    MAC=$(normalizeMac "$2") || die "Invalid MAC: $2 (expected aa:bb:cc:dd:ee:ff)"
    ensureDeviceExists "$3"
    setMac "$3" "$MAC" ;;
  -r|--random)
    ensureRoot "$@"
    ensureDeviceExists "$2"
    setMac "$2" "$(generateMac)" ;;
  -p|--permanent)
    ensureRoot "$@"
    ensureDeviceExists "$2"
    PERM=$(getPermanent "$2")
    PERM=$(normalizeMac "$PERM") || die "Could not read the permanent MAC of $2."
    setMac "$2" "$PERM" ;;
  *)
    usage ;;
esac
