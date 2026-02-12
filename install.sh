#!/usr/bin/env bash
set -euo pipefail

REPO_DEFAULT="https://github.com/vitalyor/sys-tools.git"
INSTALL_DIR="/opt/sys-tools"
BIN_LINK="/usr/local/bin/sys-tools"

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  sudo apt-get update -y
  sudo apt-get install -y "$@"
}

main() {
  if ! cmd_exists apt-get; then
    echo "apt-get not found. This installer is for Ubuntu/Debian." >&2
    exit 1
  fi

  if ! cmd_exists git; then
    echo "[*] Installing git + curl..."
    apt_install git curl
  fi

  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "[*] Updating existing install in ${INSTALL_DIR}"
    ( cd "$INSTALL_DIR" && git pull --rebase )
  else
    echo "[*] Fresh install into ${INSTALL_DIR}"
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown -R "$USER":"$USER" "$INSTALL_DIR" 2>/dev/null || true
    git clone "$REPO_DEFAULT" "$INSTALL_DIR"
  fi

  # Не считаем chmod (filemode) изменением — иначе обновления будут постоянно ругаться на 644/755
  ( cd "$INSTALL_DIR" && git config core.filemode false )

  sudo chmod +x "${INSTALL_DIR}/toolbox.sh"
  sudo ln -sf "${INSTALL_DIR}/toolbox.sh" "${BIN_LINK}"

  echo "[+] Installed."
  echo "Run: sys-tools"
}

main "$@"
