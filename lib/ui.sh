#!/usr/bin/env bash
set -euo pipefail

RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"
BLUE="\033[1;34m"; CYAN="\033[1;36m"; RESET="\033[0m"
UI_INTERRUPTED=0

ui_line()  { echo -e "${BLUE}============================================================${RESET}"; }
ui_h1()    { ui_line; echo -e "${CYAN}$1${RESET}"; ui_line; }
ui_ok()    { echo -e "${GREEN}✔ $1${RESET}"; }
ui_warn()  { echo -e "${YELLOW}⚠ $1${RESET}"; }
ui_fail()  { echo -e "${RED}✘ $1${RESET}"; }
ui_info()  { echo -e "${CYAN}• $1${RESET}"; }

ui_kv() { printf "%-14s: %s\n" "$1" "$2"; }

ui_clear() { clear 2>/dev/null || true; }

ui_pause() {
  echo
  read -rp "Нажми Enter чтобы продолжить..." _ || true
  if [[ "${UI_INTERRUPTED:-0}" == "1" ]]; then
    UI_INTERRUPTED=0
  fi
}

ui_on_interrupt() {
  UI_INTERRUPTED=1
  echo
}

ui_enable_interrupt_guard() {
  trap 'ui_on_interrupt' INT
}

ui_confirm() {
  local prompt="$1"
  local def="${2:-N}" # Y|N
  local ans=""
  while true; do
    if [[ "$def" == "Y" ]]; then
      read -rp "${prompt} [Y/n]: " ans || true
      ans="${ans:-Y}"
    else
      read -rp "${prompt} [y/N]: " ans || true
      ans="${ans:-N}"
    fi
    if [[ "${UI_INTERRUPTED:-0}" == "1" ]]; then
      UI_INTERRUPTED=0
      ui_info "Отменено (Ctrl+C)."
      return 1
    fi
    case "$ans" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) ui_warn "Введи Y или N." ;;
    esac
  done
}

ui_input() {
  local prompt="$1"
  local def="${2:-}"
  local ans=""
  if [[ -n "$def" ]]; then
    read -rp "${prompt} (Enter = ${def}): " ans || true
    if [[ "${UI_INTERRUPTED:-0}" == "1" ]]; then
      UI_INTERRUPTED=0
      echo ""
      return 0
    fi
    echo "${ans:-$def}"
  else
    read -rp "${prompt}: " ans || true
    if [[ "${UI_INTERRUPTED:-0}" == "1" ]]; then
      UI_INTERRUPTED=0
      echo ""
      return 0
    fi
    echo "$ans"
  fi
}

ui_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

ui_read_choice() {
  local prompt="${1:-Выбор}"
  local ans=""
  read -rp "${prompt}: " ans || true
  if [[ "${UI_INTERRUPTED:-0}" == "1" ]]; then
    UI_INTERRUPTED=0
    echo "0"
    return 0
  fi
  ans="$(ui_trim "$ans")"
  ans="$(printf "%s" "$ans" | tr '[:upper:]' '[:lower:]')"
  case "$ans" in
    q|quit|exit|back|назад) echo "0" ;;
    *) echo "$ans" ;;
  esac
}

ui_menu_back_item() {
  echo "0) Назад (или q)"
}
