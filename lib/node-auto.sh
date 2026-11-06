#!/usr/bin/env bash
set -eEuo pipefail
umask 077

resolve_short_ids() {
  local raw="$1" tok out=""
  local -a tokens
  [ -n "${raw}" ] || return 1
  raw="$(printf '%s' "${raw}" | tr -d ' \r\n')"
  IFS=',' read -r -a tokens <<<"${raw}"
  for tok in "${tokens[@]}"; do
    if [[ "${tok}" =~ ^[0-9a-fA-F]+$ ]] && [ $((${#tok} % 2)) -eq 0 ] &&
      [ "${#tok}" -ge 2 ] && [ "${#tok}" -le 32 ]; then
      [ -n "${out}" ] && out="${out},"
      out="${out}${tok,,}"
    fi
  done
  [ -n "${out}" ] || return 1
  printf '%s' "${out}"
}

tls_sni_auto() {
  local key="$1" fallback="$2" raw mode
  raw="$(env_var "${key}")"
  mode="$(env_var "cert")"
  mode="${mode:-self}"
  case "${raw,,}" in
  "")
    env_domain_or_default "${key}" "${fallback}"
    ;;
  auto)
    if [ "${mode}" = "custom" ]; then
      print_warn "${key}=auto 不能用于自定义证书，回退 ${fallback}。"
      printf '%s' "${fallback}"
      return 0
    fi
    if [ -n "${TLS_SNI_AUTO_CACHE:-}" ]; then
      printf '%s' "${TLS_SNI_AUTO_CACHE}"
      return 0
    fi
    print_info "正在检测 TLS SNI（TLS 1.3 + HTTP/2，自签证书）..." >&2
    TLS_SNI_AUTO_CACHE="$(detect_sni_best 2>/dev/null || printf '%s' "${fallback}")"
    printf '%s' "${TLS_SNI_AUTO_CACHE}"
    ;;
  *)
    env_domain_or_default "${key}" "${fallback}"
    ;;
  esac
}

auto_cert_bundle() {
  local tag="$1" domain="$2"
  local __mode __cert_path __key_path __cert_b64 __key_b64 __pair
  __mode="$(env_var "cert")"
  __mode="${__mode:-self}"
  if [ "${__mode}" = "custom" ]; then
    __cert_b64="$(env_var "cert_b64")"
    __key_b64="$(env_var "key_b64")"
    if [ -n "$__cert_b64" ] || [ -n "$__key_b64" ]; then
      if [ -n "$__cert_b64" ] && [ -n "$__key_b64" ] && __pair="$(import_custom_certificate_content "$tag" "$__cert_b64" "$__key_b64")"; then
        printf 'custom|%s|%s' "${__pair%|*}" "${__pair#*|}"
        return 0
      fi
      print_warn "cert_b64/key_b64 解码失败，节点 ${tag} 回退自签证书。"
      __pair="$(ensure_tls_material "$tag" "$domain")"
      printf 'self-signed|%s|%s' "${__pair%|*}" "${__pair#*|}"
      return 0
    fi
    __cert_path="$(env_var "cert_path")"
    __key_path="$(env_var "key_path")"
    if [ -n "$__cert_path" ] && [ -n "$__key_path" ] && __pair="$(import_custom_certificate_bundle "$tag" "$__cert_path" "$__key_path")"; then
      printf 'custom|%s|%s' "${__pair%|*}" "${__pair#*|}"
      return 0
    fi
    print_warn "自定义证书不可用，节点 ${tag} 回退自签证书。"
  elif [ "${__mode}" != "self" ] && [ "${__mode}" != "self-signed" ]; then
    print_warn "未知证书模式 cert=${__mode}，节点 ${tag} 使用自签证书。"
  fi
  __pair="$(ensure_tls_material "$tag" "$domain")"
  printf 'self-signed|%s|%s' "${__pair%|*}" "${__pair#*|}"
}

auto_reality_keys() {
  local key_output
  if [ -z "${AUTO_REALITY_PRIVATE:-}" ] || [ -z "${AUTO_REALITY_PUBLIC:-}" ]; then
    key_output="$("${XRAY_BIN}" x25519 2>/dev/null || "${XRAY_BIN}" generate reality-keypair 2>/dev/null || true)"
    AUTO_REALITY_PRIVATE="$(printf '%s\n' "$key_output" | sed -n 's/^Private[Kk]ey:[[:space:]]*//p; s/^Private key:[[:space:]]*//p' | head -n1)"
    AUTO_REALITY_PUBLIC="$(printf '%s\n' "$key_output" | sed -n 's/^Public[Kk]ey:[[:space:]]*//p; s/^Password [Pp]ublic[Kk]ey:[[:space:]]*//p; s/^Password (PublicKey):[[:space:]]*//p; s/^Public key:[[:space:]]*//p' | head -n1)"
    [ -n "${AUTO_REALITY_PRIVATE}" ] && [ -n "${AUTO_REALITY_PUBLIC}" ] || return 1
    set_setting "reality_private" "${AUTO_REALITY_PRIVATE}" || true
    set_setting "reality_public" "${AUTO_REALITY_PUBLIC}" || true
  fi
  if ! AUTO_SHORT_ID="$(resolve_short_ids "$(env_var "short_ids")")"; then
    AUTO_SHORT_ID="$(generate_hex 4)"
  fi
}

auto_add_reality() {
  local proto="$1" port="$2" network="$3" name_suffix="$4" sni="$5"
  local tag uuid path node_json secret_json
  tag="$(generate_tag "$proto")"
  uuid="${ENV_UUID:-$(generate_uuid)}"
  case "$network" in
  tcp) path="" ;;
  grpc) path="$(env_var "grpc_service")"; path="${path:-xm-$(generate_hex 4)}" ;;
  *) path="$(env_var "xhttp_path")"; path="${path:-/$(generate_hex 4)}" ;;
  esac
  if ! auto_reality_keys; then
    print_err "生成 Reality 密钥失败，跳过 ${proto}。"
    return 1
  fi
  node_json="$(jq -n \
    --arg protocol "$proto" --arg name "$(auto_node_name "$name_suffix")" \
    --argjson port "$port" --arg reality_server "$sni" \
    --arg public_key "$AUTO_REALITY_PUBLIC" --arg short_id "$AUTO_SHORT_ID" \
    --arg ws_path "$path" \
    '{protocol:$protocol,name:$name,port:$port,reality_server:$reality_server,
      public_key:$public_key,short_id:$short_id}
     + (if $ws_path == "" then {} else {ws_path:$ws_path} end)')"
  secret_json="$(jq -n --arg uuid "$uuid" --arg private_key "$AUTO_REALITY_PRIVATE" '{uuid:$uuid,private_key:$private_key}')"
  auto_save_node "$tag" "$node_json" "$secret_json"
}

