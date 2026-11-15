#!/bin/bash
# Help text and interactive menu.

is_help() {
    cat <<HELP
${IS_CORE_NAME} 管理脚本 v${IS_SH_VER}

用法: sb <命令> [参数]

  install                    安装 ${IS_CORE_NAME} 内核及服务
  add [名称] [端口]          添加 VLESS + Reality 节点
  list                       列出所有节点
  show <名称>                 显示节点详情及分享链接
  del <名称>                  删除节点
  update                     更新 ${IS_CORE_NAME} 内核 (仅从 GitHub 获取)
  start | stop | restart      服务控制
  status                     查看服务状态
  logs                       查看服务日志
  uninstall                  卸载内核与服务
  help                       显示本帮助

说明:
  - 所有网络请求仅指向 GitHub (api.github.com / github.com)。
  - 不收集任何数据, 不上报任何遥测, 不使用第三方 DNS 或 IP 查询服务。
  - 本脚本不提供自更新, 如需更新请手动获取新版本。

HELP
}

is_menu() {
    while :; do
        echo
        _green "===== ${IS_CORE_NAME} 管理菜单 ====="
        echo "  1) 添加节点 (VLESS + Reality)"
        echo "  2) 列出节点"
        echo "  3) 显示节点详情"
        echo "  4) 删除节点"
        echo "  5) 更新 ${IS_CORE_NAME} 内核"
        echo "  6) 服务控制 (启动/停止/重启/状态)"
        echo "  7) 查看日志"
        echo "  0) 退出"
        echo
        read -rp "请选择 [0-7]: " opt
        case $opt in
        1)
            read -rp "节点名称 (回车自动生成): " name
            read -rp "端口 (回车自动选择): " port
            is_add_node "$name" "$port"
            ;;
        2) is_list_nodes ;;
        3)
            read -rp "节点名称: " name
            is_show_node "$name"
            ;;
        4)
            read -rp "节点名称: " name
            is_del_node "$name"
            ;;
        5) is_update_core ;;
        6)
            read -rp "操作 (start/stop/restart/status): " act
            is_service_action "$act"
            ;;
        7) journalctl -u sing-box -n 50 --no-pager ;;
        0) break ;;
        *) warn "无效选项." ;;
        esac
    done
}
