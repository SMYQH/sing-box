#!/bin/bash
# Node management: create / list / delete VLESS + Reality nodes and keep
# the sing-box configuration in sync.

# Ensure the runtime directories exist.
is_prepare_dirs() {
    _mkdir "$IS_CORE_DIR" "$IS_CORE_DIR/bin" "$IS_CONF_DIR" "$IS_LOG_DIR"
    if [[ ! -f $IS_NODES_JSON ]]; then
        echo '[]' >"$IS_NODES_JSON"
        chmod 600 "$IS_NODES_JSON"
    fi
}

# 原子写入 JSON 文件。
# 先写入同目录下的临时文件, 只有 jq 成功且输出非空时才用 mv 覆盖目标文件。
# 原因: 直接用 > 重定向会先把目标文件截断, 一旦 jq 失败 (例如端口非法),
#       节点列表就会变成 0 字节文件, 其中保存的 Reality 私钥将全部丢失。
# Usage: is_write_json <file> <json> [label]
is_write_json() {
    local file=$1 data=$2 label=${3:-文件} tmp out
    tmp=$(mktemp "${file}.tmp.XXXXXX") || err "无法写入${label}: ${file}"
    if ! out=$(jq '.' <<<"$data" 2>/dev/null) || [[ -z $out ]]; then
        rm -f "$tmp"
        err "无法写入${label}: ${file}"
    fi
    if ! printf '%s\n' "$out" >"$tmp"; then
        rm -f "$tmp"
        err "无法写入${label}: ${file}"
    fi
    chmod 600 "$tmp"
    if ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        err "无法写入${label}: ${file}"
    fi
}

# Read the node registry.
# 文件缺失时返回空列表; 文件损坏时返回非 0,
# 避免把损坏的数据当成空列表覆盖回去。
is_read_nodes() {
    local out
    [[ -f $IS_NODES_JSON ]] || { echo '[]'; return 0; }
    out=$(jq '.' "$IS_NODES_JSON" 2>/dev/null) || return 1
    [[ -z $out ]] && out='[]'
    printf '%s\n' "$out"
}

# Persist the node registry.
is_write_nodes() {
    is_write_json "$IS_NODES_JSON" "$1" "节点列表"
}

# Pick a free TCP port.
is_free_port() {
    local port
    port=$(shuf -i 20000-60000 -n 1)
    while ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$"; do
        port=$(shuf -i 20000-60000 -n 1)
    done
    echo "$port"
}

