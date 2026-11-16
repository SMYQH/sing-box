#!/bin/bash
# sing-box 管理脚本 (VLESS + Reality)
#
# 该脚本仅从 GitHub 获取 ${IS_CORE_NAME} 内核, 不收集任何数据,
# 不含任何遥测, 第三方 DNS 或 IP 查询服务, 也不提供脚本自更新.

IS_SH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "${IS_SH_DIR}/src/init.sh"
load download.sh
load core.sh
load help.sh

is_update_core() {
    local current
    is_require_debian
    # 内核目录可能还不存在 (全新主机, 或先执行 update 而未 install),
    # 必须先创建目录, 否则下载完成后复制内核会失败。
    is_prepare_dirs
    current=$("$IS_CORE_BIN" version 2>/dev/null | head -n1)
    if [[ -n $current ]]; then
        msg "当前版本: ${current}"
    else
        msg "未检测到已安装的 ${IS_CORE_NAME} 内核, 将直接下载安装."
    fi
    is_download_core
    is_restart
    msg "${IS_CORE_NAME} 内核已更新."
}

is_install() {
    is_root
    is_require_debian
    is_prepare_dirs
    msg "安装 ${IS_CORE_NAME} 内核 ..."
    is_download_core
    is_write_config
    is_install_service
    is_restart
    msg "安装完成. 使用 'sb add' 创建节点."
}

is_uninstall() {
    is_root
    is_remove_service
    _rm "$IS_CORE_DIR"
    # 脚本自身所在目录与 sb 入口需延迟删除, 避免运行中的脚本被移除
    nohup bash -c "sleep 1; rm -rf '${IS_SCRIPT_DIR}' '${IS_SB_BIN}'" >/dev/null 2>&1 &
    msg "已卸载. 管理脚本与 sb 命令将在 1 秒后被移除."
}

case ${1:-menu} in
install)
    is_install
    ;;
add)
    shift
    is_root
    is_prepare_dirs
    _name="" _port="" _target=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --target | -t)
                # 必须带值: 否则 shift 2 会因参数不足而失败, 循环永远停不下来
                [[ $# -lt 2 || -z ${2:-} ]] && err "--target 需要指定目标域名."
                _target=$2
                shift 2
                ;;
            *)
                if [[ -z $_name ]]; then
                    _name=$1
                elif [[ -z $_port ]]; then
                    _port=$1
                fi
                shift
                ;;
        esac
    done
    is_add_node "$_name" "$_port" "$_target"
    ;;
list)
    is_list_nodes
    ;;
show)
    shift
    [[ -z $1 ]] && err "请指定节点名称."
    is_show_node "$1"
    ;;
del | delete)
    shift
    [[ -z $1 ]] && err "请指定节点名称."
    is_root
    is_prepare_dirs
    is_del_node "$1"
    ;;
clash)
    shift
    [[ -z $1 ]] && err "请指定节点名称."
    is_clash_proxy "$1"
    ;;
target)
    shift
    [[ -z $1 ]] && err "请指定节点名称."
    [[ -z $2 ]] && err "请指定新的目标域名."
    is_root
    is_prepare_dirs
    is_set_target "$1" "$2"
    ;;
sync)
    # 根据节点列表重新生成配置并重启服务.
    is_root
    is_prepare_dirs
    is_write_config
    is_restart
    msg "配置已同步."
    ;;
update)
    is_root
    is_update_core
    ;;
start | stop | restart | status)
    is_service_action "$1"
    ;;
logs)
    journalctl -u sing-box -n 100 --no-pager
    ;;
uninstall)
    is_uninstall
    ;;
help | -h | --help)
    is_help
    ;;
menu | "")
    is_menu
    ;;
*)
    is_help
    ;;
esac
