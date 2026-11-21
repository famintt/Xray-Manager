#!/usr/bin/env bash
# 官方 TUIC v5 / Hysteria2 sidecar 核心：按需安装、配置、启停。
set -Eeuo pipefail
umask 077

node_tags_by_protocol() {
  local proto="$1" tag
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    [ "$(node_value "${tag}" "protocol")" = "${proto}" ] && printf '%s\n' "${tag}"
  done < <(iter_node_tags)
}

need_tuic() { [ -n "$(node_tags_by_protocol "tuic-v5")" ]; }
need_hysteria() { [ -n "$(node_tags_by_protocol "hy2")" ]; }

aux_arch() {
  local arch
  arch="$(detect_arch)" || return 1
  case "${arch}" in
    amd64 | arm64 | armv7) printf '%s' "${arch}" ;;
    armv6)
      print_err "官方 sidecar 未提供 armv6 预编译包，请使用 armv7 或 arm64 系统。"
      return 1 ;;
    *) print_err "不支持的 sidecar 架构：${arch}"; return 1 ;;
  esac
}

install_tuic_core() {
  local arch asset expected tmp
  [ -x "${TUIC_BIN}" ] && return 0
  arch="$(aux_arch)" || return 1
  asset="${TUIC_ASSET[$arch]:-}"
  expected="${TUIC_SHA256[$arch]:-}"
  [ -n "${asset}" ] || { print_err "未配置 ${arch} 的 tuic-server 资产。"; return 1; }
  [ -n "${expected}" ] || { print_err "未配置 ${arch} 的 tuic-server 校验值。"; return 1; }
  tmp="$(mktemp)" || return 1
  print_info "正在安装官方 tuic-server ${TUIC_VERSION} (${arch})"
  local -a urls=("https://github.com/tuic-protocol/tuic/releases/download/${TUIC_VERSION}/${asset}")
  [ -n "${TUIC_MIRROR_BASE:-}" ] && urls+=("${TUIC_MIRROR_BASE}/${asset}")
  if ! download_file_multi "${tmp}" "${urls[@]}"; then
    rm -f "${tmp}"
    print_err "下载 tuic-server 失败（已尝试 ${#urls[@]} 个源）。"
    return 1
  fi
  if ! sha256_matches "${tmp}" "${expected}" || ! install_atomic "${tmp}" "${TUIC_BIN}"; then
    rm -f "${tmp}"
    print_err "tuic-server 校验或安装失败。"
    return 1
  fi
  rm -f "${tmp}"
  print_ok "tuic-server 已安装到 ${TUIC_BIN}"
}

install_hysteria_core() {
  local arch asset expected tmp
  [ -x "${HYSTERIA_BIN}" ] && return 0
  arch="$(aux_arch)" || return 1
  asset="${HYSTERIA_ASSET[$arch]:-}"
  expected="${HYSTERIA_SHA256[$arch]:-}"
  [ -n "${asset}" ] || { print_err "未配置 ${arch} 的 hysteria 资产。"; return 1; }
  [ -n "${expected}" ] || { print_err "未配置 ${arch} 的 hysteria 校验值。"; return 1; }
  tmp="$(mktemp)" || return 1
  print_info "正在安装官方 hysteria ${HYSTERIA_VERSION} (${arch})"
  local -a urls=("https://github.com/HyNetworks/hysteria/releases/download/${HYSTERIA_VERSION//\//%2F}/${asset}")
  [ -n "${HYSTERIA_MIRROR_BASE:-}" ] && urls+=("${HYSTERIA_MIRROR_BASE}/${asset}")
  if ! download_file_multi "${tmp}" "${urls[@]}"; then
    rm -f "${tmp}"
    print_err "下载 hysteria 失败（已尝试 ${#urls[@]} 个源）。"
    return 1
  fi
  if ! sha256_matches "${tmp}" "${expected}" ||
     ! chmod 700 "${tmp}" ||
     ! ensure_binary_runs "${tmp}" "hysteria" version ||
     ! install_atomic "${tmp}" "${HYSTERIA_BIN}"; then
    rm -f "${tmp}"
    print_err "hysteria 校验或安装失败。"
    return 1
  fi
  rm -f "${tmp}"
  print_ok "hysteria 已安装到 ${HYSTERIA_BIN}"
}

ensure_tuic_core() { [ -x "${TUIC_BIN}" ] || install_tuic_core; }
ensure_hysteria_core() { [ -x "${HYSTERIA_BIN}" ] || install_hysteria_core; }

ensure_aux_cores_for_env() {
  if [ -n "$(env_var "tupt")" ]; then
    ensure_tuic_core || return 1
  fi
  if [ -n "$(env_var "hypt")" ]; then
    ensure_hysteria_core || return 1
  fi
}

