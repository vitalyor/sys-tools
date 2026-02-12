#!/usr/bin/env bash
set -euo pipefail

ufw_installed() { sys_cmd_exists ufw; }

firewall_install_ufw() {
  ui_h1 "Firewall — установка UFW"
  if ufw_installed; then ui_ok "ufw уже установлен."; ui_pause; return 0; fi
  sys_apt_install "ufw"
  ui_ok "ufw установлен."
  ui_pause
}

firewall_status() {
  ui_h1 "Firewall — статус"
  if ufw_installed; then
    sudo ufw status verbose || true
  else
    ui_warn "ufw не установлен."
  fi
  echo
  ui_info "Listening ports (ss -lntuop):"
  sudo ss -lntuop || true
  ui_pause
}

firewall_enable_basic() {
  ui_h1 "Firewall — включить UFW (базовая настройка)"
  sys_need_sudo
  ufw_installed || { ui_warn "ufw не установлен."; ui_confirm "Установить?" "Y" && firewall_install_ufw || { ui_pause; return 0; }; }

  local ssh_port
  ssh_port="$(ui_input "Какой порт SSH разрешить ДО включения firewall?" "$(sys_detect_ssh_port)")"

  ui_warn "Если ошибёшься с SSH портом — можешь потерять доступ."
  ui_confirm "Продолжить?" "N" || { ui_info "Отменено."; ui_pause; return 0; }

  sudo ufw allow "${ssh_port}/tcp" || true
  sudo ufw default deny incoming || true
  sudo ufw default allow outgoing || true
  sudo ufw --force enable || true

  ui_ok "UFW включён. SSH разрешён на порту ${ssh_port}/tcp."
  firewall_status
}

firewall_allow_rule() {
  ui_h1 "Firewall — добавить правило allow"
  sys_need_sudo
  ufw_installed || { ui_warn "ufw не установлен."; ui_pause; return 0; }

  local port proto
  port="$(ui_input "Порт" "")"
  proto="$(ui_input "Протокол (tcp/udp)" "tcp")"

  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    ui_fail "Некорректный порт."
    ui_pause
    return 1
  fi

  sudo ufw allow "${port}/${proto}" || true
  ui_ok "Добавлено: allow ${port}/${proto}"
  sudo ufw status numbered || true
  ui_pause
}

firewall_delete_rule() {
  ui_h1 "Firewall — удалить правило"
  sys_need_sudo
  ufw_installed || { ui_warn "ufw не установлен."; ui_pause; return 0; }

  ui_info "Текущие правила (numbered):"
  sudo ufw status numbered || true
  echo
  local n
  n="$(ui_input "Номер правила для удаления" "")"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    ui_fail "Номер должен быть числом."
    ui_pause
    return 1
  fi
  sudo ufw delete "$n" || true
  ui_ok "Правило удалено."
  ui_pause
}

firewall_listening_ports() {
  ui_h1 "Ports — какие порты слушаются сейчас"
  sudo ss -lntuop || true
  ui_pause
}

ssh_audit_top_ips() {
  ui_h1 "SSH Audit — топ атакующих IP (исправлено)"
  local unit
  unit="$(sys_detect_ssh_unit)"
  ui_info "Использую systemd unit: ${unit}"

  sudo journalctl -u "$unit" --no-pager -n 3000 2>/dev/null \
    | grep -E "Failed password|Invalid user" \
    | grep -oE 'from ([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | awk '{print $2}' \
    | sort | uniq -c | sort -nr | head -n 20 || ui_warn "Совпадений не найдено."
  ui_pause
}

plugin_firewall_menu() {
  while true; do
    ui_clear
    ui_h1 "Меню: Firewall / Ports"
    echo "1) Установить ufw"
    echo "2) Статус ufw"
    echo "3) Показать правила ufw (с номерами)"
    echo "4) Включить ufw (deny incoming, allow outgoing, allow ssh)"
    echo "5) Добавить allow правило (порт/протокол)"
    echo "6) Удалить правило по номеру"
    echo "7) Показать слушающие порты (ss)"
    echo "8) SSH audit: топ атакующих IP"
    echo "0) Назад"
    echo
    read -rp "Выбор: " c || true

    case "${c:-}" in
      1) firewall_install_ufw ;;
      2) firewall_status ;;
      3) fw_show_rules ;;
      4) firewall_enable_basic ;;
      5) firewall_allow_rule ;;
      6) firewall_delete_rule ;;
      7) firewall_listening_ports ;;
      8) ssh_audit_top_ips ;;
      0) return 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}

fw_show_rules() {
  ui_h1 "UFW — правила (с номерами)"
  if ! sys_cmd_exists ufw; then
    ui_warn "ufw не установлен."
    ui_pause
    return 0
  fi

  local rules_output
  echo
  rules_output="$(sudo ufw status numbered 2>&1 || true)"
  echo "$rules_output"
  if [[ "$rules_output" == *"Status: inactive"* ]]; then
    echo
    ui_info "UFW не активен. После включения здесь появятся правила."
  fi

  ui_pause
}
