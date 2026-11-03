#!/usr/bin/env bash
set -eEuo pipefail
umask 077

build_share_link() {
  local tag="$1" public_ip="${2:-}"
  local protocol name port host uuid password username reality_server public_key short_id
  local preferred_domain host_domain ws_path ws_mode cdn_port cdn_sni certificate_path certificate_mode endpoint_domain
  local sni path transport hostpart enc_name
  node_meta_array "$tag"
  protocol="${NODE_META[0]}"; name="${NODE_META[1]}"; port="${NODE_META[2]}"
  uuid="${NODE_META[3]}"; password="${NODE_META[4]}"; public_key="${NODE_META[6]}"
  short_id="${NODE_META[7]}"; reality_server="${NODE_META[8]}"; preferred_domain="${NODE_META[10]}"
  host_domain="${NODE_META[11]}"; ws_path="${NODE_META[12]}"; ws_mode="${NODE_META[13]}"
  cdn_port="${NODE_META[14]}"; cdn_sni="${NODE_META[15]}"; certificate_path="${NODE_META[17]}"
  certificate_mode="${NODE_META[16]}"; endpoint_domain="${NODE_META[19]}"; username="${NODE_META[24]}"
  local direct_host server_ip
  direct_host="$(manager_env_or_setting "direct_host" "")"
  server_ip="$(manager_env_or_setting "server_ip" "")"
  if [ -n "${direct_host}" ]; then public_ip="${direct_host}"
  elif [ -n "${server_ip}" ]; then public_ip="${server_ip}"
  else public_ip="${public_ip:-$(get_public_ip)}"; fi
  host="$(wrap_host "$public_ip")"
  path="${ws_path:-/}"
  enc_name="$(url_encode "$name")"

  case "$protocol" in
    vless-reality)
      local -a enc=()
      mapfile -t enc < <(url_encode_many "$reality_server" "$public_key" "$short_id")
      local e_sni="${enc[0]:-}" e_pbk="${enc[1]:-}" e_sid="${enc[2]:-}"
      printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
        "$uuid" "$host" "$port" "$e_sni" "$e_pbk" "$e_sid" "$enc_name" ;;
    vless-xhttp-reality|vless-grpc-reality)
      transport="${protocol#vless-}"; transport="${transport%-reality}"
      local -a enc=()
      mapfile -t enc < <(url_encode_many "$reality_server" "$public_key" "$short_id" "$path" "$reality_server")
      local e_sni="${enc[0]:-}" e_pbk="${enc[1]:-}" e_sid="${enc[2]:-}" e_path="${enc[3]:-}" e_host="${enc[4]:-}"
      if [ "$transport" = "grpc" ]; then
        printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=grpc&serviceName=%s#%s' \
          "$uuid" "$host" "$port" "$e_sni" "$e_pbk" "$e_sid" "${e_path#%2F}" "$enc_name"
      else
        printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&host=%s&mode=auto#%s' \
          "$uuid" "$host" "$port" "$e_sni" "$e_pbk" "$e_sid" "$e_path" "$e_host" "$enc_name"
      fi ;;
    vless-ws-cdn|vless-xhttp-cdn|vless-grpc-cdn)
      transport="${protocol#vless-}"; transport="${transport%-cdn}"
      sni="${cdn_sni:-$preferred_domain}"; cdn_port="${cdn_port:-443}"
      local -a enc=()
      mapfile -t enc < <(url_encode_many "$sni" "$preferred_domain" "$path")
      local e_sni="${enc[0]:-}" e_host="${enc[1]:-}" e_path="${enc[2]:-}"
      if [ "$transport" = "ws" ]; then
        printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s' \
          "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" "$e_sni" "$e_host" "$e_path" "$enc_name"
      elif [ "$transport" = "grpc" ]; then
        printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=grpc&serviceName=%s#%s' \
          "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" "$e_sni" "${e_path#%2F}" "$enc_name"
      else
        printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&path=%s&host=%s&mode=auto#%s' \
          "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" "$e_sni" "$e_path" "$e_host" "$enc_name"
      fi ;;
    vless-ws-argo|vless-xhttp-argo|vless-grpc-argo)
      transport="${protocol#vless-}"; transport="${transport%-argo}"
      local argo_port="${cdn_port:-443}"
      [ "${argo_port}" = "0" ] && argo_port=443
      if [ -z "$endpoint_domain" ] || [ "$endpoint_domain" = "待分配.example.com" ]; then
        print_warn "节点 ${tag} 的 Argo 域名尚未分配，链接暂不可用。"; return 0
      fi
      local -a enc=()
      mapfile -t enc < <(url_encode_many "$endpoint_domain" "$endpoint_domain" "$path")
      local e_domain="${enc[0]:-}" e_host="${enc[1]:-}" e_path="${enc[2]:-}"
      if [ "$transport" = "ws" ]; then
        printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s' \
          "$uuid" "$(wrap_host "$endpoint_domain")" "$argo_port" "$e_domain" "$e_host" "$e_path" "$enc_name"
      elif [ "$transport" = "grpc" ]; then
        printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=grpc&serviceName=%s#%s' \
          "$uuid" "$(wrap_host "$endpoint_domain")" "$argo_port" "$e_domain" "${e_path#%2F}" "$enc_name"
      else
        printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&path=%s&host=%s&mode=auto#%s' \
          "$uuid" "$(wrap_host "$endpoint_domain")" "$argo_port" "$e_domain" "$e_path" "$e_host" "$enc_name"
      fi ;;
    tuic-v5)
      local tls_server="${NODE_META[9]:-}" e_uuid e_password e_sni e_name insecure=""
      if cert_needs_insecure "$certificate_mode" "$certificate_path" "$tls_server"; then insecure="&allow_insecure=1"; fi
      local -a enc=()
      mapfile -t enc < <(url_encode_many "$uuid" "$password" "$tls_server" "$name")
      e_uuid="${enc[0]:-}"; e_password="${enc[1]:-}"; e_sni="${enc[2]:-}"; e_name="${enc[3]:-}"
      printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s&udp_relay_mode=native%s#%s'         "$e_uuid" "$e_password" "$host" "$port" "$e_sni" "$insecure" "$e_name" ;;
    hy2)
      local tls_server="${NODE_META[9]:-}" e_sni e_name insecure=""
      if cert_needs_insecure "$certificate_mode" "$certificate_path" "$tls_server"; then insecure="&insecure=1"; fi
      local -a enc=()
      mapfile -t enc < <(url_encode_many "$tls_server" "$name")
      e_sni="${enc[0]:-}"; e_name="${enc[1]:-}"
      printf 'hysteria2://%s@%s:%s?sni=%s%s#%s' \
        "$(url_encode "$password")" "$host" "$port" "$e_sni" "$insecure" "$e_name" ;;
    *) print_warn "未知协议：${protocol}"; return 1 ;;
  esac
}

build_vless_argo_link() { build_share_link "$1"; }