auto_node_name() {
  local suffix="$1"
  if [ -n "${ENV_NAME:-}" ]; then printf '%s-%s' "${ENV_NAME}" "$suffix"; else printf '%s' "$suffix"; fi
}

auto_add_cdn() {
  local proto="$1" port="$2" transport="$3" name_suffix="$4" sni="$5" host="$6"
  local tag uuid path cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "$proto")"
  uuid="${ENV_UUID:-$(generate_uuid)}"
  case "$transport" in
  grpc) path="$(env_var "grpc_service")"; path="${path:-xm-$(generate_hex 4)}" ;;
  ws) path="$(env_var "ws_path")"; path="${path:-$(random_ws_path)}" ;;
  *) path="$(env_var "xhttp_path")"; path="${path:-/$(generate_hex 4)}" ;;
  esac
  local cdn_port="${ENV_CDN_PORT:-443}"
  cert_bundle="$(auto_cert_bundle "$tag" "$sni")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"
  node_json="$(jq -n \
    --arg protocol "$proto" --arg name "$(auto_node_name "$name_suffix")" \
    --argjson port "$port" --arg preferred_domain "$host" --arg host_domain "$sni" \
    --arg ws_path "$path" --arg ws_mode "cdn" --argjson cdn_port "$cdn_port" \
    --arg cdn_sni "$sni" --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" --arg key_path "$key_file" \
    '{protocol:$protocol,name:$name,port:$port,preferred_domain:$preferred_domain,
      host_domain:$host_domain,ws_path:$ws_path,ws_mode:$ws_mode,cdn_port:$cdn_port,
      cdn_sni:$cdn_sni,certificate_mode:$certificate_mode,
      certificate_path:$certificate_path,key_path:$key_path}')"
  secret_json="$(jq -n --arg uuid "$uuid" '{uuid:$uuid}')"
  auto_save_node "$tag" "$node_json" "$secret_json"
}

