#!/usr/bin/env bash

# Shared shell helpers for platform integration scripts.

_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(_ts)] $*"
}

warn() {
  echo "[$(_ts)] WARN: $*" >&2
}

die() {
  echo "[$(_ts)] ERROR: $*" >&2
  exit 1
}

ensure_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
}

maybe_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

is_true() {
  local v
  v="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
  case "${v}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() {
  [[ "${1}" =~ ^[0-9]+$ ]]
}

nearest_existing_path() {
  local p="$1"
  while [[ ! -e "${p}" ]]; do
    local parent
    parent="$(dirname "${p}")"
    if [[ "${parent}" == "${p}" ]]; then
      break
    fi
    p="${parent}"
  done
  echo "${p}"
}

path_available_kb() {
  local p="$1"
  local existing
  existing="$(nearest_existing_path "${p}")"
  df -Pk "${existing}" | awk 'NR==2 {print $4}'
}

path_mountpoint() {
  local p="$1"
  local existing
  existing="$(nearest_existing_path "${p}")"
  df -Pk "${existing}" | awk 'NR==2 {print $6}'
}

gdscheck_binary() {
  if command -v gdscheck >/dev/null 2>&1; then
    command -v gdscheck
    return 0
  fi
  if [[ -x /usr/local/cuda/gds/tools/gdscheck ]]; then
    echo "/usr/local/cuda/gds/tools/gdscheck"
    return 0
  fi
  if [[ -x /usr/local/cuda-12.8/gds/tools/gdscheck ]]; then
    echo "/usr/local/cuda-12.8/gds/tools/gdscheck"
    return 0
  fi
  if [[ -x /usr/local/cuda-12.6/gds/tools/gdscheck ]]; then
    echo "/usr/local/cuda-12.6/gds/tools/gdscheck"
    return 0
  fi
  return 1
}
