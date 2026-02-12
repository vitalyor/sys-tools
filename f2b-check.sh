#!/usr/bin/env bash
set -euo pipefail

# ===== Colors =====
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

line() { echo -e "${BLUE}============================================================${RESET}"; }
section() { line; echo -e "${CYAN}$1${RESET}"; line; }
ok() { echo -e "${GREEN}✔ $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $1${RESET}"; }
fail() { echo -e "${RED}✘ $1${RESET}"; }

need_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo -n true 2>/dev/null || { fail "Need sudo (passwordless or interactive)."; exit 1; }
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

f2b_ping() {
  sudo fail2ban-client ping >/dev/null 2>&1 && return 0
  sudo fail2ban-client -s /run/fail2ban/fail2ban.sock ping >/dev/null 2>&1 && return 0
  return 1
}

f2b_status_sshd_ok() {
  sudo fail2ban-client status sshd >/dev/null 2>&1 && return 0
  sudo fail2ban-client -s /run/fail2ban/fail2ban.sock status sshd >/dev/null 2>&1 && return 0
  return 1
}

write_default_sshd_jail_if_missing() {
  local f="/etc/fail2ban/jail.d/sshd.local"
  sudo mkdir -p /etc/fail2ban/jail.d

  if [[ -s "$f" ]]; then
    ok "Config exists: $f (won't overwrite)"
    return 0
  fi

  warn "Config missing/empty, creating default: $f"
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
}

install_fail2ban_if_missing() {
  if cmd_exists fail2ban-client; then
    ok "fail2ban-client present"
    return 0
  fi

  warn "Fail2ban not installed -> installing"
  sudo apt-get update -y
  sudo apt-get install -y fail2ban
}

ensure_service_running() {
  sudo systemctl enable fail2ban >/dev/null 2>&1 || true
  sudo systemctl restart fail2ban || true
}

print_report() {
  clear || true
  section "FAIL2BAN SSHD CHECKER"

  echo "Host: $(hostname)"
  echo "Date: $(date)"
  echo "Public IP: $(curl -fsS ifconfig.me 2>/dev/null || echo "N/A")"
  echo

  section "Service status"
  if systemctl list-unit-files | grep -q '^fail2ban\.service'; then
    local st
    st="$(systemctl is-active fail2ban 2>/dev/null || true)"
    if [[ "$st" == "active" ]]; then ok "fail2ban is active"; else fail "fail2ban not active ($st)"; fi
  else
    warn "fail2ban service unit not found"
  fi

  section "Client ping"
  if f2b_ping; then ok "fail2ban-client ping OK"; else fail "fail2ban-client ping FAILED"; fi

  section "Jail: sshd"
  if f2b_status_sshd_ok; then
    sudo fail2ban-client status sshd 2>/dev/null || sudo fail2ban-client -s /run/fail2ban/fail2ban.sock status sshd || true
  else
    warn "sshd jail not available"
  fi

  section "Banned IPs (sshd)"
  local bans=""
  bans="$(sudo fail2ban-client get sshd banip 2>/dev/null || sudo fail2ban-client -s /run/fail2ban/fail2ban.sock get sshd banip 2>/dev/null || true)"
  if [[ -n "${bans// /}" ]]; then
    echo "$bans" | tr ' ' '\n' | sed '/^$/d'
  else
    warn "No banned IPs (or jail inactive)"
  fi

  section "Firewall hooks (iptables/nft)"
  if sudo iptables -S 2>/dev/null | grep -Eq "f2b|fail2ban"; then
    ok "iptables has fail2ban-related rules"
    sudo iptables -S | grep -E "f2b|fail2ban" || true
  else
    warn "iptables: no fail2ban rules found"
  fi

  if cmd_exists nft; then
    if sudo nft list ruleset 2>/dev/null | grep -Eq "f2b|fail2ban"; then
      ok "nft has fail2ban-related rules"
      sudo nft list ruleset 2>/dev/null | grep -E "f2b|fail2ban" || true
    else
      warn "nft: no fail2ban rules found"
    fi
  else
    warn "nft not installed"
  fi

  section "Recent SSH failures (last ~200 lines)"
  sudo journalctl -u ssh --no-pager -n 200 2>/dev/null | grep -E "Failed password|Invalid user" | tail -n 50 || warn "No recent matches (or ssh unit name differs)"

  section "Top attackers (last ~2000 lines)"
  sudo journalctl -u ssh --no-pager -n 2000 2>/dev/null \
    | grep -E "Failed password|Invalid user" \
    | awk '{print $NF}' \
    | sort | uniq -c | sort -nr | head -n 10 || warn "No matches (or ssh unit name differs)"

  line
  echo -e "${CYAN}Done.${RESET}"
  line
}

main() {
  need_sudo

  # Detect: already configured?
  local installed=0
  local running=0
  local sshd_jail=0

  cmd_exists fail2ban-client && installed=1 || true
  systemctl is-active --quiet fail2ban && running=1 || true
  f2b_status_sshd_ok && sshd_jail=1 || true

  section "Pre-check"
  [[ $installed -eq 1 ]] && ok "Installed" || warn "Not installed"
  [[ $running -eq 1 ]] && ok "Service running" || warn "Service not running"
  [[ $sshd_jail -eq 1 ]] && ok "SSHD jail OK" || warn "SSHD jail not OK"

  # If something missing -> install/configure minimal safe defaults
  if [[ $installed -eq 0 || $running -eq 0 || $sshd_jail -eq 0 ]]; then
    section "Install / Configure"
    install_fail2ban_if_missing
    write_default_sshd_jail_if_missing
    ensure_service_running
  else
    section "No changes"
    ok "Fail2ban + sshd jail already present. Only printing report."
  fi

  print_report
}

main "$@"
