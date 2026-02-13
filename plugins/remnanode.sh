#!/usr/bin/env bash
set -euo pipefail

# ====== Пути ======
RN_INSTALL_DIR="/opt"
RN_NODE_DIR="${RN_INSTALL_DIR}/remnanode"
RN_DATA_DIR="/var/lib/remnanode"

RN_CADDY_DIR="${RN_INSTALL_DIR}/caddy"
RN_CADDY_HTML_DIR="${RN_CADDY_DIR}/html"

# ====== Дефолты ======
RN_DEFAULT_NODE_PORT="2222"      # твой стандарт
RN_DEFAULT_SELFSTEAL_PORT="443"  # чаще всего
RN_DEFAULT_TEMPLATE_FOLDER="google"

# --------------------------
# Helpers
# --------------------------
rn_require_ubuntu_debian() { sys_ensure_apt || return 1; }

rn_install_packages() {
  rn_require_ubuntu_debian || return 1
  sys_need_sudo
  sudo apt-get update -y
  sudo apt-get install -y "$@"
}

rn_ensure_dir() {
  local d="$1"
  sudo mkdir -p "$d"
}

rn_docker_installed() { sys_cmd_exists docker; }
rn_compose_available() { docker compose version >/dev/null 2>&1; }

rn_port_in_use() {
  local port="$1"
  sudo ss -lntup 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
}

rn_port_who_uses() {
  local port="$1"
  sudo ss -lntup 2>/dev/null | grep -E "[:.]${port}\s" || true
}

rn_require_free_port_or_abort() {
  local port="$1"
  local purpose="$2"
  sys_need_sudo
  if rn_port_in_use "$port"; then
    ui_fail "Порт ${port} уже занят (${purpose})."
    ui_info "Кто слушает:"
    rn_port_who_uses "$port"
    echo
    ui_warn "Выбери другой порт, иначе сервис не запустится (network_mode: host)."
    return 1
  fi
  return 0
}

rn_get_server_ip() { sys_public_ip; }

rn_read_env_value() {
  local env_file="$1"
  local key="$2"
  if ! sudo test -r "$env_file" 2>/dev/null; then
    echo ""
    return 0
  fi
  sudo awk -F= -v k="$key" '$1==k {print substr($0, index($0, "=")+1); exit}' "$env_file" 2>/dev/null || true
}

rn_mask_secret() {
  local v="$1"
  local len="${#v}"
  if (( len <= 6 )); then
    echo "***"
  else
    printf "%s***%s\n" "${v:0:3}" "${v: -2}"
  fi
}

# --------------------------
# Docker install (Ubuntu 22/24)
# --------------------------
rn_install_docker() {
  ui_h1 "RemnaNode — установка Docker (Ubuntu 22/24)"
  sys_need_sudo
  rn_require_ubuntu_debian || { ui_pause; return 1; }

  if rn_docker_installed && rn_compose_available; then
    ui_ok "Docker и docker compose уже установлены."
    ui_pause
    return 0
  fi

  ui_warn "Будет установлен Docker Engine + docker compose plugin."
  ui_confirm "Продолжить?" "Y" || { ui_info "Отменено."; ui_pause; return 0; }

  ui_info "Шаг 1/4: зависимости"
  rn_install_packages ca-certificates curl gnupg lsb-release

  ui_info "Шаг 2/4: Docker repo keyring"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  local codename=""
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -z "$codename" ]] && codename="$(lsb_release -cs 2>/dev/null || true)"

  ui_info "Шаг 3/4: добавляем репозиторий (codename=${codename})"
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  ui_info "Шаг 4/4: установка"
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  ui_ok "Docker установлен."
  docker --version || true
  docker compose version || true
  ui_pause
}

