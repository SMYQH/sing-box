# sing-box 管理脚本 (VLESS + Reality)

一个精简、纯净的 sing-box 管理脚本，用于快速部署 VLESS + Reality 节点。

## 特性

- **零数据采集**：不收集、不上报任何用户数据与遥测信息。
- **仅连接 GitHub**：除 GitHub（`api.github.com` / `github.com`）外，脚本不会访问任何外部主机。
  - 不使用 IP 查询服务（如 `one.one.one.one`）获取公网 IP，公网 IP 从本机网卡读取。
  - 不内置第三方 DNS 服务器（Cloudflare / Google DoH），DNS 交由系统解析。
  - 不含 Caddy / ACME 自动证书签发，不与 Let's Encrypt 等 CA 通信。
- **无脚本自更新**：脚本不会自我更新或静默下载执行远端代码；内核更新为显式命令。
- **完整性校验**：下载内核时校验 GitHub Release 提供的 SHA-256 摘要。
- **配置预校验**：生成的配置先经 `sing-box check` 校验通过后才重启服务。
- 仅实现 VLESS + Reality 协议，代码量小、易审计。

## 环境要求

- Linux (x86_64 / arm64 / armv7 等)
- root 权限
- systemd (或 openrc)

## 安装

```bash
bash install.sh
```

或手动安装：

```bash
# 1. 安装依赖
apt-get update && apt-get install -y curl tar jq

# 2. 下载脚本到 /usr/local/lib/sing-box 并创建 /usr/local/bin/sb
#    (从 GitHub 仓库拉取)

# 3. 安装内核并注册服务
sb install
```

## 使用

```bash
sb add              # 添加节点 (交互式)
sb add mynode 443   # 添加节点 (指定名称与端口)
sb list             # 列出所有节点
sb show mynode      # 查看节点详情与分享链接
sb del mynode       # 删除节点
sb update           # 更新 sing-box 内核 (仅从 GitHub)
sb start|stop|restart|status
sb logs             # 查看服务日志
sb uninstall        # 卸载
sb help             # 帮助
```

不带参数运行 `sb` 进入交互式菜单。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `/etc/sing-box/bin/sing-box` | 内核二进制 |
| `/etc/sing-box/config.json` | 生成的配置 |
| `/etc/sing-box/nodes.json` | 节点清单 |
| `/etc/sing-box/conf/` | 额外配置目录 |
| `/usr/local/lib/sing-box/` | 管理脚本 |
| `/usr/local/bin/sb` | 管理命令入口 |

## 客户端参数

分享链接形如：

```
vless://<uuid>@<server>:<port>?encryption=none&flow=xtls-rprx-vision&security=reality&sni=<target>&fp=chrome&pbk=<public_key>&sid=<short_id>&type=tcp#<name>
```

其中 `pbk` 为 Public Key、`sid` 为 Short ID，二者由 `sb show <name>` 输出。

## 安全说明

- 节点私钥保存在 `/etc/sing-box/nodes.json`，权限为 `600`。
- Reality 握手目标默认为 `github.com`，因此服务端握手过程同样只与 GitHub 通信。
- 建议自行使用防火墙限制管理端口的来源地址。

## 许可

本项目基于 [sing-box](https://github.com/SagerNet/sing-box) 与早期 `sing-box` shell 脚本项目
(原项目作者 233boy) 修改而来，遵循 **GPL-3.0** 许可。原始版权声明保留于本仓库的
`LICENSE` 与 `NOTICE` 文件中。

GPL-3.0 要求衍生作品保留原版权声明，因此上述署名信息属于许可证义务，不属于推广内容。

## 免责声明

本项目按「现状」提供，不附带任何形式的担保。使用者需自行确保其使用行为符合所在地区
的法律与网络服务条款。
