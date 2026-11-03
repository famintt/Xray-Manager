#!/usr/bin/env bash
set -eEuo pipefail
umask 077

prompt_reality_sni() {
  local value detected
  while true; do
    value="$(prompt_with_default "Reality 域名（留空/auto 自动检测）" "auto")"
    case "${value,,}" in
    "" | auto)
      print_info "正在检测 Reality SNI ..." >&2
      detected="$(detect_sni_best 2>/dev/null || true)"
      if [ -n "$detected" ]; then
        printf '%s' "$detected"
        return 0
      fi
      print_warn "自动检测失败，回退 ${DEFAULT_REALITY_SERVER}。" >&2
      printf '%s' "${DEFAULT_REALITY_SERVER}"
      return 0
      ;;
    *)
      if is_safe_domain "$value"; then
        printf '%s' "$value"
        return 0
      fi
      print_warn "域名格式无效：${value}"
      ;;
    esac
  done
}

prompt_tls_sni() {
  local value detected
  while true; do
    value="$(prompt_with_default "SNI 域名（留空=${DEFAULT_TLS_SERVER}；auto 自动检测）" "${DEFAULT_TLS_SERVER}")"
    case "${value,,}" in
    "")
      printf '%s' "${DEFAULT_TLS_SERVER}"
      return 0
      ;;
    auto)
      detected="$(detect_sni_best 2>/dev/null || true)"
      if [ -n "$detected" ]; then
        printf '%s' "$detected"
        return 0
      fi
      printf '%s' "${DEFAULT_TLS_SERVER}"
      return 0
      ;;
    *)
      if is_safe_domain "$value"; then
        printf '%s' "$value"
        return 0
      fi
      print_warn "域名格式无效：${value}"
      ;;
    esac
  done
}

_gen_reality_keys() {
  local out
  out="$("${XRAY_BIN}" x25519 2>/dev/null || true)"
  if [ -z "$out" ]; then
    out="$("${XRAY_BIN}" generate reality-keypair 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

_reality_key() {
  local output="$1" kind="$2"
  if [ "$kind" = "private" ]; then
    printf '%s\n' "$output" | sed -n 's/^Private[Kk]ey:[[:space:]]*//p; s/^Private key:[[:space:]]*//p' | head -n1
  else
    printf '%s\n' "$output" | sed -n 's/^Public[Kk]ey:[[:space:]]*//p; s/^Password [Pp]ublic[Kk]ey:[[:space:]]*//p; s/^Password (PublicKey):[[:space:]]*//p; s/^Public key:[[:space:]]*//p' | head -n1
  fi
}

_add_vless_reality() {
  local proto="$1" default_port="$2" default_name="$3" network="$4"
  local tag port name uuid reality_server path key_output private_key public_key short_id node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "$proto")"
  port="$(prompt_port "$default_port")"
  name="$(prompt_with_default "节点名称" "$default_name")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  reality_server="$(prompt_reality_sni)"
  if [ "$network" = "tcp" ]; then
    path=""
  elif [ "$network" = "grpc" ]; then
    path="$(prompt_with_default "gRPC serviceName" "xm-$(generate_hex 4)")"
  else
    path="$(prompt_with_default "XHTTP 路径" "/$(generate_hex 4)")"
  fi
  key_output="$(_gen_reality_keys)"
  private_key="$(_reality_key "$key_output" private)"
  public_key="$(_reality_key "$key_output" public)"
  [ -n "$private_key" ] && [ -n "$public_key" ] || fatal "无法生成 Reality 密钥（当前 Xray 版本不支持 x25519？）"
  short_id="$(generate_hex 4)"
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "$proto" --arg name "$name" --argjson port "$port" \
    --arg reality_server "$reality_server" --arg public_key "$public_key" \
    --arg short_id "$short_id" --arg ws_path "$path" \
    '{protocol:$protocol,name:$name,port:$port,reality_server:$reality_server,public_key:$public_key,short_id:$short_id}
     + (if $ws_path == "" then {} else {ws_path:$ws_path} end)')"
  secret_json="$(jq -n --arg uuid "$uuid" --arg private_key "$private_key" '{uuid:$uuid,private_key:$private_key}')"
  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi
  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_reality() { _add_vless_reality "vless-reality" 443 "VLESS-Vision-Reality" tcp; }
add_vless_xhttp_reality() { _add_vless_reality "vless-xhttp-reality" 8443 "VLESS-XHTTP-Reality" xhttp; }
add_vless_grpc_reality() { _add_vless_reality "vless-grpc-reality" 8444 "VLESS-gRPC-Reality" grpc; }

_add_vless_cdn() {
  local proto="$1" default_port="$2" default_name="$3" transport="$4"
  local tag port name uuid domain host_domain path cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "$proto")"
  port="$(prompt_port "$default_port")"
  name="$(prompt_with_default "节点名称" "$default_name")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  domain="$(prompt_cdn_domain)"
  host_domain="$domain"
  case "$transport" in
  grpc) path="$(prompt_with_default "gRPC serviceName" "xm-$(generate_hex 4)")" ;;
  ws) path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")" ;;
  *) path="$(prompt_with_default "XHTTP 路径" "/$(generate_hex 4)")" ;;
  esac
  cert_bundle="$(prompt_certificate_bundle "$tag" "$host_domain")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "$proto" --arg name "$name" --argjson port "$port" \
    --arg preferred_domain "$domain" --arg host_domain "$host_domain" \
    --arg ws_path "$path" --arg ws_mode "cdn" --argjson cdn_port 443 \
    --arg cdn_sni "$domain" --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" --arg key_path "$key_file" \
    '{protocol:$protocol,name:$name,port:$port,preferred_domain:$preferred_domain,
      host_domain:$host_domain,ws_path:$ws_path,ws_mode:$ws_mode,cdn_port:$cdn_port,
      cdn_sni:$cdn_sni,certificate_mode:$certificate_mode,
      certificate_path:$certificate_path,key_path:$key_path}')"
  secret_json="$(jq -n --arg uuid "$uuid" '{uuid:$uuid}')"
  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi
  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_ws_cdn() { _add_vless_cdn "vless-ws-cdn" 8443 "VLESS-WS-TLS-CDN" ws; }