# --------------------------
# DNS-check
# --------------------------
rn_dns_check() {
  local domain="$1"
  local server_ip="$2"

  ui_info "DNS-check: домен ${domain} должен указывать на ${server_ip}"

  if ! sys_cmd_exists dig; then
    ui_info "Устанавливаю dnsutils (dig)..."
    rn_install_packages dnsutils
  fi

  local dns_ip=""
  dns_ip="$(dig +short "$domain" A | tail -n 1 || true)"
  if [[ -z "$dns_ip" ]]; then
    ui_fail "DNS-check: A запись не найдена для ${domain}"
    return 1
  fi

  if [[ "$dns_ip" != "$server_ip" ]]; then
    ui_fail "DNS-check: домен указывает на ${dns_ip}, сервер имеет IP ${server_ip}"
    return 1
  fi

  ui_ok "DNS-check OK: ${domain} -> ${dns_ip}"
  return 0
}

# --------------------------
# Xray-core install
# --------------------------
rn_install_xray_core() {
  ui_h1 "RemnaNode — установка Xray-core"

  sys_need_sudo
  rn_require_ubuntu_debian || { ui_pause; return 1; }
  rn_ensure_dir "$RN_DATA_DIR"

  rn_install_packages wget unzip

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="64" ;;
    aarch64|arm64) arch="arm64-v8a" ;;
    armv7l|armv6l) arch="arm32-v7a" ;;
    *) ui_fail "Неподдерживаемая архитектура: $(uname -m)"; ui_pause; return 1 ;;
  esac

  ui_info "Архитектура Xray: ${arch}"
  ui_info "Получаю последнюю версию через GitHub API..."

  local api tag
  api="$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" || true)"
  [[ -z "$api" ]] && { ui_fail "Не удалось получить данные с GitHub API"; ui_pause; return 1; }

  tag="$(echo "$api" | grep -oP '"tag_name":\s*"\K[^"]+' | head -n 1 || true)"
  [[ -z "$tag" ]] && { ui_fail "Не удалось извлечь tag_name"; ui_pause; return 1; }

  ui_ok "Версия Xray-core: ${tag}"

  local filename="Xray-linux-${arch}.zip"
  local url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${filename}"

  ui_info "Скачиваю: ${url}"
  ( cd "$RN_DATA_DIR" && sudo wget --timeout=30 --tries=3 -q "$url" -O "$filename" )

  ui_info "Распаковка..."
  sudo unzip -o "${RN_DATA_DIR}/${filename}" -d "$RN_DATA_DIR" >/dev/null
  sudo rm -f "${RN_DATA_DIR}/${filename}"

  [[ ! -f "${RN_DATA_DIR}/xray" ]] && { ui_fail "Не найден ${RN_DATA_DIR}/xray"; ui_pause; return 1; }
  sudo chmod +x "${RN_DATA_DIR}/xray"

  ui_ok "Xray-core установлен."
  "${RN_DATA_DIR}/xray" version 2>/dev/null | head -n 1 || true
  ui_pause
}

# --------------------------
# RemnaNode deploy
# --------------------------
rn_write_node_files() {
  local node_port="$1"
  local secret_key="$2"
  local install_xray="$3"   # true/false

  sys_need_sudo
  rn_ensure_dir "$RN_NODE_DIR"
  rn_ensure_dir "$RN_DATA_DIR"

  ui_info "Пишу ${RN_NODE_DIR}/.env"
  sudo tee "${RN_NODE_DIR}/.env" >/dev/null <<EOF
NODE_PORT=${node_port}
SECRET_KEY=${secret_key}
EOF

  ui_info "Пишу ${RN_NODE_DIR}/docker-compose.yml"
  sudo tee "${RN_NODE_DIR}/docker-compose.yml" >/dev/null <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ghcr.io/remnawave/node:latest
    env_file:
      - .env
    network_mode: host
    restart: always
EOF

  if [[ "$install_xray" == "true" ]]; then
    sudo tee -a "${RN_NODE_DIR}/docker-compose.yml" >/dev/null <<EOF
    volumes:
      - ${RN_DATA_DIR}/xray:/usr/local/bin/xray
      - /dev/shm:/dev/shm
EOF
  else
    sudo tee -a "${RN_NODE_DIR}/docker-compose.yml" >/dev/null <<'EOF'
    # volumes:
    #   - /dev/shm:/dev/shm
EOF
  fi

  ui_ok "Файлы RemnaNode созданы."
}

