#!/usr/bin/env bash
set -eEuo pipefail

cli_add_usage() {
  cat <<'EOF'
用法: xm add --protocol PROTOCOL [选项]

协议:
  reality         VLESS + Vision + Reality (TCP)
  xhttp-reality   VLESS + XHTTP + Reality
  grpc-reality    VLESS + gRPC + Reality
  ws              VLESS + WS + TLS + CDN
  xhttp-cdn       VLESS + XHTTP + TLS + CDN
  grpc-cdn        VLESS + gRPC + TLS + CDN
  argo            VLESS + WS/XHTTP/gRPC + Argo
  tuic            TUIC v5 (official tuic-server, UDP)
  hy2             Hysteria2 (official hysteria, UDP)

选项:
  --port PORT          监听端口；省略随机选择
  --name NAME          节点名称
  --sni DOMAIN         SNI；可用 auto 自动检测
  --uuid UUID          指定 UUID
  --password VALUE     指定密码
  --server-ip IP       分享链接使用的服务器 IP
  --direct-host HOST   直连协议使用的域名
  --cdn-host HOST      CDN 优选域名/地址
  --transport MODE     Argo 传输：ws / xhttp / grpc（默认 xhttp）
  --path PATH          WS/XHTTP 路径
  --service-name NAME  gRPC serviceName
  --argo-mode MODE     Argo 模式：temp / token（默认 temp）
  --argo-token TOKEN   Cloudflared 隧道 Token
  --endpoint-domain D  Argo 固定隧道域名
EOF
}

random_free_port() {
  local p
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    p=$(( (RANDOM * 32768 + RANDOM) % 50000 + 10000 ))
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q "[:.]${p} "; then
      continue
    fi
    printf '%s' "${p}"
    return 0
  done
  printf '%s' "443"
}

sni_candidates() {
  cat <<'EOF'
dl-cdn.alpinelinux.org
deb.debian.org
crates.io
pypi.org
rubygems.org
addons.mozilla.org
formulae.brew.sh
static.rust-lang.org
cpan.org
EOF
}

