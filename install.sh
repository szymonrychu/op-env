#!/usr/bin/env bash
# Install op-env-export.sh into the current user's shell(s).
#
# Usage: ./install.sh
#
# What it does:
#   1. Copies op-env-export.sh to ~/.op-env-export.sh
#   2. Adds `source ~/.op-env-export.sh` to ~/.zshrc and ~/.bashrc (if present)
set -euo pipefail

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="${SCRIPT_DIR}/op-env-export.sh"
DEST="${HOME}/.op-env-export.sh"
SOURCE_LINE='source "${HOME}/.op-env-export.sh"'

_add_source_line() {
    local rc_file="${1}"
    [[ -f "${rc_file}" ]] || return 0
    if grep -qF 'op-env-export.sh' "${rc_file}"; then
        echo "  already sourced in ${rc_file} — skipping"
    else
        printf '\n# op-env — 1Password environment variable manager\n%s\n' "${SOURCE_LINE}" >> "${rc_file}"
        echo "  added source line to ${rc_file}"
    fi
}

echo "Installing op-env-export.sh..."

cp "${SRC}" "${DEST}"
echo "  copied to ${DEST}"

_add_source_line "${HOME}/.zshrc"
_add_source_line "${HOME}/.bashrc"

echo ""
echo "Done. Restart your shell or run:"
echo "  source ${DEST}"