rn_node_up() {
  ui_h1 "RemnaNode — запуск контейнера"
  sys_need_sudo

  rn_docker_installed || { ui_fail "Docker не установлен."; ui_pause; return 1; }
  rn_compose_available || { ui_fail "docker compose недоступен."; ui_pause; return 1; }

  ui_info "docker compose up -d в ${RN_NODE_DIR}"
  ( cd "$RN_NODE_DIR" && sudo docker compose up -d )
  ui_ok "RemnaNode запущен."
  ui_pause
}

rn_node_install_flow() {
  ui_h1 "Установка RemnaNode (node + optional Xray)"

  rn_install_docker

  local node_env_file="${RN_NODE_DIR}/.env"
  local existing_node_port="" existing_secret_key=""
  local node_port="" secret_key="" install_xray="false"
  local keep_existing_port="false"

  existing_node_port="$(rn_read_env_value "$node_env_file" "NODE_PORT")"
  existing_secret_key="$(rn_read_env_value "$node_env_file" "SECRET_KEY")"

  if [[ -n "${existing_node_port// }" ]]; then
    ui_info "Найден текущий NODE_PORT: ${existing_node_port}"
    if ui_confirm "Оставить текущий NODE_PORT?" "Y"; then
      node_port="$existing_node_port"
      keep_existing_port="true"
    else
      node_port="$(ui_input "NODE_PORT (порт API ноды на хосте)" "${existing_node_port}")"
    fi
  else
    node_port="$(ui_input "NODE_PORT (порт API ноды на хосте)" "$RN_DEFAULT_NODE_PORT")"
  fi

  if ! [[ "$node_port" =~ ^[0-9]+$ ]] || (( node_port < 1 || node_port > 65535 )); then
    ui_fail "Некорректный порт: $node_port"
    ui_pause
    return 1
  fi

  if [[ "$keep_existing_port" == "false" ]] && ! rn_require_free_port_or_abort "$node_port" "NODE_PORT (API ноды)"; then
    ui_pause
    return 1
  fi

  if [[ -n "${existing_secret_key// }" ]]; then
    ui_info "Найден текущий SECRET_KEY: $(rn_mask_secret "$existing_secret_key")"
    if ui_confirm "Оставить текущий SECRET_KEY?" "Y"; then
      secret_key="$existing_secret_key"
    else
      secret_key="$(ui_input "SECRET_KEY (ключ ноды)" "")"
    fi
  else
    secret_key="$(ui_input "SECRET_KEY (ключ ноды)" "")"
  fi

  [[ -z "${secret_key// }" ]] && { ui_fail "SECRET_KEY пустой — так нельзя."; ui_pause; return 1; }

  if sudo test -f "${RN_NODE_DIR}/docker-compose.yml" 2>/dev/null; then
    if sudo grep -q "${RN_DATA_DIR}/xray:/usr/local/bin/xray" "${RN_NODE_DIR}/docker-compose.yml" 2>/dev/null; then
      if ui_confirm "В текущем compose уже включено монтирование Xray. Оставить так?" "Y"; then
        install_xray="true"
      fi
    fi
  fi

  if ui_confirm "Установить Xray-core на хост (для монтирования в контейнер)?" "Y"; then
    if rn_install_xray_core; then
      install_xray="true"
    else
      ui_warn "Xray-core не установлен. Продолжу без него."
      install_xray="false"
    fi
  fi

  rn_write_node_files "$node_port" "$secret_key" "$install_xray"
  rn_node_up
}

# --------------------------
# Caddy selfsteal
# --------------------------
rn_template_prepare() {
  sys_need_sudo
  rn_ensure_dir "$RN_CADDY_HTML_DIR"
  sudo rm -rf "${RN_CADDY_HTML_DIR:?}/"* 2>/dev/null || true

  # минимальный шаблон (без внешних зависимостей)
  sudo tee "${RN_CADDY_HTML_DIR}/index.html" >/dev/null <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><title>OK</title></head>
<body style="font-family:system-ui; padding:40px">
<h2>Selfsteal</h2>
<p>Шаблон установлен минимальный. Позже можно расширить выбор шаблонов.</p>
</body></html>
EOF
}

