#!/bin/bash

VERSION="0.2.0"
AUTHOR="shilch (updated by ChatGPT)"
YEAR="2025"

RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RS='\033[0m'

BOLD=$(tput bold)
NORMAL=$(tput sgr0)

ERROR="${BOLD}${RED}ERROR:${RS}${NORMAL}   "
INFO="${BOLD}${BLUE}INFO:${RS}${NORMAL}    "
WARNING="${BOLD}${YELLOW}WARNING:${RS}${NORMAL} "

if [[ "$(uname)" != "Darwin" ]]; then
  printf "${ERROR}This script only works on macOS.\n"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  printf "${ERROR}Use as root: sudo $0 [option] [device]\n"
  exit 1
fi

ensureDeviceExists () {
  if ! ifconfig "$1" > /dev/null 2>&1; then
    printf "${ERROR}Device/interface not found. Maybe it's down?\n"
    exit 1
  fi
}

getType(){
  networksetup -listallhardwareports | \
  awk -v iface="$1" '
    $1=="Hardware" && $2=="Port:" {port=$3}
    $1=="Device:" && $2==iface {print port}
  '
}

generateMac() {
  openssl rand -hex 6 | sed 's/\(..\)/\1:/g; s/:$//' | awk '{print tolower($0)}'
}

currentMac () {
  ifconfig "$1" | awk '/ether/{print $2}'
}

getPermanent (){
  networksetup -getmacaddress "$1" 2>/dev/null | awk '{print $3}'
}

setMac(){
  local iface=$1
  local newmac=$2

  printf "${INFO}Disabling interface $iface...\n"
  ifconfig "$iface" down

  printf "${INFO}Setting new MAC: $newmac\n"
  ifconfig "$iface" ether "$newmac"

  printf "${INFO}Enabling interface $iface...\n"
  ifconfig "$iface" up
}

warnMulticast(){
  local firstbyte=$(echo "$1" | cut -d: -f1)
  local dec=$((16#$firstbyte))
  if (( dec % 2 != 0 )); then
    printf "${WARNING}MAC address is multicast! Might not work properly.\n"
  fi
}

if [[ "$1" == "-v" || "$1" == "--version" ]]; then
  printf "Version: $VERSION, Copyright $YEAR by $AUTHOR\n"

elif [[ "$1" == "-s" || "$1" == "--show" ]]; then
  if [[ -z "$2" ]]; then
    printf "${ERROR}Please specify your device / interface\n"
    exit 1
  fi
  ensureDeviceExists "$2"

  printf "${BOLD}Type of device:${NORMAL}         $( getType "$2" )\n"
  printf "${BOLD}Permanent MAC address:${NORMAL}  $( getPermanent "$2" )\n"
  printf "${BOLD}Current MAC address:${NORMAL}    $( currentMac "$2" )\n"

elif [[ "$1" == "-r" || "$1" == "--random" ]]; then
  if [[ -z "$2" ]]; then
    printf "${ERROR}Please specify your device / interface\n"
    exit 1
  fi
  ensureDeviceExists "$2"

  oldmac=$( currentMac "$2" )
  newmac=$( generateMac )

  warnMulticast "$newmac"
  setMac "$2" "$newmac"

  printf "${BOLD}Permanent MAC address:${NORMAL} $( getPermanent "$2" )\n"
  printf "${BOLD}Old MAC address:${NORMAL}       $oldmac\n"
  printf "${BOLD}New MAC address:${NORMAL}       $( currentMac "$2" )\n"

elif [[ "$1" == "-m" || "$1" == "--mac" ]]; then
  if [[ -z "$2" || -z "$3" ]]; then
    printf "${ERROR}Usage: -m MAC device\n"
    exit 1
  fi
  warnMulticast "$2"
  ensureDeviceExists "$3"

  oldmac=$( currentMac "$3" )
  setMac "$3" "$2"

  printf "${BOLD}Permanent MAC address:${NORMAL} $( getPermanent "$3" )\n"
  printf "${BOLD}Old MAC address:${NORMAL}       $oldmac\n"
  printf "${BOLD}New MAC address:${NORMAL}       $( currentMac "$3" )\n"

elif [[ "$1" == "-p" || "$1" == "--permanent" ]]; then
  if [[ -z "$2" ]]; then
    printf "${ERROR}Please specify your device / interface\n"
    exit 1
  fi
  ensureDeviceExists "$2"

  oldmac=$( currentMac "$2" )
  permac=$( getPermanent "$2" )

  setMac "$2" "$permac"

  printf "${BOLD}Permanent MAC address:${NORMAL} $permac\n"
  printf "${BOLD}Old MAC address:${NORMAL}       $oldmac\n"
  printf "${BOLD}New MAC address:${NORMAL}       $( currentMac "$2" )\n"

else
  printf "Usage: sudo $0 [option] [device]\n"
  printf "Options:\n"
  printf " -r, --random         Generates a random MAC and sets it\n"
  printf " -m, --mac MAC        Set a custom MAC address\n"
  printf " -p, --permanent      Reset to permanent MAC address\n"
  printf " -s, --show           Show current & permanent MAC\n"
  printf " -v, --version        Show version\n"
fi