auto_add_argo() {
  # 注意：不要声明名为 argo_mode/endpoint_domain/argo_token 的 local 变量。
  # env_var 使用 Bash 间接展开；同名 local 会遮蔽环境变量，导致 token 模式被误判为 temp。
  local port="$1" transport node_json secret_json tag uuid path
  local node_argo_mode node_endpoint_domain node_argo_token
  local argo_host="${ENV_ARGO_CDN_HOST:-${ENV_CDN_HOST}}"
  transport="$(auto_argo_transport)"
  tag="$(generate_tag "vless-${transport}-argo")"
  uuid="${ENV_UUID:-$(generate_uuid)}"
  case "$transport" in
  grpc) path="$(env_var "grpc_service")"; path="${path:-xm-$(generate_hex 4)}" ;;
  ws) path="$(env_var "ws_path")"; path="${path:-$(random_ws_path)}" ;;
  *) path="$(env_var "xhttp_path")"; path="${path:-/$(generate_hex 4)}" ;;
  esac
  node_argo_mode="$(env_var "argo_mode")"; node_argo_mode="${node_argo_mode:-temp}"
  if [ "$node_argo_mode" = "token" ]; then
    node_argo_token="$(env_var "argo_token")"
    node_endpoint_domain="$(env_var "endpoint_domain")"
  else
    node_argo_mode="temp"; node_argo_token=""; node_endpoint_domain=""
  fi
  node_json="$(jq -n \
    --arg protocol "vless-${transport}-argo" --arg name "$(auto_node_name "Argo")" \
    --argjson port "$port" --argjson cdn_port "${ENV_ARGO_CDN_PORT:-443}" --arg preferred_domain "$argo_host" \
    --arg ws_path "$path" --arg argo_mode "$node_argo_mode" --arg endpoint_domain "$node_endpoint_domain" \
    '{protocol:$protocol,name:$name,port:$port,preferred_domain:$preferred_domain,cdn_port:$cdn_port,
      ws_path:$ws_path,argo_mode:$argo_mode,endpoint_domain:$endpoint_domain}')"
  secret_json="$(jq -n --arg uuid "$uuid" --arg argo_token "$node_argo_token" '{uuid:$uuid,argo_token:$argo_token}')"
  auto_save_node "$tag" "$node_json" "$secret_json"
}

auto_add_tuic() {
  local port="$1" tag uuid password cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "tuic-v5")"
  uuid="${ENV_UUID:-$(generate_uuid)}"
  password="${ENV_PASSWD:-$(generate_hex 8)}"
  cert_bundle="$(auto_cert_bundle "$tag" "${ENV_TU_SNI}")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"
  node_json="$(jq -n     --arg protocol "tuic-v5" --arg name "$(auto_node_name "TUIC")" --argjson port "$port"     --arg tls_server "${ENV_TU_SNI}" --arg certificate_mode "$cert_mode"     --arg certificate_path "$cert_file" --arg key_path "$key_file"     '{protocol:$protocol,name:$name,port:$port,tls_server:$tls_server,
      certificate_mode:$certificate_mode,certificate_path:$certificate_path,
      key_path:$key_path}')"
  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{uuid:$uuid,password:$password}')"
  auto_save_node "$tag" "$node_json" "$secret_json"
}

auto_add_hy2() {
  local port="$1" tag uuid password cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "hy2")"
  uuid=""
  password="${ENV_PASSWD:-$(generate_hex 8)}"
  cert_bundle="$(auto_cert_bundle "$tag" "${ENV_HY_SNI}")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"
  node_json="$(jq -n \
    --arg protocol "hy2" --arg name "$(auto_node_name "HY2")" --argjson port "$port" \
    --arg tls_server "${ENV_HY_SNI}" --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" --arg key_path "$key_file" \
    --argjson up_mbps 0 --argjson down_mbps 0 \
    '{protocol:$protocol,name:$name,port:$port,tls_server:$tls_server,
      certificate_mode:$certificate_mode,certificate_path:$certificate_path,
      key_path:$key_path,up_mbps:$up_mbps,down_mbps:$down_mbps}')"
  secret_json="$(jq -n --arg password "$password" '{password:$password}')"
  auto_save_node "$tag" "$node_json" "$secret_json"
}

