#!/bin/bash
# 一键安装脚本 (仅从 GitHub 获取文件)
#
# 运行环境: Debian 系系统 (apt) + systemd
#
# 安装流程:
#   1. 安装依赖 (curl / tar / jq)
#   2. 从 GitHub 下载本项目脚本
#   3. 安装 ${IS_CORE_NAME} 内核 (从 GitHub Releases)
#   4. 注册并启动 systemd 服务
#
# 该脚本不会联系除 GitHub 以外的任何主机.

IS_REPO="SMYQH/sing-box"
IS_REPO_URL="https://github.com/${IS_REPO}"
: "${IS_TARBALL:=https://github.com/${IS_REPO}/archive/refs/heads/main.tar.gz}"

IS_SH_VER="1.0.2"
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

# 读取系统名称 (仅用于提示信息)
os_name() {
    [[ -r /etc/os-release ]] || { echo "未知系统"; return; }
    local name
    name=$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)
    echo "${name:-未知系统}"
}

# 判断是否为 Debian 系系统 (Debian 及其衍生版, 如 Ubuntu / Devuan)
is_debian_os() {
    [[ -r /etc/os-release ]] || return 1
    local id id_like
    id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)
    id_like=$(awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)
    [[ $id == debian ]] && return 0
    [[ " ${id_like} " == *" debian "* ]] && return 0
    return 1
}

# 校验运行环境: 仅支持 Debian 系 (apt) 且使用 systemd
check_env() {
    is_debian_os || err "此脚本仅支持 Debian 系统 (当前系统: $(os_name))."
    [[ -n $(type -P apt-get) ]] || err "未检测到 apt-get, 请确认使用的是标准 Debian 系统."
    [[ -n $(type -P systemctl) ]] || err "未检测到 systemd, 请确认使用的是标准 Debian 系统."
}

# install dependencies
install_deps() {
    local need=""
    for i in curl tar jq; do
        [[ ! $(type -P $i) ]] && need="$need $i"
    done
    [[ -z $need ]] && return

    msg "安装依赖:$need"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || err "apt-get update 失败."
    DEBIAN_FRONTEND=noninteractive apt-get install -y $need || err "依赖安装失败: $need"
}

# download and install the management script from GitHub
install_script() {
    local tmpdir sh_dir src_dir stage repo_root d
    tmpdir=$(mktemp -d)
    IS_TMPDIR="$tmpdir"
    sh_dir="/usr/local/lib/sing-box"
    # 新版本先落到暂存目录, 最后整体替换旧目录。
    # 原因: 直接在源目录上做 rm -rf 会把管理脚本自己删掉
    #       (运行已安装的副本时 src_dir 与 sh_dir 是同一个目录)。
    stage="${tmpdir}/stage"

    # 从仓库检出目录运行时直接使用本地文件。
    # 原因: GitHub 的分支 tarball 存在 CDN 缓存, push 后短时间内取到的仍是旧版本,
    #       会造成"明明 clone 到新版本却装上旧脚本"的现象。
    # 仅当脚本以文件方式执行时才考虑使用本地目录;
    # 通过管道执行 (curl ... | bash) 时一律从 GitHub 下载官方版本。
    src_dir=""
    if [[ -n ${BASH_SOURCE[0]:-} ]]; then
        src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
    fi
    if [[ -n $src_dir && -f "$src_dir/sing-box.sh" && -d "$src_dir/src" ]]; then
        msg "使用当前目录的管理脚本: ${src_dir}"
        mkdir -p "$stage"
        cp -rf "${src_dir}/." "$stage/" || err "复制管理脚本失败."
    else
        msg "从 GitHub 下载管理脚本 ..."
        if ! curl -fsSL --retry 3 -o "${tmpdir}/main.tar.gz" "$IS_TARBALL"; then
            err "下载失败: ${IS_TARBALL}"
        fi

        tar zxf "${tmpdir}/main.tar.gz" -C "$tmpdir" || err "解压失败."
        # GitHub 以仓库名作为压缩包根目录, 仓库改名后根目录名也会跟着变,
        # 因此这里自动识别顶层目录, 不写死目录名。
        repo_root=""
        for d in "$tmpdir"/*/; do
            [[ -d $d ]] || continue
            if [[ -f "${d}sing-box.sh" && -d "${d}src" ]]; then
                repo_root="${d%/}"
                break
            fi
        done
        [[ -z $repo_root ]] && err "未找到预期的目录结构."

        mkdir -p "$stage"
        cp -rf "${repo_root}/." "$stage/" || err "复制管理脚本失败."
    fi

    # 先清空旧目录, 避免上一版本中被删除的文件长期驻留
    rm -rf "$sh_dir"
    mkdir -p "$(dirname "$sh_dir")"
    mv "$stage" "$sh_dir" || err "安装管理脚本失败: ${sh_dir}"
    rm -rf "${sh_dir}/.github" "${sh_dir}/.git"

    cat >/usr/local/bin/sb <<WRAPPER
#!/bin/bash
exec bash ${sh_dir}/sing-box.sh "\$@"
WRAPPER
    chmod +x /usr/local/bin/sb
    msg "管理脚本已安装: /usr/local/bin/sb"
}

case ${1:-install} in
install)
    check_env
    install_deps
    install_script
    sb install
    _green "安装完成. 运行 'sb add' 创建节点, 'sb list' 查看节点."
    ;;
-h | --help)
    echo "用法: bash install.sh [install]"
    echo "一键安装: curl -fsSL https://raw.githubusercontent.com/${IS_REPO}/main/install.sh | sudo bash"
    ;;
*)
    err "未知参数: $1"
    ;;
esac
