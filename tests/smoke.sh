#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
export XM_TEST_MODE=1
export BASE_DIR="${BASE_DIR:-/tmp/xm-smoke-state}"
export LIB_DIR="${LIB_DIR:-${BASE_DIR}/lib}"
export XRAY_BIN="${XRAY_BIN:-/mnt/d/AI/DSH/.sbm_test/xray-linux/xray}"
export TUIC_BIN="${TUIC_BIN:-/bin/true}"
export HYSTERIA_BIN="${HYSTERIA_BIN:-/bin/true}"

rm -rf "${BASE_DIR}"
mkdir -p "${BASE_DIR}"/{certs,logs,runtime,backups}

# shellcheck source=/dev/null
source "${ROOT}/xm.sh"
init_storage

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf 'ok   %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$3], actual [$2])"; fi; }
check_contains() { if printf '%s' "$2" | grep -Fq "$3"; then pass "$1"; else fail "$1 (missing [$3])"; fi; }

check_eq "版本" "$(cat VERSION)" "v0.10.0"
check_contains "入口名称" "$(head -n 15 xm.sh)" "Xray 管理器"
check_contains "UI 有 TUIC 卡" "$(cat interface/index.html)" 'id="tupt"'
check_contains "UI 有 TUIC SNI" "$(cat interface/index.html)" 'id="tu_sni"'
check_contains "UI 有 Vision 标签" "$(cat interface/index.html)" 'VLESS+Vision+Reality'
if grep -q 'vx_security' interface/index.html; then fail "UI 不应有 vx_security"; else pass "UI 无 XUDP 安全层"; fi
if grep -q 'SOCKS5' interface/index.html; then fail "UI 不应有 SOCKS5"; else pass "UI 无 SOCKS5"; fi

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=www.apple.com' -addext 'subjectAltName=DNS:www.apple.com' \
  -keyout "${BASE_DIR}/certs/test.key" -out "${BASE_DIR}/certs/test.crt" >/dev/null 2>&1

CRT="${BASE_DIR}/certs/test.crt"
KEY="${BASE_DIR}/certs/test.key"
jq -n --arg c "$CRT" --arg k "$KEY" '{
  p1:{protocol:"vless-reality",name:"p1",port:21001,reality_server:"www.bing.com",public_key:"pk",short_id:"abcd"},
  p2:{protocol:"vless-xhttp-reality",name:"p2",port:21002,reality_server:"www.bing.com",public_key:"pk",short_id:"abcd",ws_path:"/x"},
  p3:{protocol:"vless-grpc-reality",name:"p3",port:21003,reality_server:"www.bing.com",public_key:"pk",short_id:"abcd",ws_path:"svc"},
  p4:{protocol:"vless-ws-cdn",name:"p4",port:21004,preferred_domain:"cdn.example.com",host_domain:"cdn.example.com",ws_path:"/ws",ws_mode:"cdn",cdn_port:443,cdn_sni:"cdn.example.com",certificate_mode:"self-signed",certificate_path:$c,key_path:$k},
  p5:{protocol:"vless-xhttp-cdn",name:"p5",port:21005,preferred_domain:"cdn.example.com",host_domain:"cdn.example.com",ws_path:"/xh",ws_mode:"cdn",cdn_port:443,cdn_sni:"cdn.example.com",certificate_mode:"self-signed",certificate_path:$c,key_path:$k},
  p6:{protocol:"vless-grpc-cdn",name:"p6",port:21006,preferred_domain:"cdn.example.com",host_domain:"cdn.example.com",ws_path:"svc",ws_mode:"cdn",cdn_port:443,cdn_sni:"cdn.example.com",certificate_mode:"self-signed",certificate_path:$c,key_path:$k},
  p7:{protocol:"vless-ws-argo",name:"p7",port:21007,ws_path:"/argo",endpoint_domain:"argo.example.com"},
  p8:{protocol:"vless-xhttp-argo",name:"p8",port:21008,ws_path:"/argo-x",endpoint_domain:"argo.example.com"},
  p9:{protocol:"vless-grpc-argo",name:"p9",port:21009,ws_path:"svc",endpoint_domain:"argo.example.com"},
  p10:{protocol:"hy2",name:"p10",port:21010,tls_server:"www.apple.com",certificate_mode:"self-signed",certificate_path:$c,key_path:$k,up_mbps:200,down_mbps:200},
  p11:{protocol:"tuic-v5",name:"p11",port:21011,tls_server:"www.apple.com",certificate_mode:"self-signed",certificate_path:$c,key_path:$k}
}' >"${NODES_FILE}"
jq -n '{
  p1:{uuid:"11111111-1111-1111-1111-111111111111",private_key:"gK1-0qevln1-obIttkNQRucQ9D3_vuPE8-qx42Byk1c"},
  p2:{uuid:"22222222-2222-2222-2222-222222222222",private_key:"gK1-0qevln1-obIttkNQRucQ9D3_vuPE8-qx42Byk1c"},
  p3:{uuid:"33333333-3333-3333-3333-333333333333",private_key:"gK1-0qevln1-obIttkNQRucQ9D3_vuPE8-qx42Byk1c"},
  p4:{uuid:"44444444-4444-4444-4444-444444444444"},
  p5:{uuid:"55555555-5555-5555-5555-555555555555"},
  p6:{uuid:"66666666-6666-6666-6666-666666666666"},
  p7:{uuid:"77777777-7777-7777-7777-777777777777",argo_token:""},
  p8:{uuid:"88888888-8888-8888-8888-888888888888",argo_token:""},
  p9:{uuid:"99999999-9999-9999-9999-999999999999",argo_token:""},
  p10:{password:"hy-pass"},
  p11:{uuid:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",password:"tuic-pass"}
}' >"${SECRETS_FILE}"