detect_sni_best() {
  local host t best="" best_t="999"
  command -v curl >/dev/null 2>&1 || return 1
  while IFS= read -r host; do
    [ -n "${host}" ] || continue
    t="$(curl -fsS --http2 --tlsv1.3 -o /dev/null --connect-timeout 3 --max-time 6 \
      -w '%{time_appconnect}' "https://${host}" 2>/dev/null || true)"
    [[ "${t}" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    if awk -v a="${t}" -v b="${best_t}" 'BEGIN { exit !(a < b) }'; then
      best="${host}"
      best_t="${t}"
    fi
  done < <(sni_candidates)
  [ -n "${best}" ] || return 1
  printf '%s' "${best}"
}

cli_sni() {
  local best
  print_info "正在检测 Reality SNI 候选（TLS 1.3 + HTTP/2）..."
  if best="$(detect_sni_best)"; then
    print_ok "推荐 SNI：${best}"
  else
    print_warn "自动检测失败，建议使用 pypi.org"
    return 1
  fi
}

# All option parsing finishes before auto_install may touch persistent state.
cli_require_value() {
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
    print_err "参数 ${1:-} 缺少值"
    return 2
  fi
}

cli_port_value() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
  local number=$((10#$1))
  [ "${number}" -ge 1 ] && [ "${number}" -le 65535 ] || return 1
  printf '%s' "${number}"
}

cli_add() {
  require_root
  local protocol="" port="" name="" sni="" uuid="" password="" server_ip="" direct_host=""
  local cdn_host="" transport="" path="" service_name="" argo_mode="" argo_token="" endpoint_domain=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --protocol|--port|--name|--sni|--uuid|--password|--server-ip|--direct-host|--cdn-host|--transport|--path|--service-name|--argo-mode|--argo-token|--endpoint-domain)
        cli_require_value "$@" || return 2 ;;
    esac
    case "$1" in
      --protocol) protocol="${2:-}"; shift 2 ;;
      --port) port="${2:-}"; shift 2 ;;
      --name) name="${2:-}"; shift 2 ;;
      --sni) sni="${2:-}"; shift 2 ;;
      --uuid) uuid="${2:-}"; shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --server-ip) server_ip="${2:-}"; shift 2 ;;
      --direct-host) direct_host="${2:-}"; shift 2 ;;
      --cdn-host) cdn_host="${2:-}"; shift 2 ;;
      --transport) transport="${2:-}"; shift 2 ;;
      --path) path="${2:-}"; shift 2 ;;
      --service-name) service_name="${2:-}"; shift 2 ;;
      --argo-mode) argo_mode="${2:-}"; shift 2 ;;
      --argo-token) argo_token="${2:-}"; shift 2 ;;
      --endpoint-domain) endpoint_domain="${2:-}"; shift 2 ;;
      -h|--help) cli_add_usage; return 0 ;;
      *) print_err "未知参数：$1"; cli_add_usage; return 2 ;;
    esac
  done
  [ -n "${protocol}" ] || { print_err "缺少 --protocol"; cli_add_usage; return 2; }
  if [ -z "${port}" ]; then
    port="$(random_free_port)"
  fi
  port="$(cli_port_value "${port}")" || { print_err "--port 必须为 1-65535 的整数"; return 2; }
  case "${protocol,,}" in
    reality|vless-reality|xhttp-reality|xhttp|grpc-reality|grpc|ws|vless-ws|vless-ws-tls|vless-ws-cdn|xhttp-cdn|grpc-cdn|argo|vless-argo|tuic|tuic-v5|tuic5|hysteria2|hy2) ;;
    *) print_err "不支持的协议：${protocol}"; return 2 ;;
  esac
  case "${transport}" in ''|ws|xhttp|grpc) ;; *) print_err "--transport 仅支持 ws/xhttp/grpc"; return 2 ;; esac
  case "${argo_mode}" in ''|temp|token) ;; *) print_err "--argo-mode 仅支持 temp/token"; return 2 ;; esac
  [ -n "${name}" ] || name="${protocol}-${port}"
  if [ "${sni}" = "auto" ]; then
    sni="$(detect_sni_best || printf 'pypi.org')"
  fi
  export name
  [ -n "${uuid}" ] && export uuid
  [ -n "${password}" ] && export passwd="${password}"
  [ -n "${server_ip}" ] && export server_ip
  [ -n "${direct_host}" ] && export direct_host
  [ -n "${cdn_host}" ] && export cdn_host
  [ -n "${path}" ] && export ws_path="${path}" xhttp_path="${path}"
  [ -n "${service_name}" ] && export grpc_service="${service_name}"
  case "${protocol,,}" in
    reality|vless-reality)
      export vlrt="${port}"
      [ -n "${sni}" ] && export vl_sni="${sni}"
      ;;
    xhttp-reality|xhttp)
      export xrpt="${port}"
      [ -n "${sni}" ] && export xr_sni="${sni}"
      ;;
    grpc-reality|grpc)
      export grpt="${port}"
      [ -n "${sni}" ] && export gr_sni="${sni}"
      ;;
    ws|vless-ws|vless-ws-tls|vless-ws-cdn)
      export wspt="${port}"
      [ -n "${sni}" ] && export ws_sni="${sni}"
      ;;
    xhttp-cdn)
      export xwpt="${port}"
      [ -n "${sni}" ] && export xw_sni="${sni}"
      ;;
    grpc-cdn)
      export gwpt="${port}"
      [ -n "${sni}" ] && export gw_sni="${sni}"
      ;;
    argo|vless-argo)
      export argo="vlpt" argo_pt="${port}"
      export argo_transport="${transport:-xhttp}"
      [ -n "${argo_mode}" ] && export argo_mode="${argo_mode}"
      [ -n "${argo_token}" ] && export argo_token="${argo_token}"
      [ -n "${endpoint_domain}" ] && export endpoint_domain="${endpoint_domain}"
      ;;
    tuic|tuic-v5|tuic5)
      export tupt="${port}"
      [ -n "${sni}" ] && export tu_sni="${sni}"
      ;;
    hysteria2|hy2)
      export hypt="${port}"
      [ -n "${sni}" ] && export hy_sni="${sni}"
      ;;
    *)
      print_err "不支持的协议：${protocol}"; return 2
      ;;
  esac
  auto_install ins
}

cli_status() {
  local n=0
  init_storage
  n="$(iter_node_tags | wc -l | tr -d ' ')"
  printf '版本: %s\n' "${SCRIPT_VERSION}"
  printf '服务: %s\n' "$(service_state)"
  printf '节点: %s\n' "${n}"
  printf '配置: %s\n' "${CONFIG_FILE}"
}

cli_doctor() {
  local fail=0
  init_storage
  printf '== %s doctor ==\n' "${SCRIPT_VERSION}"
  if [ -x "${XRAY_BIN}" ]; then
    print_ok "内核可执行"
  else
    print_err "内核不可执行：${XRAY_BIN}"
    fail=1
  fi
  if [ -s "${CONFIG_FILE}" ]; then
    print_ok "配置文件存在"
  else
    print_err "配置文件缺失：${CONFIG_FILE}"
    fail=1
  fi
  if [ -x "${XRAY_BIN}" ] && [ -s "${CONFIG_FILE}" ]; then
    if [ -n "${XRAY_BIN:-}" ] && "${XRAY_BIN}" run -test -c "${CONFIG_FILE}" >/dev/null 2>&1; then
      print_ok "配置校验通过"
    else
      print_err "配置校验失败"
      fail=1
    fi
  fi
  case "$(service_state)" in
    *运行中*) print_ok "服务运行中" ;;
    *) print_err "服务未运行"; fail=1 ;;
  esac
  if [ "${fail}" -eq 0 ]; then
    print_ok "doctor 检查通过"
  else
    print_warn "doctor 检查发现问题"
  fi
  return "${fail}"
}

