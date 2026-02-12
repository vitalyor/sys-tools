#!/usr/bin/env bash
set -euo pipefail

RN_INSTALL_URL_DEFAULT="https://raw.githubusercontent.com/Case211/remnanode-install/refs/heads/main/remnanode-install.sh"

remnanode_run_installer() {
  ui_h1 "RemnaNode Install — запуск установщика"
  sys_need_sudo

  local url
  url="$(ui_input "URL установщика" "$RN_INSTALL_URL_DEFAULT")"

  ui_warn "Ты запускаешь удалённый скрипт. Это риск. Делай только если доверяешь источнику."
  ui_confirm "Продолжить?" "N" || { ui_info "Отменено."; ui_pause; return 0; }

  local port secret
  port="$(ui_input "Порт ноды (например 443/8443/2053 и т.п.)" "443")"
  secret="$(ui_input "Секрет/ключ (если нужен установщику)" "")"

  ui_info "Скачиваю установщик во временный файл..."
  local tmp="/tmp/remnanode-install.$$.sh"
  curl -fsSL "$url" -o "$tmp"
  chmod +x "$tmp"
  ui_ok "Скачано: $tmp"

  ui_info "Запуск. Если установщик задаёт вопросы — отвечай в интерактиве."
  echo
  # ВНИМАНИЕ: мы не знаем точные аргументы установщика, поэтому:
  # 1) сначала пробуем передать PORT и SECRET через env (универсально),
  # 2) если ему это не нужно, он просто проигнорит.
  PORT="$port" SECRET="$secret" sudo -E bash "$tmp"

  ui_ok "Установщик завершился (проверь вывод выше)."
  ui_pause
}

plugin_remnanode_install_menu() {
  while true; do
    ui_clear
    ui_h1 "Меню: RemnaNode Install"
    echo "1) Запустить установщик remnanode-install"
    echo "0) Назад"
    echo
    read -rp "Выбор: " c || true
    case "${c:-}" in
      1) remnanode_run_installer ;;
      0) return 0 ;;
      *) ui_warn "Неверный выбор."; ui_pause ;;
    esac
  done
}
