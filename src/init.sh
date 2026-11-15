#!/bin/bash
# Shared definitions and helpers.
#
# Network policy of this project:
#   - The ONLY remote endpoint ever contacted is GitHub
#     (api.github.com for release metadata, github.com for release assets).
#   - No telemetry, no IP-echo services, no third-party DNS endpoints,
#     no ACME / certificate authorities, no analytics of any kind.
#   - The public IP is derived from the local network interface, not queried.

IS_SH_VER="1.0.0"
IS_CORE_NAME="sing-box"
IS_CORE_REPO="SagerNet/sing-box"
IS_CORE_API="https://api.github.com/repos/${IS_CORE_REPO}/releases/latest"

IS_CORE_DIR="/etc/sing-box"
IS_CORE_BIN="${IS_CORE_DIR}/bin/sing-box"
IS_CONF_DIR="${IS_CORE_DIR}/conf"
IS_CONFIG_JSON="${IS_CORE_DIR}/config.json"
IS_NODES_JSON="${IS_CORE_DIR}/nodes.json"
IS_LOG_DIR="/var/log/sing-box"

# Reality handshake target. Kept on GitHub so that the server never
# contacts a third-party host during the Reality handshake.
IS_REALITY_TARGET="www.microsoft.com"
# Validate a Reality handshake target: plain hostname only (no scheme/path/port).
is_valid_target() {
    local t=$1
    [[ $t =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}


# bash colors
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

_red() { echo -e ${red}$@${none}; }
_blue() { echo -e ${blue}$@${none}; }
_cyan() { echo -e ${cyan}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }
_magenta() { echo -e ${magenta}$@${none}; }
_red_bg() { echo -e "\e[41m$@${none}"; }

IS_ERR=$(_red_bg 错误!)
IS_WARN=$(_red_bg 警告!)

# msg [warn|err] <message>
msg() {
    local color=$green text
    if [[ $1 == warn || $1 == err ]]; then
        case $1 in
        warn) color=$yellow ;;
        err) color=$red ;;
        esac
        text=$2
    else
        text=$1
    fi
    echo -e "${color}$(date +'%T')${none}) ${text}"
}

err() {
    echo -e "\n${IS_ERR} $@\n"
    exit 1
}

warn() {
    echo -e "\n${IS_WARN} $@\n"
}

_rm() { rm -rf "$@"; }
_cp() { cp -rf "$@"; }
_mkdir() { mkdir -p "$@"; }

# Locate the project root (works from the repo or from /etc/sing-box).
if [[ -z $IS_SH_DIR ]]; then
    IS_SH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi

# load a module from src/
load() {
    . "${IS_SH_DIR}/src/$1"
}

# Require root privileges.
is_root() {
    [[ $EUID != 0 ]] && err "请使用 root 用户运行此脚本."
}

# Detect the release architecture name used by sing-box assets.
is_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    armv7l | armv7) echo "armv7" ;;
    armv6l | armv6) echo "armv6" ;;
    i386 | i686) echo "386" ;;
    mips) echo "mips" ;;
    mipsle) echo "mipsle" ;;
    mips64) echo "mips64" ;;
    mips64le) echo "mips64le" ;;
    s390x) echo "s390x" ;;
    loongarch64 | loong64) echo "loong64" ;;
    *) err "不支持的架构: ${arch}" ;;
    esac
}

# Local IPv4 address of this host. Read from the network interface so that
# no external service is contacted to discover the public IP.
is_local_ip() {
    local ip
    ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [[ -z $ip ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

# Random hex string, used for Reality short ids.
is_random_hex() {
    local len=${1:-8}
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$len"
    else
        head -c "$len" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# Random uuid, read from the kernel to avoid extra dependencies.
is_random_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# Detect the init system in use.
IS_SYSTEMD=$(type -P systemctl)
IS_OPENRC=$(type -P rc-service)