ensure_aux_cores_for_nodes() {
  if need_tuic; then ensure_tuic_core || return 1; fi
  if need_hysteria; then ensure_hysteria_core || return 1; fi
}

# 官方配置每进程只有一个监听。此检查必须在写入节点/秘密表之前运行。
aux_singleton_available() {
  local protocol="$1" tag="$2"
  case "$protocol" in tuic-v5|hy2) ;; *) return 0 ;; esac
  if ! jq -e --arg proto "$protocol" --arg tag "$tag" \
    'all(to_entries[]; .key == $tag or .value.protocol != $proto)' "${NODES_FILE}" >/dev/null; then
    print_err "${protocol} 只支持一个节点，请先删除现有同协议节点。"
    return 1
  fi
}

aux_port_valid() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
aux_bandwidth_valid() { [[ "$1" =~ ^(0|[1-9][0-9]{0,8})$ ]]; }

render_tuic_config() {
  local tag="$1" output="$2" port uuid password cert key
  node_meta_array "$tag" || return 1
  port="${NODE_META[2]}"; uuid="${NODE_META[3]}"; password="${NODE_META[4]}"
  cert="${NODE_META[17]}"; key="${NODE_META[18]}"
  if ! aux_port_valid "$port" || ! valid_node_uuid "$uuid" || [ -z "$password" ]; then
    print_err "TUIC 节点 ${tag} 的端口、UUID 或密码无效。"
    return 1
  fi
  validate_certificate_pair "$cert" "$key" || { print_err "TUIC 节点 ${tag} 的 TLS 证书与私钥无效。"; return 1; }
  jq -n --arg server "[::]:${port}" --arg uuid "$uuid" --arg password "$password" \
    --arg cert "$cert" --arg key "$key" '{
      server:$server, users:{($uuid):$password}, certificate:$cert, private_key:$key,
      alpn:["h3"], congestion_control:"bbr", zero_rtt_handshake:false, dual_stack:true, log_level:"warn"
    }' >"$output"
}

render_hysteria_config() {
  local tag="$1" output="$2" port password cert key up down
  node_meta_array "$tag" || return 1
  port="${NODE_META[2]}"; password="${NODE_META[4]}"
  cert="${NODE_META[17]}"; key="${NODE_META[18]}"
  up="${NODE_META[22]:-0}"; down="${NODE_META[23]:-0}"
  if ! aux_port_valid "$port" || [ -z "$password" ] || ! aux_bandwidth_valid "$up" || ! aux_bandwidth_valid "$down"; then
    print_err "Hysteria2 节点 ${tag} 的端口、密码或带宽无效。"
    return 1
  fi
  validate_certificate_pair "$cert" "$key" || { print_err "Hysteria2 节点 ${tag} 的 TLS 证书与私钥无效。"; return 1; }
  # Hysteria 的 YAML 解析器接受 JSON。同样的编码保护密码与证书路径。
  jq -n --arg listen ":$port" --arg password "$password" --arg cert "$cert" --arg key "$key" \
    --argjson up "$up" --argjson down "$down" '
      {listen:$listen, tls:{cert:$cert, key:$key}, auth:{type:"password", password:$password}}
      # jq 的对象值里 `(A) + (B)` 不会被解析成加法（报 unexpected '+'），
      # 必须整体再包一层括号，否则整个 sidecar 配置生成直接失败。
      + (if $up == 0 and $down == 0 then {} else {bandwidth: (
          (if $up == 0 then {} else {up:("\($up) mbps")} end)
          + (if $down == 0 then {} else {down:("\($down) mbps")} end))} end)
    ' >"$output"
}

prepare_aux_configs() {
  local stage="$1" tags
  tags="$(jq -r '[to_entries[] | select(.value.protocol == "tuic-v5") | .key] | join("\n")' "${NODES_FILE}")" || return 1
  if [ -n "$tags" ]; then
    if [[ "$tags" == *$'\n'* ]]; then print_err "检测到多个 TUIC 节点。请删减至一个后再启动。"; return 1; fi
    render_tuic_config "$tags" "$stage/tuic.json" || return 1
  fi
  tags="$(jq -r '[to_entries[] | select(.value.protocol == "hy2") | .key] | join("\n")' "${NODES_FILE}")" || return 1
  if [ -n "$tags" ]; then
    if [[ "$tags" == *$'\n'* ]]; then print_err "检测到多个 Hysteria2 节点。请删减至一个后再启动。"; return 1; fi
    render_hysteria_config "$tags" "$stage/hysteria.yaml" || return 1
  fi
}

