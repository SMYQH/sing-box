#!/bin/bash
# 一键安装脚本 (仅从 GitHub 获取文件)
#
# 安装流程:
#   1. 安装依赖 (curl / tar / jq)
#   2. 从 GitHub 下载本项目脚本
#   3. 安装 ${IS_CORE_NAME} 内核 (从 GitHub Releases)
#   4. 注册并启动 systemd 服务
#
# 该脚本不会联系除 GitHub 以外的任何主机.

IS_REPO="SMYQH/singbox"
IS_REPO_URL="https://github.com/${IS_REPO}"
: "${IS_TARBALL:=https://github.com/${IS_REPO}/archive/refs/heads/main.tar.gz}"

IS_SH_VER="1.0.1"
IS_CORE_NAME="sing-box"

red='\e[31m'
yellow='\e[33m'
green='\e[92m'
none='\e[0m'

_red() { echo -e ${red}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }

msg() {
    echo -e "${green}$(date +'%T')${none}) ${1}"
}

err() {
    echo -e "\n$(_red 错误!) $1\n"
    exit 1
}

# 统一的临时目录清理: 正常结束或被中断时都不留残留
IS_TMPDIR=""
_cleanup_tmp() {
    [[ -n ${IS_TMPDIR:-} && -d ${IS_TMPDIR:-} ]] && rm -rf "$IS_TMPDIR"
}
trap _cleanup_tmp EXIT INT TERM

[[ $EUID != 0 ]] && err "请使用 root 用户运行此脚本."

# install dependencies
install_deps() {
    local cmd
    cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)
    [[ ! $cmd ]] && err "此脚本仅支持 (Ubuntu / Debian / CentOS / SUSE / Alpine)."

    local need=""
    for i in curl tar jq; do
        [[ ! $(type -P $i) ]] && need="$need $i"
    done
    [[ -z $need ]] && return

    msg "安装依赖:$need"
    case $cmd in
    */apt-get) apt-get update -qq && apt-get install -y $need ;;
    */yum) yum install -y $need ;;
    */zypper) zypper install -y $need ;;
    */apk) apk add --no-cache $need ;;
    esac
}

# download and install the management script from GitHub
install_script() {
    local tmpdir sh_dir
    tmpdir=$(mktemp -d)
    IS_TMPDIR="$tmpdir"
    sh_dir="/usr/local/lib/sing-box"

    msg "从 GitHub 下载管理脚本 ..."
    if ! curl -fsSL --retry 3 -o "${tmpdir}/main.tar.gz" "$IS_TARBALL"; then
        err "下载失败: ${IS_TARBALL}"
    fi

    tar zxf "${tmpdir}/main.tar.gz" -C "$tmpdir" || err "解压失败."
    [[ ! -d $tmpdir/singbox-main ]] && err "未找到预期的目录结构."

    # 先清空旧目录, 避免上一版本中被删除的文件长期驻留
    rm -rf "$sh_dir"
    mkdir -p "$sh_dir"
    cp -rf "${tmpdir}/singbox-main/." "$sh_dir/"
    rm -rf "${sh_dir}/.github"

    cat >/usr/local/bin/sb <<WRAPPER
#!/bin/bash
exec bash ${sh_dir}/sing-box.sh "\$@"
WRAPPER
    chmod +x /usr/local/bin/sb
    msg "管理脚本已安装: /usr/local/bin/sb"
}

case ${1:-install} in
install)
    install_deps
    install_script
    sb install
    _green "安装完成. 运行 'sb add' 创建节点, 'sb list' 查看节点."
    ;;
-h | --help)
    echo "用法: bash install.sh [install]"
    ;;
*)
    err "未知参数: $1"
    ;;
esac
