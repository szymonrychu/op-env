#!/usr/bin/env bash
# Install or upgrade op-env into the current user's shell(s).
#
# Local install:   ./install.sh
# Remote install:  curl -fsSL https://raw.githubusercontent.com/szymonrychu/op-env/main/install.sh | bash
set -euo pipefail

DEST="${HOME}/.op-env-export.sh"
REPO_RAW="https://raw.githubusercontent.com/szymonrychu/op-env/main"
SOURCE_LINE='source "${HOME}/.op-env-export.sh"'

# Detect local checkout vs piped installation.
# BASH_SOURCE[0] is empty when the script is read from a pipe (curl | bash).
_self="${BASH_SOURCE[0]:-}"
_local_src=""
if [[ -n "${_self}" ]]; then
    _dir="$(cd -P -- "$(dirname -- "${_self}")" 2>/dev/null && pwd -P)" || true
    [[ -f "${_dir}/op-env-export.sh" ]] && _local_src="${_dir}/op-env-export.sh"
fi

[[ -f "${DEST}" ]] && _action="Upgrading" || _action="Installing"
echo "${_action} op-env..."

if [[ -n "${_local_src}" ]]; then
    cp "${_local_src}" "${DEST}"
    echo "  installed from local checkout → ${DEST}"
else
    curl -fsSL "${REPO_RAW}/op-env-export.sh" -o "${DEST}"
    echo "  downloaded → ${DEST}"
fi

_add_source_line() {
    local rc_file="${1}"
    [[ -f "${rc_file}" ]] || return 0
    if grep -qF 'op-env-export.sh' "${rc_file}"; then
        echo "  ${rc_file}: already configured"
    else
        printf '\n# op-env — 1Password environment variable manager\n%s\n' \
            "${SOURCE_LINE}" >> "${rc_file}"
        echo "  ${rc_file}: added source line"
    fi
}

_add_source_line "${HOME}/.zshrc"
_add_source_line "${HOME}/.bashrc"

echo ""
echo "${_action} complete. Restart your shell or run:"
echo "  source ${DEST}"
