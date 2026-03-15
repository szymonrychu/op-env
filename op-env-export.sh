#!/usr/bin/env bash
# 1password CLI wrapper — exports secrets to environment variables in current shell.
# Source this file, then use the functions below.
# Similar to https://gitlab.com/gitlab-com/gl-infra/pmv
#
# Common flags (consistent across all functions):
#   -n <title>     1password item title
#   -t <tag>       1password item tag (repeatable: -t tag1 -t tag2)
#   -v <vault>     vault name
#   -s KEY=VALUE   secret env var — stored as concealed (passwords, tokens, keys)
#   -p KEY=VALUE   plain env var  — stored as text (URLs, usernames, non-sensitive config)
#   -a item:FIELD        alias — resolves FIELD from item at export time (deduplicates values)
#   -a VARNAME=item:FIELD  alias with a different local var name
#   -e <VAR>       specific env var name (op_env only)
#
# Default tag for new items (set in your shell profile to avoid repeating -t):
#   export OP_ENV_DEFAULT_TAG="myteam"
OP_ENV_DEFAULT_TAG="${OP_ENV_DEFAULT_TAG:-}"

# Prefix used to mark alias fields stored in 1Password.
# Value format: @alias:item_title:FIELD_NAME
_OP_ALIAS_PREFIX="@alias:"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Ensure an active 1Password session; auto-signin if needed.
_op_ensure_auth() {
    op whoami >/dev/null 2>&1 && return 0
    echo "Not signed in to 1Password — signing in..." >&2
    eval "$(op signin)" || { echo "1Password sign-in failed" >&2; return 1; }
}

# Join arguments with commas (for --tags).
_op_tags_csv() {
    local csv="" t
    for t in "$@"; do csv="${csv:+${csv},}${t}"; done
    printf '%s' "${csv}"
}

# Find the first item ID matching title and optional comma-joined tags/vault (stdout).
_op_find_item_id() {
    local title="${1}" tags="${2:-}" vault="${3:-}"
    local -a args=("item" "list" "--format=json")
    [[ -n "${tags}" ]] && args+=("--tags" "${tags}")
    [[ -n "${vault}" ]] && args+=("--vault" "${vault}")
    op "${args[@]}" 2>/dev/null \
        | jq -r --arg t "${title}" '.[] | select(.title == $t) | .id' \
        | head -1
}

