#!/usr/bin/env bash
set -euo pipefail

# ====== Параметры по умолчанию ======
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
INSTALL_SCRIPT="/tmp/install-release.sh"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf '%s\n' "Запусти скрипт от root: sudo bash $0"
    exit 1
  fi
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl unzip openssl ca-certificates ufw
}

download_install_script() {
  rm -f "${INSTALL_SCRIPT}"
  local urls=(
    "https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
    "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
  )
  for url in "${urls[@]}"; do
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 "$url" -o "${INSTALL_SCRIPT}"; then
      if head -n 1 "${INSTALL_SCRIPT}" | grep -q '^#!'; then
        chmod +x "${INSTALL_SCRIPT}"
        return 0
      fi
    fi
  done
  printf '%s\n' "Не удалось скачать корректный install-release.sh." >&2
  exit 1
}

install_xray() {
  download_install_script
  bash "${INSTALL_SCRIPT}" install
  rm -f "${INSTALL_SCRIPT}"
}

gen_uuid() {
  xray uuid | tr -d '\r'
}

gen_x25519() {
  local out private_key public_key
  out="$(xray x25519 2>&1)"
  private_key="$(echo "$out" | awk -F': ' '/Private key/ {print $2}' | tr -d '\r')"
  public_key="$(echo "$out" | awk -F': ' '/Public key/ {print $2}' | tr -d '\r')"
  
  if [[ -z "${private_key}" || -z "${public_key}" ]]; then
    printf '%s\n' "Не удалось распарсить xray x25519:" >&2
    printf '%s\n' "$out" >&2
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
  chmod 700 "${XRAY_CONFIG_DIR}"
  chmod 600 "${XRAY_LOG_DIR}"/*.log 2>/dev/null || true

  cat > "${XRAY_CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL}",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
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
          "serverNames": ["${SNI}"],
          "privateKey": "${private_key}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "blocked" }
    ]
  }
}
EOF
  chmod 600 "${XRAY_CONFIG_FILE}"
}

print_config() {
  printf '\n%s\n' "===== FULL CONFIG: ${XRAY_CONFIG_FILE} ====="
  cat "${XRAY_CONFIG_FILE}"
  printf '%s\n' "===== END CONFIG ====="
  printf '\n'
}

validate_and_restart() {
  systemctl daemon-reload || true
  
  if ! systemctl list-unit-files | grep -q '^xray\.service'; then
    printf '%s\n' "systemd unit xray.service не найден. Проверь установку." >&2
    exit 1
  fi

  systemctl enable xray --now >/dev/null 2>&1 || true

  if xray run -test -config "${XRAY_CONFIG_FILE}"; then
    systemctl restart xray
    printf '%s\n' "Xray успешно перезапущен."
  else
    printf '%s\n' "Конфиг не прошёл проверку xray run -test!" >&2
    exit 1
  fi
}

open_firewall() {
  ufw allow 22/tcp || true
  ufw allow "${PORT}/tcp" || true
  ufw --force enable || true
}

print_final_info() {
  local uuid="$1"
  local private_key="$2"
  local public_key="$3"
  local short_id="$4"
  local vless_url="$5"

  print_config

  printf '%s\n' "Готово."
  printf '%s\n' "UUID: ${uuid}"
  printf '%s\n' "PrivateKey: ${private_key}"
  printf '%s\n' "PublicKey: ${public_key}"
  printf '%s\n' "ShortID: ${short_id}"
  printf '%s\n' "Config: ${XRAY_CONFIG_FILE}"
  printf '%s\n' "Link:"
  printf '%s\n' "${vless_url}"
  printf '\n'
  printf '%s\n' "Проверка:"
  printf '%s\n' "  systemctl status xray --no-pager"
  printf '%s\n' "  journalctl -u xray -e --no-pager"
  printf '\n'
}

main() {
  need_root
  install_deps
  install_xray

  UUID="$(gen_uuid)"
  KEY_PAIR="$(gen_x25519)"
  PRIVATE_KEY="${KEY_PAIR%%;*}"
  PUBLIC_KEY="${KEY_PAIR##*;}"
  SHORT_ID="$(gen_short_id)"

  VLESS_URL="vless://${UUID}@${DEST_HOST}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F${PATH_NAME}&mode=stream-one#${TAG}"

  write_config "${UUID}" "${PRIVATE_KEY}" "${SHORT_ID}"
  open_firewall
  validate_and_restart

  # Главный вывод в конце — теперь он почти гарантированно будет
  print_final_info "${UUID}" "${PRIVATE_KEY}" "${PUBLIC_KEY}" "${SHORT_ID}" "${VLESS_URL}"
}

main "$@"