rn_caddy_write_compose_and_caddyfile() {
  local domain="$1"
  local self_port="$2"
  local use_wildcard="$3"         # true/false
  local cf_token="$4"             # optional

  sys_need_sudo
  rn_ensure_dir "$RN_CADDY_DIR"
  rn_ensure_dir "$RN_CADDY_HTML_DIR"
  rn_ensure_dir "${RN_CADDY_DIR}/logs"

  local image="caddy:2.10.2"
  if [[ "$use_wildcard" == "true" ]]; then
    image="caddybuilds/caddy-cloudflare:latest"
  fi

  ui_info "Пишу ${RN_CADDY_DIR}/.env"
  sudo tee "${RN_CADDY_DIR}/.env" >/dev/null <<EOF
SELF_STEAL_DOMAIN=${domain}
SELF_STEAL_PORT=${self_port}
EOF

  if [[ "$use_wildcard" == "true" ]]; then
    echo "CLOUDFLARE_API_TOKEN=${cf_token}" | sudo tee -a "${RN_CADDY_DIR}/.env" >/dev/null
  fi

  ui_info "Пишу ${RN_CADDY_DIR}/docker-compose.yml"
  sudo tee "${RN_CADDY_DIR}/docker-compose.yml" >/dev/null <<EOF
services:
  caddy:
    image: ${image}
    container_name: caddy-selfsteal
    restart: unless-stopped
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ${RN_CADDY_HTML_DIR}:/var/www/html
      - ./logs:/var/log/caddy
      - caddy_data:/data
      - caddy_config:/config
    env_file:
      - .env
    network_mode: "host"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  caddy_data:
  caddy_config:
EOF

  ui_info "Пишу ${RN_CADDY_DIR}/Caddyfile"
  if [[ "$use_wildcard" == "true" ]]; then
    sudo tee "${RN_CADDY_DIR}/Caddyfile" >/dev/null <<'EOF'
{
	https_port {$SELF_STEAL_PORT}
	auto_https disable_redirects
}

http://{$SELF_STEAL_DOMAIN} {
	bind 0.0.0.0
	redir https://{$SELF_STEAL_DOMAIN}{uri} permanent
}

https://{$SELF_STEAL_DOMAIN} {
	tls {
		dns cloudflare {env.CLOUDFLARE_API_TOKEN}
	}
	root * /var/www/html
	try_files {path} /index.html
	file_server
}

:80 {
	bind 0.0.0.0
	respond 204
}
EOF
  else
    sudo tee "${RN_CADDY_DIR}/Caddyfile" >/dev/null <<'EOF'
{
	https_port {$SELF_STEAL_PORT}
	auto_https disable_redirects
}

http://{$SELF_STEAL_DOMAIN} {
	bind 0.0.0.0
	redir https://{$SELF_STEAL_DOMAIN}{uri} permanent
}

https://{$SELF_STEAL_DOMAIN} {
	root * /var/www/html
	try_files {path} /index.html
	file_server
}

:80 {
	bind 0.0.0.0
	respond 204
}
EOF
  fi

  ui_ok "Caddy selfsteal конфиги созданы."
}

rn_caddy_up() {
  ui_h1 "Caddy selfsteal — запуск"
  sys_need_sudo

  rn_docker_installed || { ui_fail "Docker не установлен."; ui_pause; return 1; }
  rn_compose_available || { ui_fail "docker compose недоступен."; ui_pause; return 1; }

  ( cd "$RN_CADDY_DIR" && sudo docker compose up -d )
  ui_ok "Caddy selfsteal запущен."
  ui_pause
}

