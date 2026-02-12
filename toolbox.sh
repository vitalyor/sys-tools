#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  SYS-TOOLS TOOLBOX (один файл)
#  Русский интерфейс, интерактивное меню
# ============================================================

TOOLBOX_NAME="sys-tools toolbox"
TOOLBOX_VERSION="0.2.0"
TOOLBOX_BUILD_DATE="2026-02-12"

# ===== Colors =====
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

line()  { echo -e "${BLUE}============================================================${RESET}"; }
h1()    { line; echo -e "${CYAN}$1${RESET}"; line; }
ok()    { echo -e "${GREEN}✔ $1${RESET}"; }
warn()  { echo -e "${YELLOW}⚠ $1${RESET}"; }
fail()  { echo -e "${RED}✘ $1${RESET}"; }
info()  { echo -e "${CYAN}• $1${RESET}"; }

pause() {
  echo
  read -rp "Нажми Enter чтобы продолжить..." _ || true
}

need_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if ! sudo -n true 2>/dev/null; then
      warn "Нужны права sudo. Возможно потребуется ввод пароля."
    fi
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

os_detect() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${PRETTY_NAME:-unknown}"
  else
    echo "unknown"
  fi
}

public_ip() {
  curl -fsS ifconfig.me 2>/dev/null || echo "N/A"
}

ssh_unit_name() {
  # На Ubuntu обычно "ssh", иногда "sshd"
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
    return
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    echo "sshd"
    return
  fi
  # fallback: попробуем активные
  if systemctl list-units --type=service 2>/dev/null | awk '{print $1}' | grep -q '^ssh\.service'; then
    echo "ssh"
    return
  fi
  if systemctl list-units --type=service 2>/dev/null | awk '{print $1}' | grep -q '^sshd\.service'; then
    echo "sshd"
    return
  fi
  echo "ssh" # default guess
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}" # Y or N
  local ans

  while true; do
    if [[ "$default" == "Y" ]]; then
      read -rp "$prompt [Y/n]: " ans || true
      ans="${ans:-Y}"
    else
      read -rp "$prompt [y/N]: " ans || true
      ans="${ans:-N}"
    fi

    case "${ans}" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) warn "Введи Y или N." ;;
    esac
  done
}

prompt_input() {
  local prompt="$1"
  local default="${2:-}"
  local ans
  if [[ -n "$default" ]]; then
    read -rp "$prompt (Enter = $default): " ans || true
    echo "${ans:-$default}"
  else
    read -rp "$prompt: " ans || true
    echo "$ans"
  fi
}

# =========================
# Fail2ban helpers
# =========================
f2b_ping() {
  sudo fail2ban-client ping >/dev/null 2>&1 && return 0
  sudo fail2ban-client -s /run/fail2ban/fail2ban.sock ping >/dev/null 2>&1 && return 0
  return 1
}

f2b_cmd() {
  # Wrapper: tries default socket, then explicit socket.
  # Usage: f2b_cmd status sshd
  if sudo fail2ban-client "$@" 2>/dev/null; then
    return 0
  fi
  sudo fail2ban-client -s /run/fail2ban/fail2ban.sock "$@" 2>/dev/null
}

f2b_installed() {
  cmd_exists fail2ban-client
}

f2b_service_active() {
  systemctl is-active --quiet fail2ban 2>/dev/null
}

f2b_sshd_jail_ok() {
  f2b_cmd status sshd >/dev/null 2>&1
}

f2b_install() {
  h1 "Fail2ban: установка"

  need_sudo

  if f2b_installed; then
    ok "Fail2ban уже установлен (fail2ban-client найден)."
    return 0
  fi

  if ! cmd_exists apt-get; then
    fail "apt-get не найден. Этот скрипт рассчитан на Debian/Ubuntu."
    return 1
  fi

  info "Шаг 1/2: apt-get update"
  sudo apt-get update -y
  ok "apt-get update: OK"

  info "Шаг 2/2: apt-get install fail2ban"
  sudo apt-get install -y fail2ban
  ok "fail2ban установлен"
}

f2b_write_config_safe() {
  local f="/etc/fail2ban/jail.d/sshd.local"

  sudo mkdir -p /etc/fail2ban/jail.d

  if [[ -s "$f" ]]; then
    ok "Конфиг уже существует и не пустой: $f (не перезаписываю)"
    return 0
  fi

  warn "Конфиг отсутствует/пустой — создаю дефолтный: $f"
  sudo tee "$f" >/dev/null <<'EOF'
[sshd]
enabled = true
backend = systemd

maxretry = 3
findtime = 10m
bantime = 24h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d
ignoreself = true
EOF
  ok "Конфиг создан: $f"
}

