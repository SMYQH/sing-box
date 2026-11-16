# sing-box 管理脚本 (VLESS + Reality)

一个精简、纯净的 sing-box 管理脚本，用于快速部署 VLESS + Reality 节点。

## 特性

- **零数据采集**：不收集、不上报任何用户数据与遥测信息。
- **仅连接 GitHub**：除 GitHub（`api.github.com` / `github.com`）外，**脚本本身**不会访问任何外部主机。
  - 不使用 IP 查询服务（如 `one.one.one.one`）获取公网 IP，公网 IP 从本机网卡读取。
  - 不内置第三方 DNS 服务器（Cloudflare / Google DoH），DNS 交由系统解析。
  - 不含 Caddy / ACME 自动证书签发，不与 Let's Encrypt 等 CA 通信。
- **无脚本自更新**：脚本不会自我更新或静默下载执行远端代码；内核更新为显式命令。
- **完整性校验**：下载内核时校验 GitHub Release 提供的 SHA-256 摘要。
- **配置预校验**：生成的配置先经 `sing-box check` 校验通过后才重启服务。
- 仅实现 VLESS + Reality 协议，代码量小、易审计。

## 环境要求

- Debian
- root 权限
- systemd

## 安装

```bash
bash install.sh
```

或手动安装：

```bash
# 1. 安装依赖
apt update && apt install -y curl tar jq

# 2. 下载脚本到 /usr/local/lib/sing-box 并创建 /usr/local/bin/sb

# 3. 安装内核并注册服务
sb install
```

重复执行 `bash install.sh` 是安全的：安装前会先清空 `/usr/local/lib/sing-box`，旧版本中已删除的文件不会残留；若目标版本的内核已安装，则跳过内核下载。安装过程中产生的临时目录在正常结束、失败或被中断时都会被清理。

## 使用

```bash
sb add                                           # 添加节点 (交互式)
sb add mynode 25530                              # 添加节点 (指定名称与端口)
sb add mynode 25530 --target www.microsoft.com   # 指定 Reality 握手目标
sb list                                          # 列出所有节点
sb show mynode                                   # 查看节点详情与分享链接
sb del mynode                                    # 删除节点
sb sync                                          # 依据节点列表重新生成配置并重启服务
sb update                                        # 更新 sing-box 内核
sb start|stop|restart|status                     # 管理 sing-box 启动
sb logs                                          # 查看服务日志
sb uninstall                                     # 完整卸载 (内核 / 服务 / 管理脚本 / sb 命令)
sb help                                          # 帮助
```

> 不带参数运行 `sb` 进入交互式菜单。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `/etc/sing-box/bin/sing-box` | 内核二进制 |
| `/etc/sing-box/config.json` | 生成的配置 |
| `/etc/sing-box/nodes.json` | 节点清单 |
| `/etc/sing-box/conf/` | 额外配置目录 |
| `/usr/local/lib/sing-box/` | 管理脚本 |
| `/usr/local/bin/sb` | 管理命令入口 |

## Reality 握手目标

Reality 客户端与服务器之间的 TLS ClientHello 中会携带 `SNI`，且该 SNI 在链路上是可见的。
审查或过滤设备可能针对特定 SNI 做处理，导致握手被服务端拒绝，日志表现为：

```
TLS handshake: REALITY: processed invalid connection
```

因此握手目标应当选择**在客户端所在网络中不会被针对性处理**的域名。默认值为`www.microsoft.com`（该域名在多数网络下不会被针对性处理，兼容性最好），可按节点级别调整：

```bash
sb target mynode github.com          # 修改已有节点的目标 (UUID/密钥不变, 立即生效)
sb add mynode2 25531 --target github.com
```

> 注意：Reality 握手本身必然要求服务端与目标域名建立一次出站连接，这是协议本身的组成部分，不属于「脚本主动访问外部主机」的行为。

## 客户端参数

分享链接形如：

```
vless://<uuid>@<server>:<port>?encryption=none&flow=xtls-rprx-vision&security=reality&sni=<target>&fp=chrome&pbk=<public_key>&sid=<short_id>&type=tcp#<name>
```

其中 `pbk` 为 Public Key、`sid` 为 Short ID，二者由 `sb show <name>` 输出。

## 常见故障排查

| 现象 | 服务端日志 | 原因 | 处理 |
|------|-----------|------|------|
| 连接超时 | 无任何记录 | 端口未放行 / 网络不通 | 检查 `ss -tln \| grep <端口>` 与服务商端口策略 |
| 握手被拒 | `REALITY: processed invalid connection` | 客户端参数错误或 ClientHello 被链路篡改 | 核对 `pbk` / `sid` / `sni`；确认客户端已启用 Reality 与 `fp=chrome`；尝试更换 `target` |
| 握手成功但无流量 | `inbound connection to ...` 缺失 | UUID 不匹配或未带 `flow` | 核对 UUID 与 `flow=xtls-rprx-vision` |
| 客户端能连但很慢 | - | 握手目标链路质量差 | 更换 `target` 为就近且未受干扰的域名 |

导出 mihomo / Clash.Meta 格式配置：

```bash
sb clash mynode
```

## 安全说明

- 节点私钥保存在 `/etc/sing-box/nodes.json`，权限为 `600`（创建时即设为此权限）。
- Reality 握手目标默认为 `www.microsoft.com`；若需严格只与 GitHub 通信，可执行`sb target <名称> github.com`。
- 客户端必须使用 uTLS 浏览器指纹（默认 `chrome`）；`flow` 必须为 `xtls-rprx-vision`。
- 建议自行使用防火墙限制管理端口的来源地址。

## 许可

本项目基于 [sing-box](https://github.com/SagerNet/sing-box) 与早期 `sing-box` shell 脚本项目（原项目作者 233boy）修改而来，遵循 **GPL-3.0** 许可。原始版权声明保留于本仓库的`LICENSE` 与 `NOTICE` 文件中。

Notice: GPL-3.0 要求衍生作品保留原版权声明。

## 免责声明

本项目按「现状」提供，不附带任何形式的担保。使用者需自行确保其使用行为符合所在地区的法律与网络服务条款。
