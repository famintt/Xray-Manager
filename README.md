# Xray Manager（xm）

面向 `Xray-core` 的一键安装 / 节点管理脚本：安装核心、创建节点、生成分享链接、自动保活和订阅上报一体化。项目代号 `xm`，默认安装到 `/usr/local/bin/xm`。

## 支持协议

**Xray 主核心：**

- `VLESS + Vision + Reality`
- `VLESS + XHTTP + Reality`
- `VLESS + gRPC + Reality`
- `VLESS + WS + TLS + CDN`
- `VLESS + XHTTP + TLS + CDN`
- `VLESS + gRPC + TLS + CDN`
- `VLESS + WS / XHTTP / gRPC + Argo`

**官方 sidecar：**

- `TUIC v5`：官方 [`tuic-server`](https://github.com/tuic-protocol/tuic)
- `Hysteria2`：官方 [`hysteria`](https://github.com/HyNetworks/hysteria)

TUIC/Hysteria2 只在选择对应协议时下载和安装；不选择不会拉取。两者使用 UDP/QUIC，独立于 Xray 进程运行，由 `xm` 和 watchdog 管理。

CDN 默认传输为 **VLESS + XHTTP**；Argo 临时隧道实测推荐 **WS**（Quick Tunnel 回源是 HTTP/1.1，XHTTP 可能握手失败），界面和命令行都可切换 WS / XHTTP / gRPC。

## 快速安装

```bash
bash <(curl -fsSL https://github.com/famintt/Xray-Manager/releases/latest/download/install.sh)
xm
```

无 curl 的系统可用：

```bash
bash <(wget -qO- https://github.com/famintt/Xray-Manager/releases/latest/download/install.sh)
```

## 环境变量一键安装

端口变量填了即启用；`rep` 清空重建，`ins` 追加：

```bash
vlrt=2083 xrpt=8443 grpt=8444 \
wspt=2053 xwpt=2087 gwpt=2096 \
tupt=11444 hypt=11443 \
name='HK' xm rep
```

| 变量 | 说明 |
|---|---|
| `vlrt` | VLESS + Vision + Reality 端口 |
| `xrpt` | VLESS + XHTTP + Reality 端口 |
| `grpt` | VLESS + gRPC + Reality 端口 |
| `wspt` | VLESS + WS + TLS + CDN 源站回源端口 |
| `xwpt` | VLESS + XHTTP + TLS + CDN 源站回源端口 |
| `gwpt` | VLESS + gRPC + TLS + CDN 源站回源端口 |
| `tupt` | 官方 TUIC v5 端口（UDP） |
| `hypt` | 官方 Hysteria2 端口（UDP） |
| `argo=vlpt` | 启用 Argo；`argo_pt` 为本地端口，默认 8001 |
| `argo_transport` | Argo 传输：`ws` / `xhttp` / `grpc`，默认 `xhttp` |
| `vl_sni` / `xr_sni` / `gr_sni` | 三种 Reality 的 SNI，默认 `www.bing.com` |
| `ws_sni` / `xw_sni` / `gw_sni` | 三种 CDN 的 SNI，默认 `www.apple.com` |
| `tu_sni` / `hy_sni` | TUIC / Hysteria2 的 SNI，默认 `www.apple.com` |
| `cdn_host` / `cdn_port` | CDN 优选域名/地址和客户端连接端口 |
| `ws_cert_mode` | `self`（默认自签，Cloudflare Full）或 `custom`（Origin CA，Full Strict） |
| `name` / `uuid` / `passwd` | 节点名、UUID、密码（TUIC/HY2 使用密码） |

## 协议与链接

- Reality：`security=reality&pbk=&sid=&fp=chrome`；Vision 仅 `vless-reality` 带 `flow=xtls-rprx-vision`。
- CDN：`security=tls`，客户端连接 `cdn_host:cdn_port`；`wspt/xwpt/gwpt` 是源站回源端口。
- Argo：默认 `xhttp`，链接使用临时/固定隧道域名，端口 443；`argo_transport` 可切换。
- TUIC：`tuic://uuid:password@host:port?congestion_control=bbr&alpn=h3&sni=...&udp_relay_mode=native`
- Hysteria2：`hysteria2://password@host:port?sni=...`
- 自签证书默认追加 `insecure=1` / `allow_insecure=1`。

## CDN 与 Argo

- CDN 回源自签证书时，Cloudflare SSL/TLS 选 **Full**；选 **Full (Strict)** 需要 Origin CA 或受信证书。
- `wspt/xwpt/gwpt` 不是 443 时，在 Cloudflare 添加 **Origin Rule**，把 443 回源改写到对应端口。
- Argo 临时隧道域名自动分配；固定隧道需填 `endpoint_domain` 和 `argo_token`。
- Argo 默认使用 XHTTP；可在界面/命令行选择 WS 或 gRPC。

## 官方 TUIC / Hysteria2

- 仅在启用 `tupt` / `hypt` 时按架构下载官方二进制并校验 SHA256：

```text
/usr/local/bin/tuic-server
/usr/local/bin/hysteria
```

- 配置路径：

```text
/usr/local/etc/xray-manager/tuic.json
/usr/local/etc/xray-manager/hysteria.yaml
```

- TUIC v5 使用 `uuid` + `password`；Hysteria2 使用 `password`；默认自签证书，复用 SNI。
- 两个 sidecar 不创建独立 systemd unit，由 `xm` 启动流程和 watchdog 管理。

## 常用命令

```bash
xm                 # 交互菜单
xm list            # 节点与分享链接
xm add --protocol reality --port 2083 --sni www.bing.com
xm add --protocol xhttp-reality --port 8443
xm add --protocol tuic --port 11444 --sni www.apple.com
xm add --protocol hy2 --port 11443
xm status
xm restart
xm un
```

## 目录

```text
/usr/local/bin/xm
/usr/local/bin/xray
/usr/local/lib/xray-manager/
/usr/local/etc/xray-manager/
  config.json          # Xray 主配置
  tuic.json            # TUIC sidecar 配置
  hysteria.yaml        # Hysteria2 sidecar 配置
  nodes.json
  secrets.json
  certs/
  logs/
```

## 项目结构

```text
xm.sh / mtp.sh / install.sh / lib/*.sh / metadata/upstream.env
lib/core.sh                   官方 TUIC/Hysteria2 安装、配置、启停
lib/render.sh                 Xray + sidecar 配置生成
scripts/watchdog.sh           保活
scripts/build-release-bundle.sh
interface/                    网页命令生成器（Pages / Workers）
tests/smoke.sh                冒烟测试
```

## NAT 端口与资源说明

部分云厂商的 NAT 实例只映射指定端口，**本机监听成功不等于公网可用**。部署后应分别验证：

1. **TCP**：用真实客户端完成一次 VLESS 握手并访问 `http://cp.cloudflare.com/`，不要只做 `nc`/`socket.connect`；端口能连但无 TLS 响应，通常表示公网端口指向了其他后端。
2. **UDP**：TUIC/HY2 必须从客户端实际发一次 UDP DNS 查询（例如 `8.8.8.8:53`）验证，不能只看进程或 `ss` 监听。
3. **TUIC 客户端必须带 ALPN `h3`**，否则常见错误是 `tls: no application protocol`；HY2 同样需要正确的 SNI。
4. 128MB/1vCPU 的 NAT 实例建议**逐台、低并发**部署，不要同时批量安装多个协议；安装前后检查 `free -m` 和 `uptime`。
5. Cloudflare Quick Tunnel（Argo 临时隧道）回源是 HTTP/1.1，实测 **WS 传输可用，XHTTP 传输在 quick tunnel 下可能握手失败**；Argo 临时隧道优先选 `--transport ws`。若必须使用 XHTTP，请改用支持 HTTP/2 回源的命名隧道/反向代理方案。

### 2026-11-03 NAT 实测记录

| 主机 | Vision | XHTTP | TUIC | HY2 | Argo WS | 备注 |
|---|---|---|---|---|---|---|
| CA-Oracle-nat | 204 | 204 | TCP+UDP | TCP+UDP | 204 | 5 节点内存约 57MB |
| UK-Oracle-nat | 204 | 204 | TCP+UDP | TCP+UDP | 204 | 全部通过 |
| SGW-Oracle-nat | 映射错误 | 204 | TCP+UDP | TCP 通/UDP 超时 | 204 | Vision 21001 指向 Microsoft 证书 |
| IL-Oracle-nat | 204 | 204 | TCP+UDP | TCP 通/UDP 超时 | 204 | HY2 UDP 端口疑似未映射 |
| JP-Oracle-TKY-nat-3 | 204 | 204 | 超时 | TCP+UDP | 204 | TUIC 21013 公网未通 |
| JP-Oracle-OSA-nat | 204 | 204 | 超时 | TCP+UDP | 204 | TUIC 21088 公网未通 |
| MX-Oracle-nat | 204 | 204 | 超时 | TCP+UDP | 204 | TUIC 21148 公网未通 |
| JP-Oracle-TKY-nat-1 | 超时 | 超时 | 超时 | 超时 | 204 | 21276-21279 公网未通，仅 Argo 通 |
| JP-Oracle-TKY-nat-2 | 超时 | 超时 | 超时 | TCP 000 / UDP 通 | 204 | 21096/21097 未通，HY2 UDP 可通 |
| DE-Oracle-FRA-nat | 超时 | 超时 | 超时 | TCP 204 / UDP 超时 | 204 | 21131-21133 未通，HY2 TCP 可通 |
| US-Oracle-SJC-nat-1 | 超时 | 超时 | TCP+UDP | TCP+UDP | 204 | 21036/21037 未通，UDP 21038/21039 正常 |
| US-Oracle-SJC-nat-2 | 超时 | 超时 | 超时 | TCP+UDP | 204 | 21091/21092/21093 未通，HY2 21094 正常 |

- 12 台 NAT 均已安装 XM 并可 SSH；SJC1/SJC2 已补测，公网端口映射按上表记录。
- 表内 TUIC/UDP 失败的主机，服务端 `tuic-server` 均正常监听；优先怀疑 NAT 的 UDP 端口映射/安全组，不应直接改代码。
- JP1/JP2/FRA 的 Vision/XHTTP 公网 TCP 也无 TLS 响应，说明不仅是 UDP 问题，而是对应 TCP 端口未真正转发；Argo 仍可用是因为它走 Cloudflare 出站，不依赖入站映射。
- 128MB/1vCPU 主机实测可稳定运行 5 节点（Xray + TUIC + HY2 + cloudflared），内存约 40–67MB；仍建议逐台部署并观察 `free -m`。

## 说明

- 本项目是独立项目，不修改 sbm/mm；生产使用前请先在测试机验证客户端实际连通。
- `xm rep` 会清空全部节点；执行前自动备份到 `backups/`。
- Argo 临时域名会变化，以 `xm list` 最新输出为准。
- 默认不自动推送 GitHub。