auto_install() {
  local action="$1" tag port spec line backup_dir
  local added=0 failed=0
  local -a specs=()
  local ENV_NAME ENV_UUID ENV_PASSWD
  local ENV_VL_SNI ENV_XR_SNI ENV_GR_SNI ENV_WS_SNI ENV_XW_SNI ENV_GW_SNI ENV_HY_SNI ENV_TU_SNI
  local ENV_CDN_HOST ENV_CDN_PORT ENV_ARGO_CDN_HOST ENV_ARGO_CDN_PORT ENV_WS_PATH ENV_ARGO_MODE ENV_ARGO_TRANSPORT
  local AUTO_REALITY_PRIVATE AUTO_REALITY_PUBLIC AUTO_SHORT_ID

  if [ -x /usr/local/bin/mm ] || [ -f /usr/local/etc/mihomo-manager/settings.json ]; then
    print_warn "检测到 Mihomo Manager。xm 与 mm 共用 cloudflared，且可能占用相同端口；建议同机只保留一套。"
  fi

  init_storage
  if ! auto_has_node_env; then
    print_err "未检测到任何节点环境变量（vlrt / xrpt / grpt / wspt / xwpt / gwpt / tupt / hypt / argo），放弃安装。"
    print_info "示例：vlrt=2083 xrpt=2084 xwpt=2085 argo=vlpt tupt=2086 hypt=2082 name='HK' xm ${action}"
    exit 1
  fi
  if ! spec="$(auto_collect_specs)"; then
    print_err "输入校验失败，未更改任何数据。"
    exit 1
  fi
  while IFS= read -r line; do [ -n "${line}" ] && specs+=("${line}"); done <<<"${spec}"
  [ "${#specs[@]}" -gt 0 ] || { print_err "未检测到有效端口变量，放弃安装。"; exit 1; }

  ensure_singbox_ready
  ensure_aux_cores_for_env || { print_err "官方 TUIC/Hysteria2 核心安装失败，未更改节点。"; exit 1; }
  [ -n "${_NET_TUNE_APPLIED:-}" ] || apply_network_tune || true
  acquire_lock
  backup_dir="$(backup_state)"

  if [ "${action}" = "rep" ]; then
    while IFS= read -r tag; do [ -n "${tag}" ] || continue; stop_argo_node "${tag}"; done < <(iter_node_tags)
    stop_service || true
    wipe_records
    _AUTO_ROLLBACK_DIR="${backup_dir}"
    print_info "已清空原有节点（备份：${backup_dir}），按环境变量重建。"
  else
    print_info "已备份现有状态：${backup_dir}"
  fi

  ENV_NAME="$(env_var "name")"
  ENV_UUID="$(env_var "uuid")"
  ENV_PASSWD="$(env_var "passwd")"
  ENV_VL_SNI="$(tls_sni_auto "vl_sni" "${DEFAULT_REALITY_SERVER}")"
  ENV_XR_SNI="$(tls_sni_auto "xr_sni" "${DEFAULT_REALITY_SERVER}")"
  ENV_GR_SNI="$(tls_sni_auto "gr_sni" "${DEFAULT_REALITY_SERVER}")"
  ENV_WS_SNI="$(tls_sni_auto "ws_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_XW_SNI="$(tls_sni_auto "xw_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_GW_SNI="$(tls_sni_auto "gw_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_HY_SNI="$(tls_sni_auto "hy_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_TU_SNI="$(tls_sni_auto "tu_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_CDN_HOST="$(env_domain_or_default "cdn_host" "${DEFAULT_CDN_DOMAIN}")"
  ENV_CDN_PORT="$(env_var "cdn_port")"; ENV_CDN_PORT="${ENV_CDN_PORT:-443}"
  ENV_ARGO_CDN_HOST="$(env_var "argo_cdn_host")"
  ENV_ARGO_CDN_PORT="$(env_var "argo_cdn_port")"; ENV_ARGO_CDN_PORT="${ENV_ARGO_CDN_PORT:-443}"
  ENV_WS_PATH="$(env_var "ws_path")"
  ENV_ARGO_MODE="$(env_var "argo_mode")"
  ENV_ARGO_TRANSPORT="$(auto_argo_transport)"
  AUTO_REALITY_PRIVATE="$(manager_env_or_setting "reality_private" "")"
  AUTO_REALITY_PUBLIC="$(manager_env_or_setting "reality_public" "")"

  local _key _val
  for _key in go_gc net_tune mem_high_mb mem_max_mb server_ip direct_host reality_private reality_public debug_flag; do
    _val="$(env_var "$_key")"
    [ -n "${_val}" ] && set_setting "$_key" "$_val"
  done

  for line in "${specs[@]}"; do
    port="${line##* }"
    case "${line%% *}" in
    vless-reality)
      auto_try_port "$port" "VLESS-Vision-Reality" && { auto_add_reality "vless-reality" "$port" tcp "Reality" "${ENV_VL_SNI}" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    vless-xhttp-reality)
      auto_try_port "$port" "VLESS-XHTTP-Reality" && { auto_add_reality "vless-xhttp-reality" "$port" xhttp "XHTTP" "${ENV_XR_SNI}" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    vless-grpc-reality)
      auto_try_port "$port" "VLESS-gRPC-Reality" && { auto_add_reality "vless-grpc-reality" "$port" grpc "gRPC" "${ENV_GR_SNI}" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    vless-ws-cdn)
      auto_try_port "$port" "VLESS-WS-TLS-CDN" && { auto_add_cdn "vless-ws-cdn" "$port" ws "CDN" "${ENV_WS_SNI}" "${ENV_CDN_HOST}" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    vless-xhttp-cdn)
      auto_try_port "$port" "VLESS-XHTTP-TLS-CDN" && { auto_add_cdn "vless-xhttp-cdn" "$port" xhttp "CDN" "${ENV_XW_SNI}" "${ENV_CDN_HOST}" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    vless-grpc-cdn)
      auto_try_port "$port" "VLESS-gRPC-TLS-CDN" && { auto_add_cdn "vless-grpc-cdn" "$port" grpc "CDN" "${ENV_GW_SNI}" "${ENV_CDN_HOST}" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    vless-ws-argo|vless-xhttp-argo|vless-grpc-argo)
      auto_try_port "$port" "VLESS-${ENV_ARGO_TRANSPORT}-Argo" && { auto_add_argo "$port" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    tuic-v5)
      auto_try_port "$port" "TUIC v5" && { auto_add_tuic "$port" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    hy2)
      auto_try_port "$port" "Hysteria2" && { auto_add_hy2 "$port" && added=$((added + 1)) || failed=$((failed + 1)); } || failed=$((failed + 1)) ;;
    esac
  done

  if [ "${added}" -eq 0 ]; then
    _AUTO_ROLLBACK_DIR=""
    if [ "${action}" = "rep" ]; then
      restore_latest_backup || true
      reconcile_state || true
      render_config || true
      start_service || true
      print_err "没有成功写入任何节点（added=0, failed=${failed}），已恢复安装前的节点状态。"
    else
      print_err "没有成功写入任何节点（added=0, failed=${failed}），现有节点未受影响。"
    fi
    release_lock
    exit 1
  fi
  [ "${action}" = "rep" ] && cleanup_orphan_certs
  render_config
  reload_service
  _AUTO_ROLLBACK_DIR=""
  restart_all_argo_nodes || print_warn "部分 Argo 隧道启动失败，稍后可用 xm list 重查域名。"
  cleanup_unused_cloudflared || true

  case "$(env_var "sub")" in 1 | on | yes | true) set_setting "sub_enabled" "1" || true ;; esac
  case "$(env_var "sub_mode")" in
  worker)
    set_setting "sub_mode" "worker" || true
    set_setting "sub_domain" "$(env_var "sub_domain")" || true
    set_setting "sub_token" "$(env_var "sub_token")" || true
    set_setting "sub_machine" "$(env_var "sub_machine")" || true
    ;;
  *) set_setting "sub_mode" "temp" || true ;;
  esac
  if sub_enabled; then sub_start || print_warn "订阅链接启动失败，可稍后在菜单/命令行重试。"; fi

  sanitize_permissions
  release_lock
  echo
  print_ok "一键安装完成：新增 ${added} 个节点，失败 ${failed} 个。"
  echo
  print_node_list
  if [ -s "$(sub_url_file)" ]; then
    echo "订阅链接：$(cat "$(sub_url_file)")"
    echo
  fi
  [ "${failed}" -gt 0 ] && exit 1
  return 0
}
