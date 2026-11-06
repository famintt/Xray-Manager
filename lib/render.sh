#!/usr/bin/env bash
set -eEuo pipefail
umask 077

rollback_new_node() {
  local tag="$1" cert_file="${2:-}" key_file="${3:-}"
  delete_node_records "$tag" || true
  remove_node_certificates "$tag" "$cert_file" "$key_file"
  render_config || true
  start_service || true
}

save_node_bundle() {
  local tag="$1" node_json="$2" secret_json="$3"
  json_set_record "${NODES_FILE}" "$tag" "$node_json"
  json_set_record "${SECRETS_FILE}" "$tag" "$secret_json"
  invalidate_port_caches
}

# Xray 不提供 sing-box 的 Clash API；保留空实现，确保 status 兼容。
clash_api_enabled() { return 1; }
clash_api_conn_summary() { return 1; }
clash_api_dump_connections() { return 0; }

xray_validate_config() {
  local file="$1"
  [ -x "${XRAY_BIN:-}" ] || return 0
  "${XRAY_BIN}" run -test -c "${file}" >/dev/null 2>&1
}

# XHTTP 默认与 v1.0.0 保持一致：mode=auto、不写 sc*。
# XM_XHTTP_MODE / XM_XHTTP_SC_* 仍作为显式的 fast 覆盖；默认不启用。
xhttp_mode_value() {
  local scope="${1:-direct}" mode="${XM_XHTTP_MODE:-}"
  if [ -z "${mode}" ]; then
    mode="auto"
  fi
  case "${mode}" in
    auto|packet-up|stream-up|stream-one) printf '%s' "${mode}" ;;
    *) printf '%s' "auto" ;;
  esac
}

xhttp_positive_env() {
  local key="$1" default="$2" min="$3" max="$4" value
  value="${!key:-}"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${default}"
    return 0
  fi
  if [ "${value}" -lt "${min}" ]; then
    printf '%s' "${min}"
  elif [ "${value}" -gt "${max}" ]; then
    printf '%s' "${max}"
  else
    printf '%s' "${value}"
  fi
}

xhttp_extra_json() {
  local min max buffered
  local -a parts=()
  if [ -n "${XM_XHTTP_SC_MIN_POSTS_INTERVAL_MS:-}" ]; then
    min="$(xhttp_positive_env XM_XHTTP_SC_MIN_POSTS_INTERVAL_MS 30 0 1000)"
    parts+=("\"scMinPostsIntervalMs\":${min}")
  fi
  if [ -n "${XM_XHTTP_SC_MAX_EACH_POST_BYTES:-}" ]; then
    max="$(xhttp_positive_env XM_XHTTP_SC_MAX_EACH_POST_BYTES 1048576 1024 1048576)"
    parts+=("\"scMaxEachPostBytes\":${max}")
  fi
  if [ -n "${XM_XHTTP_SC_MAX_BUFFERED_POSTS:-}" ]; then
    buffered="$(xhttp_positive_env XM_XHTTP_SC_MAX_BUFFERED_POSTS 30 1 1024)"
    parts+=("\"scMaxBufferedPosts\":${buffered}")
  fi
  if [ "${#parts[@]}" -eq 0 ]; then
    printf '%s' '{}'
    return 0
  fi
  local IFS=','
  printf '{%s}\n' "${parts[*]}"
}

xhttp_settings_json() {
  local path="$1" host="$2" scope="${3:-direct}"
  xhttp_extra_json | jq -c --arg p "${path}" --arg h "${host}" --arg mode "$(xhttp_mode_value "${scope}")" \
    '{path:$p,host:$h,mode:$mode} + .'
}

# 与 sbm 的 tcp_fast_open/tcp_keep_alive 对齐；BBR 仅在内核实际可用时写入，
# 避免精简 NAT 内核因不存在的拥塞算法导致 Xray 拒绝启动。
_xray_sockopt_json() {
  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if printf '%s' "${available}" | grep -qw bbr; then
    printf '%s' '{"tcpFastOpen":true,"tcpKeepAliveIdle":30,"tcpKeepAliveInterval":15,"tcpCongestion":"bbr"}'
  else
    printf '%s' '{"tcpFastOpen":true,"tcpKeepAliveIdle":30,"tcpKeepAliveInterval":15}'
  fi
}