check_eq "node_meta 25 字段" "$(node_meta p1 | wc -l | tr -d ' ')" "25"
check_eq "node_meta 协议" "$(node_meta p1 | sed -n '1p')" "vless-reality"
check_eq "node_meta UUID" "$(node_meta p1 | sed -n '4p')" "11111111-1111-1111-1111-111111111111"

for tag in p1 p2 p3 p4 p5 p6 p7 p8 p9; do
  if render_inbound_for_tag "$tag" >/tmp/xm-${tag}.json 2>/tmp/xm-${tag}.err; then pass "render ${tag}"; else fail "render ${tag}: $(cat /tmp/xm-${tag}.err)"; fi
done
check_eq "TUIC/HY 不写入 Xray" "$(render_inbound_for_tag p10 2>/dev/null)$(render_inbound_for_tag p11 2>/dev/null)" ""
render_config
check_eq "Xray inbounds 数量" "$(jq '.inbounds|length' "${CONFIG_FILE}")" "9"
if "$XRAY_BIN" run -test -c "${CONFIG_FILE}" >/tmp/xm-xray-test.out 2>&1; then pass "Xray 配置校验"; else fail "Xray 配置校验: $(tail -3 /tmp/xm-xray-test.out)"; fi
check_contains "TUIC 配置" "$(cat "${TUIC_CONFIG_FILE}")" '"users"'
check_contains "Hysteria 配置" "$(cat "${HYSTERIA_CONFIG_FILE}")" 'type: password'

set_setting server_ip 203.0.113.10
links="$(for tag in p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11; do build_share_link "$tag"; printf '\n'; done)"
check_contains "Vision Reality 链接" "$links" 'flow=xtls-rprx-vision'
check_contains "XHTTP Reality 链接" "$links" 'type=xhttp'
check_contains "gRPC Reality 链接" "$links" 'type=grpc&serviceName='
check_contains "WS CDN 链接" "$links" 'type=ws'
check_contains "XHTTP CDN 链接" "$links" 'path=%2Fxh'
check_contains "Argo 链接" "$links" 'argo.example.com'
check_contains "Argo 端口" "$links" '@argo.example.com:443?'
check_contains "Argo SNI 为域名" "$links" 'sni=argo.example.com'
if printf '%s' "$links" | grep -Fq '@:443'; then fail "Argo 链接出现空 host"; else pass "Argo host 非空"; fi
if printf '%s' "$links" | grep -Fq 'sni=443'; then fail "Argo SNI 被端口污染"; else pass "Argo SNI 未被污染"; fi
check_contains "Hysteria2 链接" "$links" 'hysteria2://'
check_contains "TUIC 链接" "$links" 'tuic://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:tuic-pass@'
check_contains "TUIC 参数" "$links" 'congestion_control=bbr&alpn=h3'
check_contains "HY2 自签" "$links" 'insecure=1'

export tupt=21011
if auto_has_node_env; then pass "auto_has_node_env tupt"; else fail "auto_has_node_env tupt"; fi
check_contains "auto_collect_specs tupt" "$(auto_collect_specs)" 'tuic-v5 21011'
unset tupt

if [ "${FAIL}" -gt 0 ]; then
  printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
  exit 1
fi
printf '\n%d passed, 0 failed\n' "${PASS}"