f2b_backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    sudo cp -a "$f" "${f}.bak-${ts}"
    ok "Бэкап: ${f}.bak-${ts}"
  fi
}

detect_ssh_port() {
  # Best-effort: read from sshd_config; otherwise 22.
  local port="22"
  local cfg="/etc/ssh/sshd_config"
  if [[ -r "$cfg" ]]; then
    # get last non-comment Port value
    local p
    p="$(grep -E '^\s*Port\s+[0-9]+' "$cfg" | awk '{print $2}' | tail -n 1 || true)"
    if [[ -n "$p" ]]; then
      port="$p"
    fi
  fi
  echo "$port"
}

f2b_write_config_force() {
  local f="/etc/fail2ban/jail.d/sshd.local"

  h1 "Fail2ban: ПРИНУДИТЕЛЬНАЯ настройка (ОПАСНО)"
  warn "Этот режим перезапишет $f вашим эталоном."
  warn "Если у вас там были ignoreip/порты/кастомные действия — они будут потеряны."

  if ! prompt_yes_no "Продолжить принудительную настройку?" "N"; then
    info "Отменено пользователем."
    return 0
  fi

  need_sudo
  sudo mkdir -p /etc/fail2ban/jail.d

  # backup
  f2b_backup_file "$f"

  # prompts
  local def_port
  def_port="$(detect_ssh_port)"
  local ssh_port
  ssh_port="$(prompt_input "Какой порт SSH защищаем (Port)?" "$def_port")"
  if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then
    fail "Некорректный порт: $ssh_port"
    return 1
  fi

  local ignoreip
  ignoreip="$(prompt_input "IgnoreIP (через запятую). Оставь пустым если не надо" "")"

  info "Перезаписываю $f"
  sudo tee "$f" >/dev/null <<EOF
[sshd]
enabled = true
backend = systemd
port = ${ssh_port}

maxretry = 3
findtime = 10m
bantime = 24h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d
ignoreself = true
EOF

  if [[ -n "${ignoreip// }" ]]; then
    echo "ignoreip = ${ignoreip}" | sudo tee -a "$f" >/dev/null
  fi

  ok "Готово: $f"
}

f2b_restart_enable() {
  need_sudo
  info "Шаг 1/2: enable fail2ban"
  sudo systemctl enable fail2ban >/dev/null 2>&1 || true
  ok "enable: OK"

  info "Шаг 2/2: restart fail2ban"
  sudo systemctl restart fail2ban || true
  ok "restart: OK"
}

f2b_configure_safe() {
  h1 "Fail2ban: безопасная настройка (без перезаписи)"
  need_sudo

  if ! f2b_installed; then
    warn "Fail2ban не установлен."
    if prompt_yes_no "Установить сейчас?" "Y"; then
      f2b_install
    else
      info "Отменено."
      return 0
    fi
  fi

  info "Шаг 1/2: конфиг sshd (safe)"
  f2b_write_config_safe
  ok "Конфиг: OK"

  info "Шаг 2/2: запуск/перезапуск сервиса"
  f2b_restart_enable
  ok "Сервис: OK"

  f2b_status_report
}

f2b_configure_force() {
  need_sudo

  if ! f2b_installed; then
    warn "Fail2ban не установлен."
    if prompt_yes_no "Установить сейчас?" "Y"; then
      f2b_install
    else
      info "Отменено."
      return 0
    fi
  fi

  f2b_write_config_force
  f2b_restart_enable
  f2b_status_report
}