# Export all env:* fields from item JSON, resolving @alias: references.
# Usage: _op_export_fields <item_json>
_op_export_fields() {
    local item_data="${1}"
    local alias_line var_name alias_body alias_item alias_field
    local ref_id ref_data ref_value

    # Export regular (non-alias) env:* fields.
    # Labels are validated as identifiers before eval to prevent injection.
    eval "$(printf '%s' "${item_data}" | jq -r \
        --arg pfx "${_OP_ALIAS_PREFIX}" '
        .fields[]? |
        select(.label | startswith("env:")) |
        select(.label[4:] | test("^[A-Za-z_][A-Za-z0-9_]*$")) |
        select(.value // "" | startswith($pfx) | not) |
        "export " + (.label[4:]) + "=" + (.value // "" | @sh)
    ')"

    # Resolve alias fields: each line is "VARNAME @alias:item:field"
    while IFS= read -r alias_line; do
        [[ -z "${alias_line}" ]] && continue
        var_name="${alias_line%% *}"
        alias_body="${alias_line#*"${_OP_ALIAS_PREFIX}"}"
        alias_item="${alias_body%%:*}"
        alias_field="${alias_body#*:}"

        if [[ ! "${var_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "op_env: alias has invalid var name '${var_name}'" >&2
            return 1
        fi

        ref_id=$(_op_find_item_id "${alias_item}" "" "")
        if [[ -z "${ref_id}" ]]; then
            echo "op_env: alias '${var_name}': item '${alias_item}' not found" >&2
            return 1
        fi

        ref_data=$(op item get "${ref_id}" --format=json 2>/dev/null) || return 1
        ref_value=$(printf '%s' "${ref_data}" | jq -r \
            --arg f "env:${alias_field}" \
            '.fields[]? | select(.label == $f) | .value // ""')

        if [[ -z "${ref_value}" ]]; then
            echo "op_env: alias '${var_name}': field 'env:${alias_field}' not found in '${alias_item}'" >&2
            return 1
        fi

        export "${var_name}=${ref_value}"
    done <<< "$(printf '%s' "${item_data}" | jq -r \
        --arg pfx "${_OP_ALIAS_PREFIX}" '
        .fields[]? |
        select(.label | startswith("env:")) |
        select(.label[4:] | test("^[A-Za-z_][A-Za-z0-9_]*$")) |
        select(.value // "" | startswith($pfx)) |
        (.label[4:]) + " " + (.value // "")
    ')"
}

# ---------------------------------------------------------------------------
# op_env — fetch and export env:* variables from a specific item
#
# Usage: op_env -n <title> [-t <tag> ...] [-v <vault>] [-e <VAR>]
#   -n  item title (required)
#   -t  tag (repeatable; narrows search when title is not unique)
#   -v  vault
#   -e  export only this variable; omit to export all env:* fields
# ---------------------------------------------------------------------------
op_env() {
    local OPTIND=1 title="" vault="" env_var=""
    local -a tags=()
    while getopts ":hn:t:v:e:" opt; do
        case "${opt}" in
            h) cat <<'EOF'
op_env — export env:* variables from a specific 1Password item

Usage: op_env -n <title> [-t <tag> ...] [-v <vault>] [-e <VAR>]

  -n  item title (required)
  -t  tag (repeatable; narrows search when title is not unique)
  -v  vault name
  -e  export only this variable; omit to export all env:* fields
      (aliases are always resolved, even with -e)

Examples:
  op_env -n gitlab                                   # export all env:* fields
  op_env -n gitlab -e GITLAB_TOKEN                   # export single variable
  op_env -n gitlab -t work -t personal -e GITLAB_PAT # narrow by tags, single var
EOF
               return 0 ;;
            n) title="${OPTARG}" ;;
            t) tags+=("${OPTARG}") ;;
            v) vault="${OPTARG}" ;;
            e) env_var="${OPTARG}" ;;
            :) echo "op_env: -${OPTARG} requires an argument" >&2; return 1 ;;
            ?) echo "op_env: unknown option -${OPTARG}" >&2; return 1 ;;
        esac
    done
    [[ -z "${title}" ]] && { echo "op_env: -n <title> is required" >&2; return 1; }
    _op_ensure_auth || return 1
    local tags_csv id
    tags_csv=$(_op_tags_csv "${tags[@]}")
    id=$(_op_find_item_id "${title}" "${tags_csv}" "${vault}")
    [[ -z "${id}" ]] && { echo "op_env: item '${title}' not found${tags_csv:+ (tags: ${tags_csv})}" >&2; return 1; }
    local item_data
    item_data=$(op item get "${id}" --format=json 2>/dev/null) || return 1
    if [[ -n "${env_var}" ]]; then
        # Single-variable mode: check for alias, otherwise export directly
        local raw_value field_label
        field_label="env:${env_var}"
        raw_value=$(printf '%s' "${item_data}" | jq -r \
            --arg l "${field_label}" '.fields[]? | select(.label == $l) | .value // ""')
        if [[ "${raw_value}" == "${_OP_ALIAS_PREFIX}"* ]]; then
            local alias_body alias_item alias_field ref_id ref_data
            alias_body="${raw_value#"${_OP_ALIAS_PREFIX}"}"
            alias_item="${alias_body%%:*}"
            alias_field="${alias_body#*:}"
            ref_id=$(_op_find_item_id "${alias_item}" "" "")
            [[ -z "${ref_id}" ]] && { echo "op_env: alias '${env_var}': item '${alias_item}' not found" >&2; return 1; }
            ref_data=$(op item get "${ref_id}" --format=json 2>/dev/null) || return 1
            raw_value=$(printf '%s' "${ref_data}" | jq -r \
                --arg f "env:${alias_field}" '.fields[]? | select(.label == $f) | .value // ""')
            [[ -z "${raw_value}" ]] && { echo "op_env: alias '${env_var}': field 'env:${alias_field}' not found in '${alias_item}'" >&2; return 1; }
        fi
        export "${env_var}=${raw_value}"
    else
        _op_export_fields "${item_data}"
    fi
}