render_config() {
  local inbounds_json tmp tags level outbound_sockopt
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  if ! inbounds_json="$(
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      render_inbound_for_tag "${tag}" || exit 1
    done <<<"$tags"
  )"; then
    print_err "生成 Xray 入站配置失败。"
    return 1
  fi
  if [ -n "${inbounds_json}" ]; then
    inbounds_json="$(printf '%s\n' "${inbounds_json}" | jq -s '.')" || return 1
  else
    inbounds_json='[]'
  fi
  level="$(manager_env_or_setting "log_level" "warning")"
  case "${level}" in
    debug|info|warning|error|none) ;;
    *) level="warning" ;;
  esac
  tmp="$(mktemp "${BASE_DIR}/.config.XXXXXX")"
  local cfg_tmp="${tmp}.json"
  outbound_sockopt="$(_xray_sockopt_json)"
  if ! jq -n --argjson inbounds "${inbounds_json}" --arg level "${level}" --argjson outbound_sockopt "${outbound_sockopt}" '{
    log: { loglevel: $level },
    inbounds: $inbounds,
    outbounds: [{ protocol: "freedom", tag: "direct", streamSettings: { sockopt: $outbound_sockopt } }]
  }' >"${cfg_tmp}"; then
    rm -f "${tmp}" "${cfg_tmp}"; print_err "写入 Xray 配置失败。"; return 1
  fi
  if ! xray_validate_config "${cfg_tmp}"; then
    if [ "${XM_DEBUG_RENDER:-0}" = "1" ]; then
      cp -f "${cfg_tmp}" /tmp/xm-failed-config.json || true
      "${XRAY_BIN}" run -test -c "${cfg_tmp}" 2>/tmp/xm-validate.err || true
    fi
    rm -f "${tmp}" "${cfg_tmp}"
    print_err "Xray 配置校验失败，已拒绝覆盖现有配置。"
    return 1
  fi
  chmod 600 "${cfg_tmp}"
  render_aux_configs || { rm -f "${tmp}" "${cfg_tmp}"; print_err "生成 TUIC/Hysteria2 配置失败。"; return 1; }
  mv "${cfg_tmp}" "${CONFIG_FILE}"
  rm -f "${tmp}"
}