f2b_status_report() {
  h1 "Fail2ban: отчёт/статистика"

  echo "Хост: $(hostname)"
  echo "ОС:   $(os_detect)"
  echo "IP:   $(public_ip)"
  echo "Дата: $(date)"
  echo

  # Service status
  info "Сервис fail2ban:"
  if systemctl list-unit-files 2>/dev/null | grep -q '^fail2ban\.service'; then
    local st
    st="$(systemctl is-active fail2ban 2>/dev/null || true)"
    if [[ "$st" == "active" ]]; then ok "fail2ban активен"; else fail "fail2ban НЕ активен ($st)"; fi
  else
    warn "Юнит fail2ban.service не найден"
  fi

  echo
  info "Пинг fail2ban-client:"
  if f2b_ping; then ok "ping OK"; else fail "ping FAILED"; fi

  echo
  info "Jail sshd:"
  if f2b_sshd_jail_ok; then
    f2b_cmd status sshd || true
  else
    warn "sshd jail недоступен (нет/не активен/ошибка)"
  fi

  echo
  info "Banned IP (sshd):"
  local bans=""
  bans="$(f2b_cmd get sshd banip 2>/dev/null || true)"
  if [[ -n "${bans// /}" ]]; then
    echo "$bans" | tr ' ' '\n' | sed '/^$/d'
  else
    warn "Список банов пуст (или jail не активен)"
  fi

  echo
  info "Firewall (f2b/fail2ban):"
  if sudo iptables -S 2>/dev/null | grep -Eq "f2b|fail2ban"; then
    ok "iptables: правила найдены"
    sudo iptables -S | grep -E "f2b|fail2ban" || true
  else
    warn "iptables: правил fail2ban не видно"
  fi

  if cmd_exists nft; then
    if sudo nft list ruleset 2>/dev/null | grep -Eq "f2b|fail2ban"; then
      ok "nft: правила найдены"
      sudo nft list ruleset 2>/dev/null | grep -E "f2b|fail2ban" || true
    else
      warn "nft: правил fail2ban не видно"
    fi
  else
    warn "nft не установлен"
  fi

  echo
  local unit
  unit="$(ssh_unit_name)"
  info "SSH логины/ошибки (journalctl -u ${unit}):"
  sudo journalctl -u "$unit" --no-pager -n 200 2>/dev/null \
    | grep -E "Failed password|Invalid user" \
    | tail -n 50 || warn "Нет совпадений (или другой unit/лог формат)"

  echo
  info "Топ атакующих (последние ~2000 строк):"
  sudo journalctl -u "$unit" --no-pager -n 2000 2>/dev/null \
    | grep -E "Failed password|Invalid user" \
    | awk '{print $NF}' \
    | sort | uniq -c | sort -nr | head -n 10 || warn "Нет совпадений"

  echo
  ok "Отчёт готов."
}

# =========================
# vnStat placeholders (будем дописывать)
# =========================
vnstat_install_stub() {
  h1 "vnStat: установка (заглушка)"
  warn "Пока не реализовано. Позже добавим установку и статистику."
  pause
}
vnstat_stats_stub() {
  h1 "vnStat: статистика (заглушка)"
  warn "Пока не реализовано."
  pause
}

# =========================
# About / System info
# =========================
about() {
  h1 "О программе"
  echo "${TOOLBOX_NAME}"
  echo "Версия: ${TOOLBOX_VERSION}"
  echo "Сборка: ${TOOLBOX_BUILD_DATE}"
  echo
  echo "Хост: $(hostname)"
  echo "ОС:   $(os_detect)"
  echo "IP:   $(public_ip)"
  echo "Дата: $(date)"
  echo
  echo "Подсказка по безопасному запуску:"
  echo "  1) Используй commit hash вместо main"
  echo "  2) Для изменения конфигов выбирай пункты меню осознанно"
  echo
  pause
}

# =========================
# Menus
# =========================
menu_fail2ban() {
  while true; do
    clear || true
    h1 "Меню: Fail2ban"
    echo "1) Установить fail2ban"
    echo "2) Настроить fail2ban (безопасно, без перезаписи конфигов)"
    echo "3) Настроить fail2ban (ПРИНУДИТЕЛЬНО, с перезаписью и бэкапом)"
    echo "4) Показать статистику/отчёт fail2ban"
    echo "0) Назад"
    echo
    read -rp "Выбор: " c || true
    case "${c:-}" in
      1) f2b_install; pause ;;
      2) f2b_configure_safe; pause ;;
      3) f2b_configure_force; pause ;;
      4) f2b_status_report; pause ;;
      0) return 0 ;;
      *) warn "Неверный выбор."; pause ;;
    esac
  done
}

menu_vnstat() {
  while true; do
    clear || true
    h1 "Меню: vnStat"
    echo "1) Установить vnStat (позже)"
    echo "2) Показать статистику (позже)"
    echo "0) Назад"
    echo
    read -rp "Выбор: " c || true
    case "${c:-}" in
      1) vnstat_install_stub ;;
      2) vnstat_stats_stub ;;
      0) return 0 ;;
      *) warn "Неверный выбор."; pause ;;
    esac
  done
}

main_menu() {
  while true; do
    clear || true
    h1 "${TOOLBOX_NAME} — v${TOOLBOX_VERSION}"
    echo "1) Fail2ban (установка / настройка / статистика)"
    echo "2) vnStat (скоро)"
    echo "9) О программе / версия / информация о системе"
    echo "0) Выход"
    echo
    read -rp "Выбор: " c || true
    case "${c:-}" in
      1) menu_fail2ban ;;
      2) menu_vnstat ;;
      9) about ;;
      0) exit 0 ;;
      *) warn "Неверный выбор."; pause ;;
    esac
  done
}

# =========================
# Entry
# =========================
main() {
  need_sudo
  main_menu
}

main "$@"