# ---------------------------------------------------------------------------
# op_envs — fetch and export env:* variables from ALL items with given tag(s)
#
# Usage: op_envs -t <tag> [-t <tag2> ...] [-v <vault>]
#   -t  tag (required, repeatable; items must have ALL specified tags)
#   -v  vault
#
# .envrc example:  op_envs -t myproject -t prod
# ---------------------------------------------------------------------------
op_envs() {
    local OPTIND=1 vault=""
    local -a tags=()
    while getopts ":ht:v:" opt; do
        case "${opt}" in
            h) cat <<'EOF'
op_envs — export all env:* variables from every item with the given tag(s)

Usage: op_envs -t <tag> [-t <tag2> ...] [-v <vault>]

  -t  tag (required, repeatable; items must have ALL specified tags)
  -v  vault name

Examples:
  op_envs -t gitlab                        # all items tagged 'gitlab'
  op_envs -t myproject -t prod             # items tagged both 'myproject' AND 'prod'
  op_envs -t myproject -t prod -v Personal # same, scoped to vault
EOF
               return 0 ;;
            t) tags+=("${OPTARG}") ;;
            v) vault="${OPTARG}" ;;
            :) echo "op_envs: -${OPTARG} requires an argument" >&2; return 1 ;;
            ?) echo "op_envs: unknown option -${OPTARG}" >&2; return 1 ;;
        esac
    done
    [[ ${#tags[@]} -eq 0 ]] && { echo "op_envs: at least one -t <tag> is required" >&2; return 1; }
    _op_ensure_auth || return 1
    local tags_csv
    tags_csv=$(_op_tags_csv "${tags[@]}")
    local -a list_args=("item" "list" "--tags" "${tags_csv}" "--format=json")
    [[ -n "${vault}" ]] && list_args+=("--vault" "${vault}")
    local items
    items=$(op "${list_args[@]}" 2>/dev/null) || return 1
    if [[ "${items}" == "[]" || -z "${items}" ]]; then
        echo "op_envs: no items found with tags '${tags_csv}'" >&2
        return 0
    fi
    local id item_data hook_file
    while IFS= read -r id; do
        item_data=$(op item get "${id}" --format=json 2>/dev/null) || continue
        _op_export_fields "${item_data}" || return 1
    done <<< "$(printf '%s' "${items}" | jq -r '.[].id')"
    hook_file=$(_op_find_hook_file)
    if [[ -n "${hook_file}" ]]; then
        # shellcheck source=/dev/null
        source "${hook_file}"
    fi
}

# ---------------------------------------------------------------------------
# op_env_unset — unset all env:* variables exported by items with given tag(s)
#
# Usage: op_env_unset -t <tag> [-t <tag2> ...] [-v <vault>]
#   -t  tag (required, repeatable; mirrors op_envs tag semantics)
#   -v  vault
# ---------------------------------------------------------------------------
op_env_unset() {
    local OPTIND=1 vault=""
    local -a tags=()
    while getopts ":ht:v:" opt; do
        case "${opt}" in
            h) cat <<'EOF'
op_env_unset — unset all env:* variables belonging to items with the given tag(s)

Usage: op_env_unset -t <tag> [-t <tag2> ...] [-v <vault>]

  -t  tag (required, repeatable; mirrors op_envs tag semantics)
  -v  vault name

Examples:
  op_env_unset -t gitlab                  # unset all vars from items tagged 'gitlab'
  op_env_unset -t myproject -t prod       # unset vars from items tagged both tags
EOF
               return 0 ;;
            t) tags+=("${OPTARG}") ;;
            v) vault="${OPTARG}" ;;
            :) echo "op_env_unset: -${OPTARG} requires an argument" >&2; return 1 ;;
            ?) echo "op_env_unset: unknown option -${OPTARG}" >&2; return 1 ;;
        esac
    done
    [[ ${#tags[@]} -eq 0 ]] && { echo "op_env_unset: at least one -t <tag> is required" >&2; return 1; }
    _op_ensure_auth || return 1
    local tags_csv
    tags_csv=$(_op_tags_csv "${tags[@]}")
    local -a list_args=("item" "list" "--tags" "${tags_csv}" "--format=json")
    [[ -n "${vault}" ]] && list_args+=("--vault" "${vault}")
    local items
    items=$(op "${list_args[@]}" 2>/dev/null) || return 1
    if [[ "${items}" == "[]" || -z "${items}" ]]; then
        echo "op_env_unset: no items found with tags '${tags_csv}'" >&2
        return 0
    fi
    local id var_name item_data
    local -a unset_vars=()
    while IFS= read -r id; do
        item_data=$(op item get "${id}" --format=json 2>/dev/null) || continue
        while IFS= read -r var_name; do
            [[ -z "${var_name}" ]] && continue
            unset "${var_name}"
            unset_vars+=("${var_name}")
        done <<< "$(printf '%s' "${item_data}" | jq -r '
            .fields[]? |
            select(.label | startswith("env:")) |
            select(.label[4:] | test("^[A-Za-z_][A-Za-z0-9_]*$")) |
            .label[4:]
        ')"
    done <<< "$(printf '%s' "${items}" | jq -r '.[].id')"
    [[ ${#unset_vars[@]} -gt 0 ]] && echo "Unset: ${unset_vars[*]}"
}

# ---------------------------------------------------------------------------
# op_env_list — list env:* variable names from items with given tag(s)
#               Never prints secret values.
#
# Usage: op_env_list -t <tag> [-t <tag2> ...] [-i] [-v <vault>]
#   -t  tag (required, repeatable; items must have ALL specified tags)
#   -i  prefix each variable with its item title (e.g. gitlab:GITLAB_USERNAME)
#   -v  vault
# ---------------------------------------------------------------------------
op_env_list() {
    local OPTIND=1 vault="" show_item=0
    local -a tags=()
    while getopts ":hit:v:" opt; do
        case "${opt}" in
            h) cat <<'EOF'
op_env_list — list env:* variable names from items with given tag(s)
              Never prints secret values.

Usage: op_env_list -t <tag> [-t <tag2> ...] [-i] [-v <vault>]

  -t  tag (required, repeatable; items must have ALL specified tags)
  -i  prefix each variable with its 1Password item title
  -v  vault name

Examples:
  op_env_list -t myproject              # GITLAB_USERNAME
  op_env_list -t myproject -i           # gitlab:GITLAB_USERNAME
  op_env_list -t myproject -t prod -i   # items with both tags, with item prefix
EOF
               return 0 ;;
            i) show_item=1 ;;
            t) tags+=("${OPTARG}") ;;
            v) vault="${OPTARG}" ;;
            :) echo "op_env_list: -${OPTARG} requires an argument" >&2; return 1 ;;
            ?) echo "op_env_list: unknown option -${OPTARG}" >&2; return 1 ;;
        esac
    done
    [[ ${#tags[@]} -eq 0 ]] && { echo "op_env_list: at least one -t <tag> is required" >&2; return 1; }
    _op_ensure_auth || return 1
    local tags_csv
    tags_csv=$(_op_tags_csv "${tags[@]}")
    local -a list_args=("item" "list" "--tags" "${tags_csv}" "--format=json")
    [[ -n "${vault}" ]] && list_args+=("--vault" "${vault}")
    local items
    items=$(op "${list_args[@]}" 2>/dev/null) || return 1
    if [[ "${items}" == "[]" || -z "${items}" ]]; then
        echo "op_env_list: no items found with tags '${tags_csv}'" >&2
        return 0
    fi
    local entry id item_title item_data var_name
    while IFS= read -r entry; do
        id=$(printf '%s' "${entry}" | jq -r '.id')
        item_title=$(printf '%s' "${entry}" | jq -r '.title')
        item_data=$(op item get "${id}" --format=json 2>/dev/null) || continue
        while IFS= read -r var_name; do
            [[ -z "${var_name}" ]] && continue
            if [[ "${show_item}" -eq 1 ]]; then
                printf '%s:%s\n' "${item_title}" "${var_name}"
            else
                printf '%s\n' "${var_name}"
            fi
        done <<< "$(printf '%s' "${item_data}" | jq -r '
            .fields[]? |
            select(.label | startswith("env:")) |
            select(.label[4:] | test("^[A-Za-z_][A-Za-z0-9_]*$")) |
            .label[4:]
        ')"
    done <<< "$(printf '%s' "${items}" | jq -c '.[]')"
}

# ---------------------------------------------------------------------------
# _op_find_hook_file — walk CWD upward looking for a .op-env file.
# Prints the first path found (or nothing if none exists).
# ---------------------------------------------------------------------------
_op_find_hook_file() {
    local dir="${PWD}"
    while [[ -n "${dir}" ]]; do
        [[ -f "${dir}/.op-env" ]] && { printf '%s/.op-env\n' "${dir}"; return 0; }
        [[ "${dir}" == "/" ]] && break
        dir="${dir%/*}"
        [[ -z "${dir}" ]] && dir="/"
    done
    return 0
}

# ---------------------------------------------------------------------------
# _op_parse_alias_arg — parse -a argument into "VARNAME=item:FIELD"
# Formats accepted:
#   item:FIELD          → VARNAME inferred from FIELD
#   VARNAME=item:FIELD  → explicit VARNAME
# Output: prints "VARNAME=item:FIELD" or returns 1 on error.
# ---------------------------------------------------------------------------
_op_parse_alias_arg() {
    local arg="${1}" caller="${2:-op_env_add}"
    local a_var a_ref
    if [[ "${arg}" == *=*:* ]]; then
        a_var="${arg%%=*}"
        a_ref="${arg#*=}"
    elif [[ "${arg}" == *:* ]]; then
        a_ref="${arg}"
        a_var="${arg##*:}"
    else
        echo "${caller}: -a requires item:FIELD or VARNAME=item:FIELD" >&2
        return 1
    fi
    if [[ ! "${a_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "${caller}: alias var name '${a_var}' is not a valid identifier" >&2
        return 1
    fi
    printf '%s=%s' "${a_var}" "${a_ref}"
}

# ---------------------------------------------------------------------------
# op_env_add — create a new item (fails if item already exists)
#
# Usage: op_env_add -n <title> [-s KEY=VALUE] [-p KEY=VALUE] [-a item:FIELD] ...
#                              [-t <tag> ...] [-v <vault>]
#   -n  item title (required)
#   -s  KEY=VALUE secret — stored concealed (passwords, tokens, keys); repeatable
#   -p  KEY=VALUE plain  — stored as text (URLs, usernames, config); repeatable
#   -a  item:FIELD or VARNAME=item:FIELD — alias to a field in another item; repeatable
#   -t  tag (repeatable; falls back to OP_ENV_DEFAULT_TAG if none given)
#   -v  vault
# ---------------------------------------------------------------------------
op_env_add() {
    local OPTIND=1 title="" vault=""
    local -a tags=() secrets=() plains=() aliases=()
    while getopts ":hn:t:v:s:p:a:" opt; do
        case "${opt}" in
            h) cat <<'EOF'
op_env_add — create a new 1Password item (fails if item already exists; use op_env_update to modify)

Usage: op_env_add -n <title> [-s KEY=VALUE] [-p KEY=VALUE] [-a item:FIELD] ...
                             [-t <tag> ...] [-v <vault>]

  -n  item title (required)
  -s  KEY=VALUE secret — stored concealed (passwords, tokens, API keys); repeatable
  -p  KEY=VALUE plain  — stored as text (URLs, usernames, non-sensitive config); repeatable
  -a  item:FIELD         — alias: resolves FIELD from item at export time; repeatable
      VARNAME=item:FIELD — alias with a different local var name
  -t  tag (repeatable; uses OP_ENV_DEFAULT_TAG if none given)
  -v  vault name

Examples:
  # Store credentials together with an alias to a shared username
  op_env_add -n myapp/prod -t myapp -t prod \
    -s DB_PASS=secret -p DB_HOST=db.example.com \
    -a gitlab:GITLAB_USERNAME

  # Rename the aliased var
  op_env_add -n myapp/prod -a APP_USER=gitlab:GITLAB_USERNAME
EOF
               return 0 ;;
            n) title="${OPTARG}" ;;
            t) tags+=("${OPTARG}") ;;
            v) vault="${OPTARG}" ;;
            s) secrets+=("${OPTARG}") ;;
            p) plains+=("${OPTARG}") ;;
            a)
                local parsed
                parsed=$(_op_parse_alias_arg "${OPTARG}" "op_env_add") || return 1
                aliases+=("${parsed}") ;;
            :) echo "op_env_add: -${OPTARG} requires an argument" >&2; return 1 ;;
            ?) echo "op_env_add: unknown option -${OPTARG}" >&2; return 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    # Accept trailing positional KEY=VALUE args as secrets
    for s in "$@"; do [[ "${s}" == *=* ]] && secrets+=("${s}"); done
    [[ -z "${title}" ]] && { echo "op_env_add: -n <title> is required" >&2; return 1; }
    [[ ${#secrets[@]} -eq 0 && ${#plains[@]} -eq 0 && ${#aliases[@]} -eq 0 ]] && {
        echo "op_env_add: at least one -s, -p, or -a is required" >&2; return 1
    }
    [[ ${#tags[@]} -eq 0 && -n "${OP_ENV_DEFAULT_TAG}" ]] && tags=("${OP_ENV_DEFAULT_TAG}")
    _op_ensure_auth || return 1
    local tags_csv
    tags_csv=$(_op_tags_csv "${tags[@]}")
    local -a field_args=()
    local s
    for s in "${secrets[@]}"; do field_args+=("env:${s%%=*}[concealed]=${s#*=}"); done
    for s in "${plains[@]}";  do field_args+=("env:${s%%=*}[text]=${s#*=}"); done
    for s in "${aliases[@]}"; do
        # s is "VARNAME=item:FIELD"; store as env:VARNAME[text]=@alias:item:FIELD
        field_args+=("env:${s%%=*}[text]=${_OP_ALIAS_PREFIX}${s#*=}")
    done
    local existing_id
    existing_id=$(_op_find_item_id "${title}" "${tags_csv}" "${vault}")
    if [[ -n "${existing_id}" ]]; then
        echo "op_env_add: item '${title}' already exists — use op_env_update to modify it" >&2
        return 1
    fi
    local -a create_args=("item" "create" "--category=Login" "--title=${title}")
    [[ -n "${tags_csv}" ]] && create_args+=("--tags=${tags_csv}")
    [[ -n "${vault}" ]] && create_args+=("--vault" "${vault}")
    create_args+=("${field_args[@]}")
    op "${create_args[@]}" >/dev/null
    local total=$(( ${#secrets[@]} + ${#plains[@]} + ${#aliases[@]} ))
    echo "Created '${title}' with ${total} field(s)${tags_csv:+ (tags: ${tags_csv})}"
}

# ---------------------------------------------------------------------------
# op_env_update — update specific env:* fields in an existing item
#                 Fails (does not create) if the item is not found.
#
# Usage: op_env_update -n <title> [-s KEY=VALUE] [-p KEY=VALUE] [-a item:FIELD] ...
#                                 [-t <tag> ...] [-v <vault>]
# ---------------------------------------------------------------------------
op_env_update() {
    local OPTIND=1 title="" vault=""
    local -a tags=() secrets=() plains=() aliases=()
    while getopts ":hn:t:v:s:p:a:" opt; do
        case "${opt}" in
            h) cat <<'EOF'
op_env_update — update env:* fields in an existing item (fails if item not found)

Usage: op_env_update -n <title> [-s KEY=VALUE] [-p KEY=VALUE] [-a item:FIELD] ...
                                [-t <tag> ...] [-v <vault>]

  -n  item title (required)
  -s  KEY=VALUE secret — update as concealed (passwords, tokens, API keys); repeatable
  -p  KEY=VALUE plain  — update as text (URLs, usernames, config); repeatable
  -a  item:FIELD         — add/update alias to a field in another item; repeatable
      VARNAME=item:FIELD — alias with a different local var name
  -t  tag (repeatable; narrows search when title is not unique)
  -v  vault name

Examples:
  op_env_update -n gitlab -s GITLAB_TOKEN=glpat-new
  op_env_update -n myapp/prod -t myapp -t prod -s API_KEY=sk-new -a gitlab:GITLAB_USERNAME
EOF
               return 0 ;;
            n) title="${OPTARG}" ;;
            t) tags+=("${OPTARG}") ;;
            v) vault="${OPTARG}" ;;
            s) secrets+=("${OPTARG}") ;;
            p) plains+=("${OPTARG}") ;;
            a)
                local parsed
                parsed=$(_op_parse_alias_arg "${OPTARG}" "op_env_update") || return 1
                aliases+=("${parsed}") ;;
            :) echo "op_env_update: -${OPTARG} requires an argument" >&2; return 1 ;;
            ?) echo "op_env_update: unknown option -${OPTARG}" >&2; return 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    for s in "$@"; do [[ "${s}" == *=* ]] && secrets+=("${s}"); done
    [[ -z "${title}" ]] && { echo "op_env_update: -n <title> is required" >&2; return 1; }
    [[ ${#secrets[@]} -eq 0 && ${#plains[@]} -eq 0 && ${#aliases[@]} -eq 0 ]] && {
        echo "op_env_update: at least one -s, -p, or -a is required" >&2; return 1
    }
    _op_ensure_auth || return 1
    local tags_csv id
    tags_csv=$(_op_tags_csv "${tags[@]}")
    id=$(_op_find_item_id "${title}" "${tags_csv}" "${vault}")
    [[ -z "${id}" ]] && { echo "op_env_update: item '${title}' not found${tags_csv:+ (tags: ${tags_csv})}" >&2; return 1; }
    local -a field_args=()
    local s
    for s in "${secrets[@]}"; do field_args+=("env:${s%%=*}[concealed]=${s#*=}"); done
    for s in "${plains[@]}";  do field_args+=("env:${s%%=*}[text]=${s#*=}"); done
    for s in "${aliases[@]}"; do
        field_args+=("env:${s%%=*}[text]=${_OP_ALIAS_PREFIX}${s#*=}")
    done
    op item edit "${id}" "${field_args[@]}" >/dev/null
    echo "Updated '${title}': $(( ${#secrets[@]} + ${#plains[@]} + ${#aliases[@]} )) field(s)"
}

# ---------------------------------------------------------------------------
# op_env_delete — delete a 1password item by title
#
# Usage: op_env_delete -n <title> [-t <tag> ...] [-v <vault>]
# ---------------------------------------------------------------------------
op_env_delete() {
    local OPTIND=1 title="" vault=""
    local -a tags=()
    while getopts ":hn:t:v:" opt; do
        case "${opt}" in
            h) cat <<'EOF'
op_env_delete — delete a 1Password item by title

Usage: op_env_delete -n <title> [-t <tag> ...] [-v <vault>]

  -n  item title (required)
  -t  tag (repeatable; narrows search when title is not unique)
  -v  vault name

Examples:
  op_env_delete -n gitlab
  op_env_delete -n myapp/prod -t myapp -t prod
EOF
               return 0 ;;
            n) title="${OPTARG}" ;;
            t) tags+=("${OPTARG}") ;;
            v) vault="${OPTARG}" ;;
            :) echo "op_env_delete: -${OPTARG} requires an argument" >&2; return 1 ;;
            ?) echo "op_env_delete: unknown option -${OPTARG}" >&2; return 1 ;;
        esac
    done
    [[ -z "${title}" ]] && { echo "op_env_delete: -n <title> is required" >&2; return 1; }
    _op_ensure_auth || return 1
    local tags_csv id
    tags_csv=$(_op_tags_csv "${tags[@]}")
    id=$(_op_find_item_id "${title}" "${tags_csv}" "${vault}")
    [[ -z "${id}" ]] && { echo "op_env_delete: item '${title}' not found${tags_csv:+ (tags: ${tags_csv})}" >&2; return 1; }
    op item delete "${id}"
    echo "Deleted '${title}'"
}
