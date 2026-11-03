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
  local arch asset expected url tmp
  [ -x "${TUIC_BIN}" ] && return 0
  arch="$(aux_arch)" || return 1
  asset="${TUIC_ASSET[$arch]:-}"
  expected="${TUIC_SHA256[$arch]:-}"
  [ -n "${asset}" ] || { print_err "未配置 ${arch} 的 tuic-server 资产。"; return 1; }
  [ -n "${expected}" ] || { print_err "未配置 ${arch} 的 tuic-server 校验值。"; return 1; }
  tmp="$(mktemp)"
  print_info "正在安装官方 tuic-server ${TUIC_VERSION} (${arch})"
  local -a urls=("https://github.com/tuic-protocol/tuic/releases/download/${TUIC_VERSION}/${asset}")
  [ -n "${TUIC_MIRROR_BASE:-}" ] && urls+=("${TUIC_MIRROR_BASE}/${asset}")
  if ! download_file_multi "${tmp}" "${urls[@]}"; then
    rm -f "${tmp}"
    print_err "下载 tuic-server 失败（已尝试 ${#urls[@]} 个源）。"
    return 1
  fi
  verify_sha256 "${tmp}" "${expected}"
  install -m 0755 "${tmp}" "${TUIC_BIN}"
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
  tmp="$(mktemp)"
  print_info "正在安装官方 hysteria ${HYSTERIA_VERSION} (${arch})"
  local -a urls=("https://github.com/HyNetworks/hysteria/releases/download/${HYSTERIA_VERSION//\//%2F}/${asset}")
  [ -n "${HYSTERIA_MIRROR_BASE:-}" ] && urls+=("${HYSTERIA_MIRROR_BASE}/${asset}")
  if ! download_file_multi "${tmp}" "${urls[@]}"; then
    rm -f "${tmp}"
    print_err "下载 hysteria 失败（已尝试 ${#urls[@]} 个源）。"
    return 1
  fi
  verify_sha256 "${tmp}" "${expected}"
  install -m 0755 "${tmp}" "${HYSTERIA_BIN}"
  rm -f "${tmp}"
  ensure_binary_runs "${HYSTERIA_BIN}" "hysteria" version || return 1
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

render_tuic_config() {
  local tag port uuid password cert key tmp
  tag="$(node_tags_by_protocol "tuic-v5" | head -n 1)"
  if [ -z "${tag}" ]; then
    rm -f "${TUIC_CONFIG_FILE}"
    return 0
  fi
  node_meta_array "${tag}"
  port="${NODE_META[2]}"; uuid="${NODE_META[3]}"; password="${NODE_META[4]}"
  cert="${NODE_META[17]}"; key="${NODE_META[18]}"
  [ -n "${uuid}" ] && [ -n "${password}" ] || { print_err "TUIC 节点 ${tag} 缺少 UUID/密码。"; return 1; }
  [ -f "${cert}" ] && [ -f "${key}" ] || { print_err "TUIC 节点 ${tag} 证书不存在。"; return 1; }
  tmp="$(mktemp "${BASE_DIR}/.tuic.XXXXXX")"
  jq -n --arg server "[::]:${port}" --arg uuid "${uuid}" --arg password "${password}" \
    --arg cert "${cert}" --arg key "${key}" '{
      server:$server,
      users:{($uuid):$password},
      certificate:$cert,
      private_key:$key,
      alpn:["h3"],
      congestion_control:"bbr",
      zero_rtt_handshake:false,
      dual_stack:true,
      log_level:"warn"
    }' >"${tmp}" || { rm -f "${tmp}"; return 1; }
  chmod 600 "${tmp}"
  mv "${tmp}" "${TUIC_CONFIG_FILE}"
}

render_hysteria_config() {
  local tag port password cert key up down tmp
  tag="$(node_tags_by_protocol "hy2" | head -n 1)"
  if [ -z "${tag}" ]; then
    rm -f "${HYSTERIA_CONFIG_FILE}"
    return 0
  fi
  node_meta_array "${tag}"
  port="${NODE_META[2]}"; password="${NODE_META[4]}"
  cert="${NODE_META[17]}"; key="${NODE_META[18]}"
  up="${NODE_META[22]}"; down="${NODE_META[23]}"
  [ -n "${password}" ] || { print_err "Hysteria2 节点 ${tag} 缺少密码。"; return 1; }
  [ -f "${cert}" ] && [ -f "${key}" ] || { print_err "Hysteria2 节点 ${tag} 证书不存在。"; return 1; }
  tmp="$(mktemp "${BASE_DIR}/.hysteria.XXXXXX")"
  {
    printf 'listen: ":%s"\n' "${port}"
    printf 'tls:\n  cert: "%s"\n  key: "%s"\n' "${cert}" "${key}"
    printf 'auth:\n  type: password\n  password: "%s"\n' "${password}"
    if [ -n "${up}" ] && [ "${up}" != "0" ] && [ -n "${down}" ] && [ "${down}" != "0" ]; then
      printf 'bandwidth:\n  up: "%s mbps"\n  down: "%s mbps"\n' "${up}" "${down}"
    fi
  } >"${tmp}" || { rm -f "${tmp}"; return 1; }
  chmod 600 "${tmp}"
  mv "${tmp}" "${HYSTERIA_CONFIG_FILE}"
}

render_aux_configs() {
  render_tuic_config || return 1
  render_hysteria_config || return 1
}

aux_pid_alive() {
  local pid_file="$1" binary="$2" pid
  pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  if [ -n "${binary}" ] && [ -r "/proc/${pid}/cmdline" ]; then
    tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null | grep -Fq "$(basename "${binary}")" || return 1
  fi
}

start_aux_one() {
  local label="$1" binary="$2" config="$3" pid_file="$4" log_file="$5"
  shift 5
  [ -f "${config}" ] || return 0
  [ -x "${binary}" ] || { print_err "${label} 二进制不存在：${binary}"; return 1; }
  if aux_pid_alive "${pid_file}" "${binary}"; then
    return 0
  fi
  rotate_log_file "${log_file}" || true
  nohup "${binary}" "$@" >"${log_file}" 2>&1 </dev/null &
  write_pid_file "${pid_file}" "$!"
  sleep 1
  if ! aux_pid_alive "${pid_file}" "${binary}"; then
    print_err "${label} 启动失败，日志：${log_file}"
    rm -f "${pid_file}"
    return 1
  fi
  print_ok "${label} 已启动"
}

start_aux_services() {
  local rc=0
  if [ -f "${TUIC_CONFIG_FILE}" ]; then
    start_aux_one "TUIC v5" "${TUIC_BIN}" "${TUIC_CONFIG_FILE}" "${TUIC_PID_FILE}" "${BASE_DIR}/logs/tuic.log" -c "${TUIC_CONFIG_FILE}" || rc=1
  fi
  if [ -f "${HYSTERIA_CONFIG_FILE}" ]; then
    start_aux_one "Hysteria2" "${HYSTERIA_BIN}" "${HYSTERIA_CONFIG_FILE}" "${HYSTERIA_PID_FILE}" "${BASE_DIR}/logs/hysteria.log" server -c "${HYSTERIA_CONFIG_FILE}" || rc=1
  fi
  return "${rc}"
}

stop_aux_services() {
  kill_pid_file "${TUIC_PID_FILE}" "${TUIC_BIN}" 2>/dev/null || true
  kill_pid_file "${HYSTERIA_PID_FILE}" "${HYSTERIA_BIN}" 2>/dev/null || true
}

ensure_aux_services() {
  ensure_aux_cores_for_nodes || return 1
  start_aux_services
}
