#!/usr/bin/env bash
set -euo pipefail

# ====== Параметры ======
PORT="${PORT:-443}"
PATH_NAME="${PATH_NAME:-vpn}"
DEST_HOST="${DEST_HOST:-speed.cloudflare.com}"
DEST_PORT="${DEST_PORT:-443}"
SNI="${SNI:-speed.cloudflare.com}"
TAG="${TAG:-VPN}"
LOG_LEVEL="${LOG_LEVEL:-warning}"

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
XRAY_LOG_DIR="/var/log/xray"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Запусти от root: sudo bash $0"
    exit 1
  fi
}

check_xray() {
  if ! command -v xray >/dev/null 2>&1; then
    echo "xray не найден. Сначала установи Xray-core."
    exit 1
  fi
}

gen_uuid() {
  xray uuid | tr -d '\r'
}

gen_x25519() {
  local out private_key public_key
  out="$(xray x25519)"
  private_key="$(echo "$out" | awk -F': ' '/Private key/ {print $2}' | tr -d '\r')"
  public_key="$(echo "$out" | awk -F': ' '/Public key/ {print $2}' | tr -d '\r')"

  if [[ -z "${private_key}" || -z "${public_key}" ]]; then
    echo "Не удалось получить ключи x25519."
    echo "$out"
    exit 1
  fi

  printf '%s;%s\n' "$private_key" "$public_key"
}

gen_short_id() {
  openssl rand -hex 4
}

write_config() {
  local uuid="$1"
  local private_key="$2"
  local short_id="$3"

  mkdir -p "${XRAY_CONFIG_DIR}" "${XRAY_LOG_DIR}"
  touch "${XRAY_LOG_DIR}/access.log" "${XRAY_LOG_DIR}/error.log"
  chmod 644 "${XRAY_LOG_DIR}/access.log" "${XRAY_LOG_DIR}/error.log"

  cat > "${XRAY_CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL}",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "stream-one",
          "path": "/${PATH_NAME}"
        },
        "realitySettings": {
          "dest": "${DEST_HOST}:${DEST_PORT}",
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
}

validate_and_restart() {
  if ! xray run -test -config "${XRAY_CONFIG_FILE}"; then
    echo "Конфиг не прошёл проверку."
    exit 1
  fi

  systemctl daemon-reload || true
  systemctl enable xray
  systemctl restart xray
}

main() {
  need_root
  check_xray

  UUID="$(gen_uuid)"
  KEY_PAIR="$(gen_x25519)"
  PRIVATE_KEY="${KEY_PAIR%%;*}"
  PUBLIC_KEY="${KEY_PAIR##*;}"
  SHORT_ID="$(gen_short_id)"

  write_config "${UUID}" "${PRIVATE_KEY}" "${SHORT_ID}"
  validate_and_restart

  VLESS_URL="vless://${UUID}@${DEST_HOST}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F${PATH_NAME}&mode=stream-one#${TAG}"

  echo
  echo "Готово."
  echo "Config: ${XRAY_CONFIG_FILE}"
  echo "UUID:   ${UUID}"
  echo "Public: ${PUBLIC_KEY}"
  echo "ShortID:${SHORT_ID}"
  echo
  echo "Ссылка:"
  echo "${VLESS_URL}"
  echo
  echo "Проверка:"
  echo "systemctl status xray --no-pager"
  echo "journalctl -u xray -e --no-pager"
}

main "$@"