node_meta() {
  local tag="$1"
  jq -n -r --arg tag "$tag" \
    --rawfile nodes "${NODES_FILE}" \
    --rawfile secrets "${SECRETS_FILE}" '
    ($nodes | fromjson | .[$tag] // {}) as $n |
    ($secrets | fromjson | .[$tag] // {}) as $s |
    [
      ($n.protocol // ""), ($n.name // ""), (($n.port // "") | tostring),
      ($s.uuid // ""), ($s.password // ""), ($s.private_key // ""),
      ($n.public_key // ""), ($n.short_id // ""), ($n.reality_server // ""),
      ($n.tls_server // ""), ($n.preferred_domain // ""), ($n.host_domain // ""),
      ($n.ws_path // ""), ($n.ws_mode // ""), (($n.cdn_port // "") | tostring),
      ($n.cdn_sni // ""), ($n.certificate_mode // ""), ($n.certificate_path // ""),
      ($n.key_path // ""), ($n.endpoint_domain // ""), ($n.argo_mode // ""),
      ($s.argo_token // ""), (($n.up_mbps // "") | tostring),
      (($n.down_mbps // "") | tostring), ($n.username // "")
    ] | .[]
  '
}

node_meta_array() {
  local tag="$1" i=0 _f
  NODE_META=()
  while IFS= read -r _f; do
    NODE_META[i++]="${_f%$'\r'}"
    [ "$i" -ge 25 ] && break
  done < <(node_meta "$tag")
  while [ "$i" -lt 25 ]; do NODE_META[i++]=""; done
}

_vless_inbound() {
  local tag="$1" name="$2" port="$3" uuid="$4" network="$5" security="$6"
  local sni="$7" path="$8" private_key="$9" short_id="${10}" cert_file="${11}" key_file="${12}" flow="${13}" xhttp_scope="${14:-direct}"
  local short_ids_json='[]' alpn_json='["h2","http/1.1"]' stream='{}' client='{}' sockopt_json
  [ -n "${flow}" ] && client="$(jq -n --arg u "$uuid" --arg n "$name" --arg f "$flow" '{id:$u,name:$n,flow:$f}')" || client="$(jq -n --arg u "$uuid" --arg n "$name" '{id:$u,name:$n}')"
  [ -n "${short_id}" ] && short_ids_json="$(printf '%s' "$short_id" | jq -R 'split(",")|map(select(.!=""))')"
  case "${network}" in
    ws) stream="$(jq -n --arg p "$path" '{network:"ws",wsSettings:{path:$p}}')" ;;
    xhttp) stream="$(jq -n --argjson xs "$(xhttp_settings_json "$path" "$sni" "$xhttp_scope")" '{network:"xhttp",xhttpSettings:$xs}')" ;;
    grpc) stream="$(jq -n --arg p "${path#/}" '{network:"grpc",grpcSettings:{serviceName:$p}}')" ;;
    tcp|raw) stream='{"network":"tcp"}' ;;
    *) stream='{"network":"tcp"}' ;;
  esac
  # TCP 快速打开/长连接：与 sbm 对齐；BBR 只在当前内核可用时写入。
  sockopt_json="$(_xray_sockopt_json)"
  stream="$(printf '%s' "$stream" | jq --argjson so "$sockopt_json" '. + {sockopt:$so}')"
  if [ "${security}" = "reality" ]; then
    stream="$(printf '%s' "$stream" | jq --arg sni "$sni" --arg pk "$private_key" --argjson sids "$short_ids_json" '. + {security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$pk,shortIds:$sids}}')"
  elif [ "${security}" = "tls" ]; then
    [ "${network}" = "grpc" ] && alpn_json='["h2"]'
    stream="$(printf '%s' "$stream" | jq --arg sni "$sni" --arg cf "$cert_file" --arg kf "$key_file" --argjson alpn "$alpn_json" '. + {security:"tls",tlsSettings:{serverName:$sni,alpn:$alpn,certificates:[{certificateFile:$cf,keyFile:$kf}]}}')"
  else
    stream="$(printf '%s' "$stream" | jq '. + {security:"none"}')"
  fi
  jq -n --arg tag "$tag" --argjson port "$port" --argjson client "$client" --argjson stream "$stream" '{
    tag:$tag, listen:"0.0.0.0", port:$port, protocol:"vless",
    settings:{clients:[$client],decryption:"none"},
    streamSettings:$stream
  }'
}

render_inbound_for_tag() {
  local tag="$1" protocol name port uuid password private_key public_key short_id
  local reality_server tls_server preferred_domain host_domain ws_path ws_mode cdn_port cdn_sni
  local certificate_path key_path endpoint_domain argo_mode up_mbps down_mbps flow network security sni path
  node_meta_array "$tag"
  protocol="${NODE_META[0]}"; name="${NODE_META[1]}"; port="${NODE_META[2]}"
  uuid="${NODE_META[3]}"; password="${NODE_META[4]}"; private_key="${NODE_META[5]}"
  public_key="${NODE_META[6]}"; short_id="${NODE_META[7]}"; reality_server="${NODE_META[8]}"
  tls_server="${NODE_META[9]}"; preferred_domain="${NODE_META[10]}"; host_domain="${NODE_META[11]}"
  ws_path="${NODE_META[12]}"; ws_mode="${NODE_META[13]}"; cdn_port="${NODE_META[14]}"
  cdn_sni="${NODE_META[15]}"; certificate_path="${NODE_META[17]}"; key_path="${NODE_META[18]}"
  endpoint_domain="${NODE_META[19]}"; argo_mode="${NODE_META[20]}"
  case "$protocol" in
    vless-reality)
      _vless_inbound "$tag" "$name" "$port" "$uuid" tcp reality "$reality_server" "" "$private_key" "$short_id" "" "" "xtls-rprx-vision" ;;
    vless-xhttp-reality)
      _vless_inbound "$tag" "$name" "$port" "$uuid" xhttp reality "$reality_server" "$ws_path" "$private_key" "$short_id" "" "" "" "direct" ;;
    vless-grpc-reality)
      _vless_inbound "$tag" "$name" "$port" "$uuid" grpc reality "$reality_server" "$ws_path" "$private_key" "$short_id" "" "" "" ;;
    vless-ws-cdn|vless-xhttp-cdn|vless-grpc-cdn)
      network="${protocol#vless-}"; network="${network%-cdn}"
      sni="${cdn_sni:-$preferred_domain}"
      _vless_inbound "$tag" "$name" "$port" "$uuid" "$network" tls "$sni" "$ws_path" "" "" "$certificate_path" "$key_path" "" "cdn" ;;
    vless-ws-argo|vless-xhttp-argo|vless-grpc-argo)
      network="${protocol#vless-}"; network="${network%-argo}"
      # XHTTP over Argo: Cloudflare 回源会保留 Host，服务端必须与客户端 host 一致。
      sni="${endpoint_domain:-}"
      _vless_inbound "$tag" "$name" "$port" "$uuid" "$network" none "$sni" "$ws_path" "" "" "" "" "" "argo" ;;
    tuic-v5|hy2)
      # 官方 TUIC v5 / Hysteria2 由 sidecar 核心处理，不写入 Xray 配置。
      return 0 ;;
    *) print_warn "未知 Xray 协议：${protocol}"; return 1 ;;
  esac
}
