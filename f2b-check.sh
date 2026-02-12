#!/usr/bin/env bash

# ===== Colors =====
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

line() {
  echo -e "${BLUE}============================================================${RESET}"
}

section() {
  line
  echo -e "${CYAN}$1${RESET}"
  line
}

ok() {
  echo -e "${GREEN}✔ $1${RESET}"
}

warn() {
  echo -e "${YELLOW}⚠ $1${RESET}"
}

fail() {
  echo -e "${RED}✘ $1${RESET}"
}

# ===== Header =====
clear
section "FAIL2BAN UNIVERSAL CHECKER"

echo -e "Server: $(hostname)"
echo -e "IP: $(curl -s ifconfig.me 2>/dev/null || echo 'N/A')"
echo -e "Date: $(date)"
echo

# ===== Service status =====
section "Fail2ban Service Status"

if systemctl list-unit-files | grep -q fail2ban; then
    STATUS=$(systemctl is-active fail2ban 2>/dev/null)
    if [[ "$STATUS" == "active" ]]; then
        ok "Fail2ban service is ACTIVE"
    else
        fail "Fail2ban service is NOT active (status: $STATUS)"
    fi
else
    warn "Fail2ban not installed"
fi

# ===== Client ping =====
section "Fail2ban Client Ping"

if sudo fail2ban-client ping &>/dev/null; then
    ok "Client ping successful"
elif sudo fail2ban-client -s /run/fail2ban/fail2ban.sock ping &>/dev/null; then
    ok "Client ping successful (custom socket)"
else
    fail "Fail2ban client not responding"
fi

# ===== SSH jail =====
section "SSHD Jail Status"

if sudo fail2ban-client status sshd &>/dev/null; then
    sudo fail2ban-client status sshd
elif sudo fail2ban-client -s /run/fail2ban/fail2ban.sock status sshd &>/dev/null; then
    sudo fail2ban-client -s /run/fail2ban/fail2ban.sock status sshd
else
    warn "SSHD jail not found or not running"
fi

# ===== Banned IP list =====
section "Banned IP List"

BANS=$(sudo fail2ban-client get sshd banip 2>/dev/null)

if [[ -n "$BANS" ]]; then
    echo "$BANS" | tr ' ' '\n' | sed '/^$/d'
else
    warn "No banned IPs or jail inactive"
fi

# ===== Firewall rules =====
section "Firewall Rules (f2b-sshd)"

if sudo iptables -L f2b-sshd -n --line-numbers &>/dev/null; then
    sudo iptables -L f2b-sshd -n --line-numbers
else
    warn "No iptables chain f2b-sshd"
fi

echo
section "NFT Rules (if used)"

if command -v nft &>/dev/null; then
    sudo nft list ruleset 2>/dev/null | grep -i f2b || warn "No nft fail2ban rules"
else
    warn "nft not installed"
fi

echo
line
echo -e "${CYAN}Check complete.${RESET}"
line