rn_caddy_install_flow() {
  ui_h1 "Установка Caddy selfsteal (DNS-check + cert)"

  rn_install_docker

  local caddy_env_file="${RN_CADDY_DIR}/.env"
  local existing_domain="" existing_self_port="" existing_cf_token=""
  local domain="" self_port="" choice="" use_wildcard="false" cf_token=""
  local keep_existing_port="false"

  existing_domain="$(rn_read_env_value "$caddy_env_file" "SELF_STEAL_DOMAIN")"
  existing_self_port="$(rn_read_env_value "$caddy_env_file" "SELF_STEAL_PORT")"
  existing_cf_token="$(rn_read_env_value "$caddy_env_file" "CLOUDFLARE_API_TOKEN")"

  if [[ -n "${existing_domain// }" ]]; then
    ui_info "Найден текущий домен: ${existing_domain}"
    if ui_confirm "Оставить текущий домен?" "Y"; then
      domain="$existing_domain"
    else
      domain="$(ui_input "Домен (совпадает с realitySettings.serverNames)" "${existing_domain}")"
    fi
  else
    domain="$(ui_input "Домен (совпадает с realitySettings.serverNames)" "")"
  fi

  [[ -z "${domain// }" ]] && { ui_fail "Домен пустой."; ui_pause; return 1; }

  if [[ -n "${existing_self_port// }" ]]; then
    ui_info "Найден текущий SELF_STEAL_PORT: ${existing_self_port}"
    if ui_confirm "Оставить текущий SELF_STEAL_PORT?" "Y"; then
      self_port="$existing_self_port"
      keep_existing_port="true"
    else
      self_port="$(ui_input "SELF_STEAL_PORT (порт Caddy на хосте)" "${existing_self_port}")"
    fi
  else
    self_port="$(ui_input "SELF_STEAL_PORT (порт Caddy на хосте)" "$RN_DEFAULT_SELFSTEAL_PORT")"
  fi

  if ! [[ "$self_port" =~ ^[0-9]+$ ]] || (( self_port < 1 || self_port > 65535 )); then
    ui_fail "Некорректный порт: $self_port"
    ui_pause
    return 1
  fi

  if [[ "$keep_existing_port" == "false" ]] && ! rn_require_free_port_or_abort "$self_port" "SELF_STEAL_PORT (Caddy selfsteal)"; then
    ui_pause
    return 1
  fi

  local server_ip
  server_ip="$(rn_get_server_ip)"
  ui_info "IP сервера: ${server_ip}"

  if ! rn_dns_check "$domain" "$server_ip"; then
    ui_warn "DNS-check не прошёл."
    ui_confirm "Продолжить несмотря на это?" "N" || { ui_info "Отменено."; ui_pause; return 0; }
  fi

  ui_info "Тип сертификата:"
  echo "1) Обычный (HTTP-01)"
  echo "2) Wildcard (DNS-01 через Cloudflare)"
  choice="$(ui_input "Выбор 1/2" "1")"

  if [[ "$choice" == "2" ]]; then
    use_wildcard="true"
    if [[ -n "${existing_cf_token// }" ]]; then
      ui_info "Найден текущий Cloudflare API Token: $(rn_mask_secret "$existing_cf_token")"
      if ui_confirm "Оставить текущий Cloudflare API Token?" "Y"; then
        cf_token="$existing_cf_token"
      else
        cf_token="$(ui_input "Cloudflare API Token (Zone Read + DNS Edit)" "")"
      fi
    else
      cf_token="$(ui_input "Cloudflare API Token (Zone Read + DNS Edit)" "")"
    fi
    [[ -z "${cf_token// }" ]] && { ui_fail "Cloudflare token пустой."; ui_pause; return 1; }
  fi

  ui_info "Шаблон selfsteal: используется минимальный встроенный."
  rn_template_prepare

  rn_caddy_write_compose_and_caddyfile "$domain" "$self_port" "$use_wildcard" "$cf_token"
  rn_caddy_up
}

