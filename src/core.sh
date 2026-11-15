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

# Read the node registry.
is_read_nodes() {
    [[ -f $IS_NODES_JSON ]] || { echo '[]'; return; }
    jq '.' "$IS_NODES_JSON" 2>/dev/null || echo '[]'
}

# Persist the node registry.
is_write_nodes() {
    local nodes=$1
    jq '.' <<<"$nodes" >"$IS_NODES_JSON" 2>/dev/null ||
        err "无法写入节点列表."
    chmod 600 "$IS_NODES_JSON"
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
    local name=$1 port=$2 uuid priv_key pub_key short_id target
    [[ -z $name ]] && name="node-$(date +%s)"
    [[ -z $port ]] && port=$(is_free_port)

    if is_read_nodes | jq -e --arg n "$name" '.[] | select(.name == $n)' >/dev/null 2>&1; then
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
        }')

    is_write_nodes "$(is_read_nodes | jq --argjson n "$node" '. + [$n]')"
    msg "已创建节点: ${name} (端口 ${port})"

    is_write_config
    is_restart

    is_show_node "$name"
}

# Usage: is_clash_proxy [name]
# 输出 mihomo / Clash.Meta 格式的节点配置, 便于在国内客户端中导入.
is_clash_proxy() {
    local name=$1 node ip port uuid pub sid target
    [[ -z $name ]] && err "请指定节点名称."
    node=$(is_read_nodes | jq -c --arg n "$name" '.[] | select(.name == $n)')
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
    local name=$1 target=$2
    [[ -z $name ]] && err "请指定节点名称."
    [[ -z $target ]] && err "请指定新的目标域名."
    is_valid_target "$target" || err "非法 target: ${target} (应为纯域名, 例如 www.microsoft.com)"
    is_read_nodes | jq -e --arg n "$name" '.[] | select(.name == $n)' >/dev/null 2>&1 \
        || err "节点不存在: ${name}"

    is_write_nodes "$(is_read_nodes | jq --arg n "$name" --arg t "$target" \
        'map(if .name == $n then .target = $t else . end)')"
    is_write_config
    is_restart
    msg "节点 ${name} 的 Reality 目标已更新为: ${target}"
    is_show_node "$name"
}

# Build the sing-box configuration from the node registry.
is_write_config() {
    local nodes config count
    nodes=$(is_read_nodes)
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

    jq '.' <<<"$config" >"$IS_CONFIG_JSON" || err "无法生成配置文件."
    chmod 600 "$IS_CONFIG_JSON"

    # Validate with the real binary before it is ever loaded by the service.
    "$IS_CORE_BIN" check -c "$IS_CONFIG_JSON" || err "配置校验失败."
    msg "配置已生成并通过校验: ${IS_CONFIG_JSON}"
}

# Print the details of a node, including the client share link.
# Usage: is_show_node [name]
is_show_node() {
    local name=$1 node ip
    node=$(is_read_nodes | jq --arg n "$name" '.[] | select(.name == $n)')
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
    nodes=$(is_read_nodes)
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
    nodes=$(is_read_nodes)
    jq -e --arg n "$name" '.[] | select(.name == $n)' <<<"$nodes" >/dev/null 2>&1 ||
        err "未找到节点: ${name}"

    is_write_nodes "$(jq --arg n "$name" '[.[] | select(.name != $n)]' <<<"$nodes")"
    msg "已删除节点: ${name}"
    is_write_config
    is_restart
}

# Service control.
is_service_action() {
    local action=$1
    if [[ $IS_SYSTEMD ]]; then
        systemctl "$action" sing-box
    elif [[ $IS_OPENRC ]]; then
        rc-service sing-box "$action"
    else
        err "未检测到 systemd 或 openrc."
    fi
}

is_restart() {
    is_service_action restart >/dev/null 2>&1
}

# Install the systemd unit.
is_install_service() {
    if [[ ! $IS_SYSTEMD ]]; then
        warn "未检测到 systemd, 请手动管理 sing-box 服务."
        return
    fi
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
