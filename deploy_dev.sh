#!/usr/bin/env bash

set -euo pipefail

REMOTE_HOST=""
REMOTE_USER=""
REMOTE_BASE_DIR=""
CONTAINER_NAME=""
SSH_PORT="22"
DRY_RUN=false

_parse_env_key() {
    local key="$1" file="$2"
    python3 -c "
import re, sys
with open('$file') as f:
    for line in f:
        m = re.match(r'^${key}:\s*[\"\\x27]?(.+?)[\"\\x27]?\s*$', line)
        if m:
            print(m.group(1))
            sys.exit(0)
" 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    _v=$(_parse_env_key remote_host     "$ENV_FILE"); [[ -n "$_v" ]] && REMOTE_HOST="$_v"
    _v=$(_parse_env_key remote_user     "$ENV_FILE"); [[ -n "$_v" ]] && REMOTE_USER="$_v"
    _v=$(_parse_env_key remote_base_dir "$ENV_FILE"); [[ -n "$_v" ]] && REMOTE_BASE_DIR="$_v"
    _v=$(_parse_env_key container_name  "$ENV_FILE"); [[ -n "$_v" ]] && CONTAINER_NAME="$_v"
    _v=$(_parse_env_key ssh_port        "$ENV_FILE"); [[ -n "$_v" ]] && SSH_PORT="$_v"
    unset _v
fi

usage() {
    cat <<EOF
Usage: $0 [options]

Deploys local development files to Home Assistant host.

Options:
  --host HOST         Remote host (default: 192.168.1.210)
  --user USER         SSH username (default: $REMOTE_USER)
  --port PORT         SSH port (default: 22)
  --container NAME    Docker container to restart (default: d22e3eee61a8)
  --dry-run           Show actions without making changes
  -h, --help          Show this help message

What this script does:
  1) Copies easunpy/ -> /storage/wd4tb/home-assistant/config/custom_components/easun_inverter/easunpy
  2) Copies custom_components/easun_inverter/* -> /storage/wd4tb/home-assistant/config/custom_components/easun_inverter
  3) Restarts Docker container using sudo on remote host
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            REMOTE_HOST="$2"
            shift 2
            ;;
        --user)
            REMOTE_USER="$2"
            shift 2
            ;;
        --port)
            SSH_PORT="$2"
            shift 2
            ;;
        --container)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

missing=()
[[ -z "$REMOTE_HOST"    ]] && missing+=("remote_host (--host)")
[[ -z "$REMOTE_USER"    ]] && missing+=("remote_user (--user)")
[[ -z "$REMOTE_BASE_DIR" ]] && missing+=("remote_base_dir")
[[ -z "$CONTAINER_NAME" ]] && missing+=("container_name (--container)")
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required config (set in .env or pass as CLI flags):" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

LOCAL_EASUNPY_DIR="$SCRIPT_DIR/easunpy/"
LOCAL_COMPONENT_DIR="$SCRIPT_DIR/custom_components/easun_inverter/"
REMOTE_EASUNPY_DIR="$REMOTE_BASE_DIR/easunpy/"
REMOTE_COMPONENT_DIR="$REMOTE_BASE_DIR/"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH_CMD=(ssh -p "$SSH_PORT")

if [[ ! -d "$LOCAL_EASUNPY_DIR" ]]; then
    echo "Error: local directory not found: $LOCAL_EASUNPY_DIR" >&2
    exit 1
fi

if [[ ! -d "$LOCAL_COMPONENT_DIR" ]]; then
    echo "Error: local directory not found: $LOCAL_COMPONENT_DIR" >&2
    exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
    echo "Error: rsync is required but not installed." >&2
    exit 1
fi

RSYNC_OPTS=("-az" "--delete")
if [[ "$DRY_RUN" == true ]]; then
    RSYNC_OPTS+=("--dry-run")
fi

remote_has_rsync=false
if "${SSH_CMD[@]}" "$REMOTE" "command -v rsync >/dev/null 2>&1"; then
    remote_has_rsync=true
fi

SUDO_PASS=""
if [[ "$DRY_RUN" == false ]]; then
    if [[ -f "$ENV_FILE" ]]; then
        SUDO_PASS=$(_parse_env_key sudo_password "$ENV_FILE")
        if [[ -z "$SUDO_PASS" ]]; then
            echo "Warning: .env found but no sudo_password key. Falling back to prompt." >&2
            read -rsp "[sudo] password for ${REMOTE_USER}@${REMOTE_HOST}: " SUDO_PASS
            echo
        fi
    else
        read -rsp "[sudo] password for ${REMOTE_USER}@${REMOTE_HOST}: " SUDO_PASS
        echo
    fi
fi

sync_dir() {
    local local_dir="$1"
    local remote_dir="$2"
    local label="$3"

    echo "Syncing $label..."

    if [[ "$remote_has_rsync" == true ]]; then
        rsync "${RSYNC_OPTS[@]}" -e "ssh -p ${SSH_PORT}" "$local_dir" "$REMOTE:$remote_dir"
        return
    fi

    echo "Remote host has no rsync; using tar-over-ssh fallback."

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] Would replace contents of $remote_dir and upload from $local_dir"
        return
    fi

    # Mirror behavior similar to rsync --delete by clearing target directory first.
    printf '%s\n' "$SUDO_PASS" | "${SSH_CMD[@]}" "$REMOTE" "sudo -S 2>/dev/null mkdir -p '$remote_dir'"
    printf '%s\n' "$SUDO_PASS" | "${SSH_CMD[@]}" "$REMOTE" "sudo -S 2>/dev/null find '$remote_dir' -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
    # Disable macOS-specific metadata and avoid restoring mtimes/permissions remotely.
    { printf '%s\n' "$SUDO_PASS"; (cd "$local_dir" && find . -mindepth 1 -print0 | COPYFILE_DISABLE=1 tar --no-xattrs --no-acls -cf - --null -T -); } | "${SSH_CMD[@]}" "$REMOTE" "sudo -S 2>/dev/null tar -m -C '$remote_dir' -xf -"
}

echo "Deploy target: $REMOTE"
echo "Container: $CONTAINER_NAME"
sync_dir "$LOCAL_COMPONENT_DIR" "$REMOTE_COMPONENT_DIR" "custom component files"
sync_dir "$LOCAL_EASUNPY_DIR" "$REMOTE_EASUNPY_DIR" "easunpy module"

if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run complete. Skipping container restart."
    exit 0
fi

echo "Restarting Docker container with sudo..."
printf '%s\n' "$SUDO_PASS" | "${SSH_CMD[@]}" "$REMOTE" "sudo -S 2>/dev/null docker restart '$CONTAINER_NAME'"

echo "Deployment complete."