rn_apply_network_tuning() {
  ui_h1 "RemnaNode — сетевые настройки (BBR/TCP/лимиты)"
  sys_need_sudo

  ui_confirm "Применить оптимизацию сетевых настроек (BBR, TCP tuning, лимиты)?" "N" || { ui_info "Отменено."; ui_pause; return 0; }

  local sysctl_file="/etc/sysctl.d/99-remnawave-tuning.conf"
  local limits_file="/etc/security/limits.d/99-remnawave.conf"
  local modules_file="/etc/modules-load.d/99-remnawave.conf"
  local systemd_conf_dir="/etc/systemd/system.conf.d"
  local systemd_conf_file="${systemd_conf_dir}/99-remnawave.conf"
  local tuning_service_file="/etc/systemd/system/remnawave-tuning.service"
  local icmp_mode=""

  if sudo test -f "$sysctl_file" 2>/dev/null; then
    ui_warn "Файл уже существует: ${sysctl_file}"
    ui_confirm "Перезаписать его?" "N" || { ui_info "Сетевые настройки не изменены."; ui_pause; return 0; }
  fi

  echo
  ui_info "Режим ICMP (ping):"
  echo "1) Оставить по умолчанию (рекомендуется)"
  echo "2) Скрыть узел от ping (icmp echo ignore)"
  echo "3) Явно разрешить ответы на ping"
  icmp_mode="$(ui_input "Выбор 1/2/3" "1")"
  case "${icmp_mode:-}" in
    1|2|3) ;;
    *) ui_warn "Неверный выбор, использую режим 1."; icmp_mode="1" ;;
  esac

  ui_info "Проверка поддержки BBR..."
  if ! grep -q "tcp_bbr" /proc/modules 2>/dev/null; then
    sudo modprobe tcp_bbr 2>/dev/null || true
  fi
  if lsmod | grep -q "tcp_bbr" 2>/dev/null; then
    ui_ok "Модуль BBR загружен."
  else
    ui_warn "BBR может быть недоступен на этом ядре."
  fi

  ui_info "Создаю ${sysctl_file}..."
  sudo tee "$sysctl_file" >/dev/null <<'EOF'
# Remnawave Network Tuning Configuration

# IPv6 (disabled)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# IPv4 routing and anti-spoofing
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# TCP tuning and BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# TCP keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15

# Socket buffers (16 MB)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Security
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1

# System limits
fs.file-max = 2097152
vm.swappiness = 10
vm.overcommit_memory = 1
EOF

  case "$icmp_mode" in
    2)
      sudo tee -a "$sysctl_file" >/dev/null <<'EOF'

# ICMP
net.ipv4.icmp_echo_ignore_all = 1
EOF
      ;;
    3)
      sudo tee -a "$sysctl_file" >/dev/null <<'EOF'

# ICMP
net.ipv4.icmp_echo_ignore_all = 0
EOF
      ;;
  esac

  ui_info "Настраиваю автозагрузку модуля BBR: ${modules_file}"
  sudo tee "$modules_file" >/dev/null <<'EOF'
tcp_bbr
EOF
  sudo systemctl restart systemd-modules-load 2>/dev/null || true

  ui_ok "Конфигурация создана: ${sysctl_file}"

  ui_info "Применяю sysctl..."
  if sudo sysctl -p "$sysctl_file" >/dev/null 2>&1; then
    ui_ok "Настройки sysctl применены."
  else
    ui_warn "Некоторые параметры не применились."
    sudo sysctl -p "$sysctl_file" 2>&1 | grep -Ei "error|invalid" || true
  fi

  ui_info "Настраиваю лимиты: ${limits_file}"
  sudo tee "$limits_file" >/dev/null <<'EOF'
# Remnawave File Limits
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 65535
root hard nproc 65535
EOF
  ui_ok "Лимиты файлов настроены."

  ui_info "Настраиваю systemd лимиты: ${systemd_conf_file}"
  sudo mkdir -p "$systemd_conf_dir"
  sudo tee "$systemd_conf_file" >/dev/null <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF
  sudo systemctl daemon-reexec 2>/dev/null || true
  ui_ok "Systemd лимиты настроены."

  ui_info "Создаю сервис персистентного применения тюнинга: ${tuning_service_file}"
  sudo tee "$tuning_service_file" >/dev/null <<EOF