# Create a new VLESS + Reality node.
# Usage: is_add_node [name] [port]
is_add_node() {
    local name=$1 port=$2 uuid priv_key pub_key short_id target nodes
    [[ -z $name ]] && name="node-$(date +%s)"

    # 端口必须是 1-65535 的整数: 否则 jq --argjson 会失败,
    # 进而在写节点列表时把整个列表 (含 Reality 私钥) 清空。
    if [[ -n $port ]]; then
        [[ $port =~ ^[0-9]+$ ]] || err "非法端口: ${port} (应为 1-65535 的整数)."
        port=$((10#$port))
        ((port >= 1 && port <= 65535)) || err "非法端口: ${port} (应为 1-65535 的整数)."
    else
        port=$(is_free_port)
    fi

    nodes=$(is_read_nodes) || err "节点列表文件已损坏: ${IS_NODES_JSON}"
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$nodes" ||
        err "节点列表文件格式错误: ${IS_NODES_JSON}"

    if jq -e --arg n "$name" '.[] | select(.name == $n)' >/dev/null 2>&1 <<<"$nodes"; then
        err "节点名称已存在: ${name}"
    fi

    uuid=$(is_random_uuid)
    target=${3:-$IS_REALITY_TARGET}
    is_valid_target "$target" || err "非法 target: ${target} (应为纯域名, 例如 www.microsoft.com)"

    # Reality keypair is generated locally by the sing-box binary.
    local keypair
    keypair=$("$IS_CORE_BIN" generate reality-keypair 2>/dev/null)
    priv_key=$(awk -F': ' '/PrivateKey/{print $2}' <<<"$keypair")
    pub_key=$(awk -F': ' '/PublicKey/{print $2}' <<<"$keypair")
    [[ -z $priv_key || -z $pub_key ]] && err "生成 Reality 密钥对失败."

    short_id=$(is_random_hex 8)

    local node
    node=$(jq -n --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
        --arg pk "$priv_key" --arg pub "$pub_key" --arg sid "$short_id" \
        --arg target "$target" '{
            name: $name,
            port: $port,
            uuid: $uuid,
            priv_key: $pk,
            public_key: $pub,
            short_id: $sid,
            target: $target,
            type: "vless-reality"
        }') || err "构建节点信息失败."

    is_write_nodes "$(jq --argjson n "$node" '. + [$n]' <<<"$nodes")"
    msg "已创建节点: ${name} (端口 ${port})"

    is_write_config
    is_restart

    is_show_node "$name"
}

# Usage: is_clash_proxy [name]
# 输出 mihomo / Clash.Meta 格式的节点配置, 便于在国内客户端中导入.
is_clash_proxy() {
    local name=$1 node ip port uuid pub sid target nodes
    [[ -z $name ]] && err "请指定节点名称."
    nodes=$(is_read_nodes) || err "节点列表文件已损坏: ${IS_NODES_JSON}"
    node=$(jq -c --arg n "$name" '.[] | select(.name == $n)' <<<"$nodes")
    [[ -z $node ]] && err "节点不存在: ${name}"
    ip=$(is_local_ip)
    port=$(jq -r '.port' <<<"$node")
    uuid=$(jq -r '.uuid' <<<"$node")
    pub=$(jq -r '.public_key' <<<"$node")
    sid=$(jq -r '.short_id' <<<"$node")
    target=$(jq -r '.target' <<<"$node")
    cat <<YAML
- name: "${name}"
  type: vless
  server: ${ip}
  port: ${port}
  uuid: ${uuid}
  network: tcp
  udp: true
  tls: true
  servername: ${target}
  flow: xtls-rprx-vision
  client-fingerprint: chrome
  reality-opts:
    public-key: ${pub}
    short-id: ${sid}
YAML
}

# Usage: is_set_target [name] [target]
# 修改已有节点的 Reality 握手目标 (SNI), 用于适配不同网络环境.
is_set_target() {
    local name=$1 target=$2 nodes
    [[ -z $name ]] && err "请指定节点名称."
    [[ -z $target ]] && err "请指定新的目标域名."
    is_valid_target "$target" || err "非法 target: ${target} (应为纯域名, 例如 www.microsoft.com)"
    nodes=$(is_read_nodes) || err "节点列表文件已损坏: ${IS_NODES_JSON}"
    jq -e --arg n "$name" '.[] | select(.name == $n)' >/dev/null 2>&1 <<<"$nodes" \
        || err "节点不存在: ${name}"

    is_write_nodes "$(jq --arg n "$name" --arg t "$target" \
        'map(if .name == $n then .target = $t else . end)' <<<"$nodes")"
    is_write_config
    is_restart
    msg "节点 ${name} 的 Reality 目标已更新为: ${target}"
    is_show_node "$name"
}

# Build the sing-box configuration from the node registry.
is_write_config() {
    local nodes config count
    nodes=$(is_read_nodes) || err "节点列表文件已损坏: ${IS_NODES_JSON}"
    count=$(jq 'length' <<<"$nodes")

    if [[ $count -eq 0 ]]; then
        # No node left: keep a minimal but valid configuration.
        config=$(jq -n '{
            log: { level: "info", timestamp: true },
            inbounds: [],
            outbounds: [ { type: "direct", tag: "direct" } ]
        }')
    else
        config=$(jq '{
            log: { level: "info", timestamp: true },
            inbounds: [ .[] | {
                type: "vless",
                tag: ("vless-reality-" + .name),
                listen: "::",
                listen_port: .port,
                users: [ { uuid: .uuid, flow: "xtls-rprx-vision" } ],
                tls: {
                    enabled: true,
                    server_name: .target,
                    reality: {
                        enabled: true,
                        handshake: { server: .target, server_port: 443 },
                        "private_key": .priv_key,
                        short_id: [ .short_id ]
                    }
                }
            } ],
            outbounds: [ { type: "direct", tag: "direct" } ]
        }' <<<"$nodes")
    fi

    is_write_json "$IS_CONFIG_JSON" "$config" "配置文件"

    # Validate with the real binary before it is ever loaded by the service.
    "$IS_CORE_BIN" check -c "$IS_CONFIG_JSON" || err "配置校验失败."
    msg "配置已生成并通过校验: ${IS_CONFIG_JSON}"
}

# Print the details of a node, including the client share link.
# Usage: is_show_node [name]
is_show_node() {
    local name=$1 node ip nodes
    nodes=$(is_read_nodes) || err "节点列表文件已损坏: ${IS_NODES_JSON}"
    node=$(jq -c --arg n "$name" '.[] | select(.name == $n)' <<<"$nodes")
    [[ -z $node ]] && err "未找到节点: ${name}"

    ip=$(is_local_ip)
    local uuid port pub sid target
    uuid=$(jq -r '.uuid' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    pub=$(jq -r '.public_key' <<<"$node")
    sid=$(jq -r '.short_id' <<<"$node")
    target=$(jq -r '.target' <<<"$node")

    echo
    _green "节点名称: $(jq -r '.name' <<<"$node")"
    _green "协议: VLESS + Reality"
    _green "服务器地址: ${ip}"
    _green "端口: ${port}"
    _green "UUID: ${uuid}"
    _green "流控: xtls-rprx-vision"
    _green "SNI / 握手目标: ${target}"
    _green "Public Key: ${pub}"
    _green "Short ID: ${sid}"
    _green "传输: tcp"
    _green "指纹: chrome"
    echo
    _green "分享链接:"
    echo "vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${target}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#${name}"
    echo
}

# List all nodes.
is_list_nodes() {
    local nodes count
    nodes=$(is_read_nodes) || err "节点列表文件已损坏: ${IS_NODES_JSON}"
    count=$(jq 'length' <<<"$nodes")
    if [[ $count -eq 0 ]]; then
        echo "暂无节点."
        return
    fi
    jq -r '.[] | [.name, .type, (.port|tostring), .uuid, .public_key, .short_id] | @tsv' <<<"$nodes" |
        awk -F'\t' 'BEGIN{printf "%-16s %-14s %-6s %-38s %-46s %s\n","NAME","TYPE","PORT","UUID","PUBLIC KEY","SHORT ID"}
                 {printf "%-16s %-14s %-6s %-38s %-46s %s\n",$1,$2,$3,$4,$5,$6}'
}

# Delete a node and rebuild the configuration.
# Usage: is_del_node <name>
is_del_node() {
    local name=$1 nodes
    nodes=$(is_read_nodes) || err "节点列表文件已损坏: ${IS_NODES_JSON}"
    jq -e --arg n "$name" '.[] | select(.name == $n)' <<<"$nodes" >/dev/null 2>&1 ||
        err "未找到节点: ${name}"

    is_write_nodes "$(jq --arg n "$name" '[.[] | select(.name != $n)]' <<<"$nodes")"
    msg "已删除节点: ${name}"
    is_write_config
    is_restart
}

# Service control (systemd only).
is_service_action() {
    local action=$1
    [[ $IS_SYSTEMD ]] || err "未检测到 systemd, 无法执行 ${action}."
    systemctl "$action" sing-box
}

is_restart() {
    # 检查放在重定向之外, 否则缺少 systemd 时会静默退出而不给出提示.
    [[ $IS_SYSTEMD ]] || err "未检测到 systemd, 无法重启 sing-box 服务."
    systemctl restart sing-box >/dev/null 2>&1
}

# Install the systemd unit.
is_install_service() {
    [[ $IS_SYSTEMD ]] || err "未检测到 systemd, 无法安装 sing-box 服务."
    cat >/etc/systemd/system/sing-box.service <<UNIT
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${IS_CORE_BIN} run -c ${IS_CONFIG_JSON} -C ${IS_CONF_DIR}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    msg "已安装 systemd 服务."
}

# Remove the systemd unit.
is_remove_service() {
    if [[ $IS_SYSTEMD ]]; then
        systemctl stop sing-box >/dev/null 2>&1
        systemctl disable sing-box >/dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    fi
}
