#!/usr/bin/env bash
set -euo pipefail

f2b_ping() {
  sudo fail2ban-client ping >/dev/null 2>&1 && return 0
  sudo fail2ban-client -s /run/fail2ban/fail2ban.sock ping >/dev/null 2>&1 && return 0
  return 1
}

f2b_cmd() {
  if sudo fail2ban-client "$@" 2>/dev/null; then return 0; fi
  sudo fail2ban-client -s /run/fail2ban/fail2ban.sock "$@" 2>/dev/null
}

f2b_installed() { sys_cmd_exists fail2ban-client; }

f2b_install() {
  ui_h1 "Fail2ban — установка"
  if f2b_installed; then ui_ok "Fail2ban уже установлен."; ui_pause; return 0; fi
  sys_apt_install "fail2ban"
  ui_ok "Fail2ban установлен."
  ui_pause
}

f2b_config_safe() {
  ui_h1 "Fail2ban — настройка SAFE (не перезаписывает существующий конфиг)"
  sys_need_sudo

  if ! f2b_installed; then
    ui_warn "Fail2ban не установлен."
    ui_confirm "Установить сейчас?" "Y" && f2b_install || { ui_info "Отменено."; ui_pause; return 0; }
  fi

  local f="/etc/fail2ban/jail.d/sshd.local"
  sudo mkdir -p /etc/fail2ban/jail.d

  if [[ -s "$f" ]]; then
    ui_ok "Конфиг уже есть: $f (не трогаю)."
  else
    ui_warn "Конфига нет/пустой — создаю дефолтный: $f"
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
    ui_ok "Конфиг создан."
  fi

  sudo systemctl enable fail2ban >/dev/null 2>&1 || true
  sudo systemctl restart fail2ban || true
  ui_ok "fail2ban перезапущен."

  f2b_report
  ui_pause
}

f2b_config_force() {
  ui_h1 "Fail2ban — настройка FORCE (перезаписывает sshd.local)"
  sys_need_sudo

  if ! f2b_installed; then
    ui_warn "Fail2ban не установлен."
    ui_confirm "Установить сейчас?" "Y" && f2b_install || { ui_info "Отменено."; ui_pause; return 0; }
  fi

  ui_warn "Этот режим перезапишет /etc/fail2ban/jail.d/sshd.local"
  ui_warn "Если там были ignoreip/порт/кастомные actions — потеряешь."
  ui_confirm "Продолжить?" "N" || { ui_info "Отменено."; ui_pause; return 0; }

  local f="/etc/fail2ban/jail.d/sshd.local"
  sudo mkdir -p /etc/fail2ban/jail.d
  sys_backup_file "$f"

  local def_port
  def_port="$(sys_detect_ssh_port)"
  local ssh_port
  ssh_port="$(ui_input "Какой порт SSH защищаем?" "$def_port")"

  if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then
    ui_fail "Некорректный порт: $ssh_port"
    ui_pause
    return 1
  fi

  local ignoreip
  ignoreip="$(ui_input "ignoreip (через запятую), можно пусто" "")"

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

  sudo systemctl enable fail2ban >/dev/null 2>&1 || true
  sudo systemctl restart fail2ban || true
  ui_ok "fail2ban перезапущен."

  f2b_report
  ui_pause
}

f2b_report() {
  ui_h1 "Fail2ban — отчёт"
  ui_kv "Сервис" "$(systemctl is-active fail2ban 2>/dev/null || echo "unknown")"
  if f2b_ping; then ui_ok "fail2ban-client ping OK"; else ui_fail "fail2ban-client ping FAIL"; fi
  echo

  ui_info "Jail sshd:"
  if f2b_cmd status sshd >/dev/null 2>&1; then
    f2b_cmd status sshd || true
  else
    ui_warn "Jail sshd недоступен."
  fi

  echo
  ui_info "Ban list (sshd):"
  local bans=""
  bans="$(f2b_cmd get sshd banip 2>/dev/null || true)"
  if [[ -n "${bans// /}" ]]; then
    echo "$bans" | tr ' ' '\n' | sed '/^$/d'
  else
    ui_warn "Банов нет (или jail не активен)."
  fi

  echo
  ui_info "nft/iptables (по наличию):"
  sudo iptables -S 2>/dev/null | grep -E "f2b|fail2ban" || ui_warn "iptables: явных правил f2b не видно"
  if sys_cmd_exists nft; then
    sudo nft list ruleset 2>/dev/null | grep -E "f2b|fail2ban" || ui_warn "nft: явных правил f2b не видно"
  fi
}

plugin_fail2ban_menu() {
  while true; do
    ui_clear
    ui_h1 "Меню: Fail2ban"
    echo "1) Установить fail2ban"
    echo "2) Настроить SAFE (не перезаписывать существующий конфиг)"
    echo "3) Настроить FORCE (перезаписать sshd.local + бэкап)"
    echo "4) Показать отчёт/статистику"
    ui_menu_back_item
    echo
    c="$(ui_read_choice "Выбор")"
    case "${c:-}" in
      1) f2b_install ;;
      2) f2b_config_safe ;;
      3) f2b_config_force ;;
      4) f2b_report; ui_pause ;;
      0) return 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}