[Unit]
Description=Remnawave persistent sysctl tuning
After=systemd-modules-load.service systemd-sysctl.service network-online.target
Wants=systemd-modules-load.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -p ${sysctl_file}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable remnawave-tuning.service >/dev/null 2>&1 || true
  sudo systemctl start remnawave-tuning.service >/dev/null 2>&1 || true
  ui_ok "Boot-сервис тюнинга включён."

  echo
  ui_info "Проверка применённых параметров:"
  ui_kv "BBR" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")"
  ui_kv "IP Forward" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "unknown")"
  ui_kv "TCP FastOpen" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "unknown")"
  ui_kv "File Max" "$(sysctl -n fs.file-max 2>/dev/null || echo "unknown")"
  ui_kv "Somaxconn" "$(sysctl -n net.core.somaxconn 2>/dev/null || echo "unknown")"
  ui_kv "ICMP Echo Ignore" "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo "default")"
  ui_kv "BBR Module" "$(lsmod | awk '$1=="tcp_bbr"{print "loaded"; found=1} END{if(!found) print "not loaded"}' 2>/dev/null || echo "unknown")"
  ui_kv "Tune Service" "$(systemctl is-enabled remnawave-tuning.service 2>/dev/null || echo "unknown")"
  echo
  rn_verify_network_tuning "$sysctl_file" "$modules_file" "$tuning_service_file"
  echo
  ui_warn "Для полного применения лимитов рекомендуется перезагрузка."
  ui_pause
}

rn_verify_network_tuning() {
  local sysctl_file="$1"
  local modules_file="$2"
  local service_file="$3"
  local ok=0 warn=0

  ui_h1 "Проверка тюнинга"

  if sudo test -f "$sysctl_file" 2>/dev/null; then
    ui_ok "Есть sysctl конфиг: ${sysctl_file}"
    ok=$((ok + 1))
  else
    ui_warn "Нет sysctl конфига: ${sysctl_file}"
    warn=$((warn + 1))
  fi

  if sudo test -f "$modules_file" 2>/dev/null && sudo grep -qx "tcp_bbr" "$modules_file" 2>/dev/null; then
    ui_ok "Автозагрузка BBR настроена: ${modules_file}"
    ok=$((ok + 1))
  else
    ui_warn "Автозагрузка BBR не настроена: ${modules_file}"
    warn=$((warn + 1))
  fi

  if sudo test -f "$service_file" 2>/dev/null; then
    ui_ok "Есть boot-сервис: ${service_file}"
    ok=$((ok + 1))
  else
    ui_warn "Нет boot-сервиса: ${service_file}"
    warn=$((warn + 1))
  fi

  if systemctl is-enabled remnawave-tuning.service >/dev/null 2>&1; then
    ui_ok "Сервис включён в автозапуск."
    ok=$((ok + 1))
  else
    ui_warn "Сервис не включён в автозапуск."
    warn=$((warn + 1))
  fi

  if systemctl is-active remnawave-tuning.service >/dev/null 2>&1; then
    ui_ok "Сервис активен."
    ok=$((ok + 1))
  else
    ui_warn "Сервис не активен."
    warn=$((warn + 1))
  fi

  if lsmod | grep -q "^tcp_bbr" 2>/dev/null; then
    ui_ok "Модуль tcp_bbr загружен."
    ok=$((ok + 1))
  else
    ui_warn "Модуль tcp_bbr не загружен."
    warn=$((warn + 1))
  fi

  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]]; then
    ui_ok "TCP congestion control = bbr"
    ok=$((ok + 1))
  else
    ui_warn "TCP congestion control не bbr"
    warn=$((warn + 1))
  fi

  if [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" == "fq" ]]; then
    ui_ok "default_qdisc = fq"
    ok=$((ok + 1))
  else
    ui_warn "default_qdisc не fq"
    warn=$((warn + 1))
  fi

  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == "1" ]]; then
    ui_ok "ip_forward = 1"
    ok=$((ok + 1))
  else
    ui_warn "ip_forward не включён"
    warn=$((warn + 1))
  fi

  local icmp_echo_ignore=""
  icmp_echo_ignore="$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo "unknown")"
  local icmp_in_cfg=""
  icmp_in_cfg="$(sudo awk -F= '/^\s*net\.ipv4\.icmp_echo_ignore_all\s*=/{gsub(/[[:space:]]/,"",$2); v=$2} END{if(v=="") print "not_set"; else print v}' "$sysctl_file" 2>/dev/null || echo "unknown")"
  if [[ "$icmp_echo_ignore" == "1" ]]; then
    ui_ok "ICMP echo скрыт (icmp_echo_ignore_all = 1)"
    ok=$((ok + 1))
  elif [[ "$icmp_echo_ignore" == "0" ]]; then
    ui_warn "ICMP echo разрешён (icmp_echo_ignore_all = 0) — ping будет идти"
    warn=$((warn + 1))
  else
    ui_warn "ICMP echo статус неизвестен (icmp_echo_ignore_all = ${icmp_echo_ignore})"
    warn=$((warn + 1))
  fi

  if [[ "$icmp_in_cfg" == "1" || "$icmp_in_cfg" == "0" ]]; then
    ui_ok "ICMP параметр в конфиге: ${icmp_in_cfg}"
    ok=$((ok + 1))
  else
    ui_warn "ICMP параметр в конфиге не зафиксирован (icmp_echo_ignore_all)"
    warn=$((warn + 1))
  fi

  echo
  ui_info "Итог проверки: OK=${ok}, WARN=${warn}"
}

