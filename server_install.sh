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
  # Критично: ждём, пока xray попадёт в PATH
  sleep 2
  hash -r || true
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

  cat > "${XRAY_CONFIG_FILE}" <<'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": PORT_PLACEHOLDER,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "UUID_PLACEHOLDER",
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
          "path": "/PATH_PLACEHOLDER"
        },
        "realitySettings": {
          "dest": "DEST_PLACEHOLDER",
          "serverNames": ["SNI_PLACEHOLDER"],
          "privateKey": "PRIVATEKEY_PLACEHOLDER",
          "shortIds": ["SHORTID_PLACEHOLDER"]
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

  # Безопасная подстановка (избегаем проблем с heredoc + переменными)
  sed -i "s/PORT_PLACEHOLDER/${PORT}/g" "${XRAY_CONFIG_FILE}"
  sed -i "s|UUID_PLACEHOLDER|${uuid}|g" "${XRAY_CONFIG_FILE}"
  sed -i "s|PATH_PLACEHOLDER|${PATH_NAME}|g" "${XRAY_CONFIG_FILE}"
  sed -i "s|DEST_PLACEHOLDER|${DEST_HOST}:${DEST_PORT}|g" "${XRAY_CONFIG_FILE}"
  sed -i "s|SNI_PLACEHOLDER|${SNI}|g" "${XRAY_CONFIG_FILE}"
  sed -i "s|PRIVATEKEY_PLACEHOLDER|${private_key}|g" "${XRAY_CONFIG_FILE}"
  sed -i "s|SHORTID_PLACEHOLDER|${short_id}|g" "${XRAY_CONFIG_FILE}"

  if [[ ! -s "${XRAY_CONFIG_FILE}" ]]; then
    printf '%s\n' "ОШИБКА: config.json пустой!" >&2
    exit 1
  fi

  chmod 600 "${XRAY_CONFIG_FILE}"
  printf '%s\n' "Конфиг успешно записан: ${XRAY_CONFIG_FILE} (размер: $(wc -c < "${XRAY_CONFIG_FILE}") байт)"
}

print_config() {
  if [[ ! -f "${XRAY_CONFIG_FILE}" ]]; then
    printf '%s\n' "ОШИБКА: Файл конфига не найден!" >&2
    return 1
  fi
  printf '\n%s\n' "===== FULL CONFIG: ${XRAY_CONFIG_FILE} ====="
  cat "${XRAY_CONFIG_FILE}"
  printf '%s\n' "===== END CONFIG ====="
  printf '\n'
}

validate_and_restart() {
  systemctl daemon-reload || true

  if ! systemctl list-unit-files | grep -q '^xray\.service'; then
    printf '%s\n' "systemd unit xray.service не найден!" >&2
    exit 1
  fi

  systemctl enable xray --now >/dev/null 2>&1 || true

  printf '%s\n' "Выполняется проверка конфига (xray run -test)..."
  if ! xray run -test -config "${XRAY_CONFIG_FILE}"; then
    printf '%s\n' "=== КОНФИГ НЕ ПРОШЁЛ ВАЛИДАЦИЮ! ===" >&2
    printf '%s\n' "Проверь логи ошибки выше." >&2
    exit 1
  fi

  printf '%s\n' "Конфиг валидный. Перезапускаем Xray..."
  systemctl restart xray
  printf '%s\n' "Xray успешно перезапущен."
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
  printf '\nПроверка:\n  systemctl status xray --no-pager\n  journalctl -u xray -e --no-pager\n'
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

  print_final_info "${UUID}" "${PRIVATE_KEY}" "${PUBLIC_KEY}" "${SHORT_ID}" "${VLESS_URL}"
}

main "$@"