cli_fw_usage() {
  cat <<'EOF'
用法: xm fw list
      xm fw open --port PORT [--proto tcp|udp]
      xm fw close --port PORT [--proto tcp|udp]

PORT 为 1-65535 的十进制整数。仅使用已启用的 ufw / firewalld；
否则操作已安装的 iptables 和 ip6tables，裸规则仅当前运行期生效。
EOF
}

cli_fw() {
  require_root
  local cmd="${1:-list}" port="" proto="tcp" backend="" ufw_status="" tool rc
  [ "$#" -eq 0 ] || shift
  case "${cmd}" in -h|--help) cli_fw_usage; return 0 ;; esac
  if [ "${cmd}" = list ] && [ "$#" -gt 0 ]; then
    print_err "用法: xm fw list"; return 2
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port|--proto) cli_require_value "$@" || return 2 ;;
    esac
    case "$1" in
      --port) port="$2"; shift 2 ;;
      --proto) proto="$2"; shift 2 ;;
      -h|--help) cli_fw_usage; return 0 ;;
      *) print_err "未知参数：$1"; cli_fw_usage; return 2 ;;
    esac
  done
  case "${cmd}" in
    list)
      [ -z "${port}" ] && [ "${proto}" = tcp ] || { print_err "用法: xm fw list"; return 2; }
      ;;
    open|close)
      port="$(cli_port_value "${port}")" || { print_err "--port 必须为 1-65535 的整数"; return 2; }
      case "${proto}" in tcp|udp) ;; *) print_err "--proto 仅支持 tcp/udp"; return 2 ;; esac
      ;;
    *) print_err "未知 fw 子命令：${cmd}"; cli_fw_usage; return 2 ;;
  esac

  if command -v ufw >/dev/null 2>&1; then
    ufw_status="$(LC_ALL=C ufw status)" || { print_err "无法读取 ufw 状态"; return 1; }
    if printf '%s\n' "${ufw_status}" | grep -Eq '^Status:[[:space:]]+active([[:space:]]|$)'; then
      backend=ufw
    elif ! printf '%s\n' "${ufw_status}" | grep -Eq '^Status:[[:space:]]+inactive([[:space:]]|$)'; then
      print_err "无法识别 ufw 状态"; return 1
    fi
  fi
  if [ -z "${backend}" ] && command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    backend=firewalld
  fi

  case "${backend}" in
    ufw)
      case "${cmd}" in
        list) printf '%s\n' "${ufw_status}"; return 0 ;;
        open) ufw allow "${port}/${proto}" || return 1 ;;
        close) ufw delete allow "${port}/${proto}" || return 1 ;;
      esac
      ;;
    firewalld)
      case "${cmd}" in
        list) firewall-cmd --list-all; return $? ;;
        open)
          firewall-cmd --add-port="${port}/${proto}" >/dev/null || return 1
          firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null || { print_err "运行期规则已添加，但永久规则保存失败"; return 1; }
          ;;
        close)
          firewall-cmd --remove-port="${port}/${proto}" >/dev/null || return 1
          firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null || { print_err "运行期规则已删除，但永久规则删除失败"; return 1; }
          ;;
      esac
      ;;
    *)
      local -a tools=() rule=(-p "${proto}" --dport "${port}" -j ACCEPT)
      for tool in iptables ip6tables; do
        if command -v "${tool}" >/dev/null 2>&1; then
          tools+=("${tool}")
          if [ "${cmd}" != list ]; then
            "${tool}" -S INPUT >/dev/null || { print_err "无法读取 ${tool} INPUT 规则"; return 1; }
          fi
        else
          print_warn "未检测到 ${tool}，对应地址族规则未处理。"
        fi
      done
      [ "${#tools[@]}" -gt 0 ] || { print_err "未检测到已启用的 ufw/firewalld 或 iptables/ip6tables"; return 1; }
      for tool in "${tools[@]}"; do
        case "${cmd}" in
          list) printf '== %s ==\n' "${tool}"; "${tool}" -S INPUT || return 1 ;;
          open|close)
            if "${tool}" -C INPUT "${rule[@]}" >/dev/null 2>&1; then
              if [ "${cmd}" = close ]; then
                "${tool}" -D INPUT "${rule[@]}" || return 1
              fi
            else
              rc=$?
              [ "${rc}" -eq 1 ] || { print_err "${tool} 规则检查失败（${rc}）"; return 1; }
              if [ "${cmd}" = open ]; then
                "${tool}" -I INPUT "${rule[@]}" || return 1
              fi
            fi
            ;;
        esac
      done
      [ "${cmd}" = list ] && return 0
      print_warn "裸 iptables/ip6tables 规则不会自动持久化，请自行保存。"
      ;;
  esac
  print_ok "防火墙${cmd}：${port}/${proto}"
}