rn_check_network_tuning_status() {
  local sysctl_file="/etc/sysctl.d/99-remnawave-tuning.conf"
  local modules_file="/etc/modules-load.d/99-remnawave.conf"
  local tuning_service_file="/etc/systemd/system/remnawave-tuning.service"

  rn_verify_network_tuning "$sysctl_file" "$modules_file" "$tuning_service_file"
  ui_pause
}

rn_network_tuning_menu() {
  local c
  while true; do
    ui_clear
    ui_h1 "RemnaNode — сетевой тюнинг"
    echo "1) Применить сетевые настройки (BBR/TCP tuning/лимиты)"
    echo "2) Проверить сетевой тюнинг (без изменений)"
    ui_menu_back_item
    echo
    c="$(ui_read_choice "Выбор")"
    case "${c:-}" in
      1) rn_apply_network_tuning ;;
      2) rn_check_network_tuning_status ;;
      0) return 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}

rn_status() {
  ui_h1 "RemnaNode / Caddy — статус"
  sys_need_sudo

  ui_info "Контейнеры (remnanode|caddy-selfsteal):"
  sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "remnanode|caddy-selfsteal" || ui_warn "Не вижу контейнеров remnanode/caddy-selfsteal"
  echo

  ui_info "Listening ports (ss -lntuop):"
  sudo ss -lntuop | head -n 120 || true
  ui_pause
}

# --------------------------
# MENU
# --------------------------
plugin_remnanode_menu() {
  while true; do
    ui_clear
    ui_h1 "Меню: RemnaNode (единый ключ)"
    echo "1) Установить Docker + docker compose"
    echo "2) Установить Xray-core (в /var/lib/remnanode/xray)"
    echo "3) Установить/настроить RemnaNode (SECRET_KEY, NODE_PORT=${RN_DEFAULT_NODE_PORT})"
    echo "4) Установить/настроить Caddy selfsteal (DNS-check, cert, порт=${RN_DEFAULT_SELFSTEAL_PORT})"
    echo "5) Статус RemnaNode/Caddy"
    echo "6) Сетевые настройки (применить/проверить)"
    ui_menu_back_item
    echo
    c="$(ui_read_choice "Выбор")"
    case "${c:-}" in
      1) rn_install_docker ;;
      2) rn_install_xray_core ;;
      3) rn_node_install_flow ;;
      4) rn_caddy_install_flow ;;
      5) rn_status ;;
      6) rn_network_tuning_menu ;;
      0) return 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}