add_vless_xhttp_cdn() { _add_vless_cdn "vless-xhttp-cdn" 8444 "VLESS-XHTTP-TLS-CDN" xhttp; }
add_vless_grpc_cdn() { _add_vless_cdn "vless-grpc-cdn" 8445 "VLESS-gRPC-TLS-CDN" grpc; }

add_vless_argo() {
  local tag port name uuid transport preferred_domain ws_path argo_mode argo_token endpoint_domain node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "vless-${transport}-argo")"
  port="$(prompt_port 8001)"
  name="$(prompt_with_default "节点名称" "VLESS-XHTTP-Argo")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  transport="$(prompt_choice "传输 (ws/xhttp/grpc)" "xhttp")"
  case "$transport" in
  ws | grpc | xhttp) ;;
  *) transport="xhttp" ;;
  esac
  if [ "$transport" = "grpc" ]; then
    ws_path="$(prompt_with_default "gRPC serviceName" "xm-$(generate_hex 4)")"
  elif [ "$transport" = "ws" ]; then
    ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")"
  else
    ws_path="$(prompt_with_default "XHTTP 路径" "/$(generate_hex 4)")"
  fi
  preferred_domain="$(prompt_optional_value "CDN 优选域名（Argo 可留空）")"
  argo_mode="$(prompt_choice "隧道模式 (temp/token)" "temp")"
  if [ "$argo_mode" = "token" ]; then
    argo_token="$(prompt_nonempty "Cloudflared 隧道 Token")"
    endpoint_domain="$(prompt_nonempty "Argo 回源域名")"
  else
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "vless-${transport}-argo" --arg name "$name" --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" --arg endpoint_domain "$endpoint_domain" \
    '{protocol:$protocol,name:$name,port:$port,preferred_domain:$preferred_domain,
      ws_path:$ws_path,argo_mode:$argo_mode,endpoint_domain:$endpoint_domain}')"
  secret_json="$(jq -n --arg uuid "$uuid" --arg argo_token "$argo_token" '{uuid:$uuid,argo_token:$argo_token}')"
  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service || ! start_argo_node "$tag"; then
    stop_argo_node "$tag" 2>/dev/null || true
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi
  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_tuic() {
  local tag port name uuid password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  ensure_tuic_core || fatal "官方 tuic-server 安装失败。"
  tag="$(generate_tag "tuic-v5")"
  port="$(prompt_port 11444)"
  name="$(prompt_with_default "节点名称" "TUIC-v5")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_tls_sni)"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"
  acquire_lock
  node_json="$(jq -n     --arg protocol "tuic-v5" --arg name "$name" --argjson port "$port"     --arg tls_server "$tls_server" --arg certificate_mode "$cert_mode"     --arg certificate_path "$cert_file" --arg key_path "$key_file"     '{protocol:$protocol,name:$name,port:$port,tls_server:$tls_server,
      certificate_mode:$certificate_mode,certificate_path:$certificate_path,
      key_path:$key_path}')"
  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{uuid:$uuid,password:$password}')"
  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi
  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_hy2() {
  local tag port name password tls_server cert_bundle cert_mode cert_file key_file up_mbps down_mbps node_json secret_json
  ensure_singbox_ready
  ensure_hysteria_core || fatal "官方 hysteria 安装失败。"
  tag="$(generate_tag "hy2")"
  port="$(prompt_port 11443)"
  name="$(prompt_with_default "节点名称" "Hysteria2")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_tls_sni)"
  up_mbps="$(prompt_optional_value "上行 Mbps（留空 200，0 不限速）")"
  up_mbps="${up_mbps:-200}"
  down_mbps="$(prompt_optional_value "下行 Mbps（留空 200，0 不限速）")"
  down_mbps="${down_mbps:-200}"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "hy2" --arg name "$name" --argjson port "$port" \
    --arg tls_server "$tls_server" --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" --arg key_path "$key_file" \
    --argjson up_mbps "$up_mbps" --argjson down_mbps "$down_mbps" \
    '{protocol:$protocol,name:$name,port:$port,tls_server:$tls_server,
      certificate_mode:$certificate_mode,certificate_path:$certificate_path,
      key_path:$key_path,up_mbps:$up_mbps,down_mbps:$down_mbps}')"
  secret_json="$(jq -n --arg password "$password" '{password:$password}')"
  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi
  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}