# A08/XR-14：sidecar 配置也走"先全量生成到暂存目录，再逐个原子替换"。
# 旧实现直接在目标路径上写，且工作区里一度出现"调用方 render_aux_configs 未定义"
# 的半成品状态——render_config 直接失败，节点明明写好了却起不来。
render_aux_configs() {
  local stage rc=0
  stage="$(mktemp -d "${BASE_DIR}/.aux.XXXXXX")" || return 1
  if ! prepare_aux_configs "${stage}"; then
    rm -rf "${stage}"
    return 1
  fi
  if [ -f "${stage}/tuic.json" ]; then
    mv -f "${stage}/tuic.json" "${TUIC_CONFIG_FILE}" || rc=1
  else
    # 节点已删除时清掉旧配置，否则 start_aux_services 会按旧文件把进程拉起来
    rm -f "${TUIC_CONFIG_FILE}"
  fi
  if [ -f "${stage}/hysteria.yaml" ]; then
    mv -f "${stage}/hysteria.yaml" "${HYSTERIA_CONFIG_FILE}" || rc=1
  else
    rm -f "${HYSTERIA_CONFIG_FILE}"
  fi
  chmod 600 "${TUIC_CONFIG_FILE}" "${HYSTERIA_CONFIG_FILE}" 2>/dev/null || true
  rm -rf "${stage}"
  return "${rc}"
}

aux_pid_alive() {
  local pid
  pid="$(read_pid_file "$1")" || return 1
  pid_matches_binary_or_alive "$pid" "$2"
}

aux_config_port() {
  local address
  address="$(jq -er '.server // .listen | strings' "$1")" || return 1
  local port="${address##*:}"
  aux_port_valid "$port" || return 1
  printf '%s\n' "$port"
}

aux_listener_ready() {
  local pid_file="$1" binary="$2" port="$3" pid
  pid="$(read_pid_file "$pid_file")" || return 1
  pid_matches_binary_or_alive "$pid" "$binary" || return 1
  ss -H -aunp 2>/dev/null | awk -v port="$port" -v process="pid=$pid," '
    $2 == "UNCONN" && $5 ~ (":" port "$") && index($0, process) {found=1}
    END {exit !found}'
}

start_aux_one() {
  local label="$1" binary="$2" config="$3" pid_file="$4" log_file="$5"
  shift 5
  local port pid n mem_limit low_port=0
  [ -f "$config" ] || return 0
  [ -x "$binary" ] || { print_err "${label} 二进制不存在：${binary}"; return 1; }
  port="$(aux_config_port "$config")" || return 1
  if aux_listener_ready "$pid_file" "$binary" "$port"; then return 0; fi
  kill_pid_file "$pid_file" "$binary" || return 1
  prepare_data_plane_permissions || return 1
  rotate_log_file "$log_file" || true
  if [ "$port" -lt 1024 ]; then low_port=1; fi
  mem_limit="$(go_mem_limit_value)" || return 1
  (
    trap '' HUP
    close_inherited_lock_fd
    cd "${DATA_PLANE_DIR}" || exit 1
    [ -z "$mem_limit" ] || export GOMEMLIMIT="$mem_limit"
    XM_BIND_LOW_PORT="$low_port" run_data_plane "$binary" "$@"
  ) >>"$log_file" 2>&1 </dev/null &
  pid=$!
  if ! write_pid_file "$pid_file" "$pid"; then
    # PID comes directly from our own asynchronous launch, even before exec.
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  for ((n=0; n<30; n++)); do
    if aux_listener_ready "$pid_file" "$binary" "$port"; then
      print_ok "${label} 已就绪（UDP ${port}）"
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  print_err "${label} 未就绪（UDP ${port}），日志：${log_file}"
  kill_pid_file "$pid_file" "$binary" || return 1
  return 1
}

start_tuic_service() {
  start_aux_one "TUIC" "${TUIC_BIN}" "${TUIC_CONFIG_FILE}" "${TUIC_PID_FILE}" "${LOG_DIR}/tuic.log" -c "${TUIC_CONFIG_FILE}"
}

start_hysteria_service() {
  start_aux_one "Hysteria2" "${HYSTERIA_BIN}" "${HYSTERIA_CONFIG_FILE}" "${HYSTERIA_PID_FILE}" "${LOG_DIR}/hysteria.log" \
    server --disable-update-check -c "${HYSTERIA_CONFIG_FILE}"
}

start_aux_services() {
  local rc=0
  start_tuic_service || rc=1
  start_hysteria_service || rc=1
  return "$rc"
}

stop_aux_services() {
  local rc=0
  kill_pid_file "${TUIC_PID_FILE}" "${TUIC_BIN}" || rc=1
  kill_pid_file "${HYSTERIA_PID_FILE}" "${HYSTERIA_BIN}" || rc=1
  return "$rc"
}

ensure_aux_services() {
  ensure_aux_cores_for_nodes || return 1
  start_aux_services
}
