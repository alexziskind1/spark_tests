#!/usr/bin/env sh
# hf_login.sh — non-interactive Hugging Face login from a token file

set -eu

# Default token file; override with first arg or HF_TOKEN_FILE env var
TOKEN_FILE="${1:-${HF_TOKEN_FILE:-$HOME/.config/huggingface/token}}"

# Pick the CLI: prefer `hf`, fall back to `huggingface-cli`
if command -v hf >/dev/null 2>&1; then
  HF_CMD="hf auth login"
elif command -v huggingface-cli >/dev/null 2>&1; then
  HF_CMD="huggingface-cli login"
else
  echo "Error: neither 'hf' nor 'huggingface-cli' found in PATH." >&2
  echo "Install with: pip install -U 'huggingface_hub[cli]'" >&2
  exit 1
fi

# Validate token file
if [ ! -f "$TOKEN_FILE" ]; then
  echo "Error: token file not found: $TOKEN_FILE" >&2
  echo "Create it with:  mkdir -p ~/.config/huggingface && echo 'hf_...yourtoken...' > ~/.config/huggingface/token && chmod 600 ~/.config/huggingface/token" >&2
  exit 1
fi

# Recommend restrictive perms
# shellcheck disable=SC2012
PERM=$(ls -l "$TOKEN_FILE" 2>/dev/null | awk '{print $1}')
case "$PERM" in
  -rw-------) : ;; # ok
  *)
    echo "Note: tightening permissions on $TOKEN_FILE to 600." >&2
    chmod 600 "$TOKEN_FILE"
    ;;
esac

# Read token (strip trailing newlines/spaces without echoing it)
TOKEN=$(sed -e 's/[[:space:]]*$//' "$TOKEN_FILE")

if [ -z "$TOKEN" ]; then
  echo "Error: token file is empty (or whitespace only): $TOKEN_FILE" >&2
  exit 1
fi

# Perform login (do not echo the token)
# --add-to-git-credential ensures Git/LFS operations work seamlessly
# shellcheck disable=SC2086
$HF_CMD --token "$TOKEN" --add-to-git-credential

echo "Hugging Face login complete using $TOKEN_FILE."
