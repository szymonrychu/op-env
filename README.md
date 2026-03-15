# op-env

A lightweight 1Password CLI wrapper that exports secrets as environment variables directly into your shell. No plaintext `.env` files, no manual copying — secrets live in 1Password and are injected on demand.

## How it works

`op-env-export.sh` is a shell script you source into your shell. It provides a set of functions (`op_env`, `op_envs`, `op_env_add`, …) that talk to the [1Password CLI (`op`)](https://developer.1password.com/docs/cli/) to fetch secrets and `export` them as environment variables.

Secrets are stored as **fields** inside 1Password items. The field label format is `env:VARIABLE_NAME` — for example, a field labelled `env:GITHUB_TOKEN` will be exported as `$GITHUB_TOKEN`.

Items are grouped via **1Password tags**. Running `op_envs -t myproject` exports every `env:*` field from every item tagged `myproject`. This makes it trivial to load all secrets for a project with a single command.

## Features

| Function | Purpose |
|---|---|
| `op_env -n <title>` | Export all env vars from a single item |
| `op_env -n <title> -e VAR` | Export a single variable from an item |
| `op_envs -t <tag>` | Export all env vars from every item with a tag |
| `op_env_list -t <tag>` | List variable names without revealing values |
| `op_env_unset -t <tag>` | Unset all variables exported by a tag |
| `op_env_add -n <title> …` | Create a new 1Password item |
| `op_env_update -n <title> …` | Update fields in an existing item |
| `op_env_delete -n <title>` | Delete an item |

### Aliases (cross-item references)

A field value can reference a field from another item using the `@alias:item:FIELD` syntax. At export time the value is resolved transparently. This lets you avoid duplicating shared values (e.g. a common username used across multiple services).

```bash
# Store GHCR_USERNAME as an alias pointing at github's GITHUB_USERNAME field
op_env_add -n ghcr -t myproject \
  -p GHCR_HOSTNAME=ghcr.io \
  -a GHCR_USERNAME=github:GITHUB_USERNAME
```

### `.op-env` hook

After successfully loading all secrets, `op_envs` walks up from the current working directory looking for a file named `.op-env`. If found, it sources it. This lets you define project-specific env var transformations without touching 1Password.

A typical use case is compatibility shims — for example, mapping secrets to the naming convention required by Terraform:

```bash
# .op-env
export TF_VAR_github_token="${GITHUB_TOKEN}"
export TF_VAR_db_password="${DB_PASSWORD}"
```

The hook file is never committed with secrets; it only references variables that are already exported.

## Requirements

- [1Password CLI (`op`)](https://developer.1password.com/docs/cli/) — installed and configured
- `jq`
- bash ≥ 4 or zsh

## Installation

```bash
git clone https://github.com/szymonrychu/op-env.git
cd op-env
./install.sh
```

`install.sh` copies `op-env-export.sh` to `~/.op-env-export.sh` and adds a `source` line to `~/.zshrc` and `~/.bashrc` (whichever exist).

After installation, restart your shell or run:

```bash
source ~/.op-env-export.sh
```

## Usage

### Store a secret

```bash
# Create an item with a secret token and a plain username
op_env_add -n github -t myproject \
  -s GITHUB_TOKEN=ghp_xxxxxxxxxxxx \
  -p GITHUB_USERNAME=myuser
```

### Load secrets

```bash
# Load all variables from every item tagged 'myproject'
op_envs -t myproject

# Load a single item
op_env -n github

# Load a single variable
op_env -n github -e GITHUB_TOKEN
```

### Inspect without revealing values

```bash
op_env_list -t myproject          # GITHUB_TOKEN
op_env_list -t myproject -i       # github:GITHUB_TOKEN
```

### Clean up

```bash
op_env_unset -t myproject
```

### Update or delete

```bash
op_env_update -n github -s GITHUB_TOKEN=ghp_new_token
op_env_delete -n github
```

## mise integration

[mise](https://mise.jdx.dev/) can source a helper script when entering a project directory. Create a `.mise-env.sh` at the project root:

```bash
#!/usr/bin/env bash
# .mise-env.sh — loaded by mise, never committed with secrets
source "${HOME}/.op-env-export.sh"
op_envs -t myproject 2>/dev/null
```

Then reference it from `.mise.toml`:

```toml
[env]
_.source = ".mise-env.sh"
```

Every `mise` task in the project will now have the 1Password secrets available as environment variables.

### With a `.op-env` hook

If some tools require different naming conventions (e.g. Terraform's `TF_VAR_*` prefix), add a `.op-env` file next to `.mise.toml`:

```bash
# .op-env  — sourced automatically by op_envs after secrets are loaded
export TF_VAR_github_token="${GITHUB_TOKEN}"
export TF_VAR_db_password="${DB_PASSWORD}"
```

`op_envs` will pick it up automatically — no changes to `.mise.toml` needed.

## Default tag

Set `OP_ENV_DEFAULT_TAG` in your shell profile to skip `-t` when creating items:

```bash
export OP_ENV_DEFAULT_TAG="myteam"
```

```bash
op_env_add -n github -s GITHUB_TOKEN=ghp_xxx   # tagged 'myteam' automatically
```

## Security notes

- Secrets are never written to disk by this tool.
- Field values marked as `concealed` in 1Password remain concealed; the CLI returns the plaintext value only when explicitly fetched.
- `op_env_list` never prints secret values — only variable names.
- The `.op-env` hook is a plain shell script; treat it like any other script in your repo.

---

If this tool saves you time, consider buying me a coffee: [buycoffee.to/szymonrychu](https://buycoffee.to/szymonrychu)
