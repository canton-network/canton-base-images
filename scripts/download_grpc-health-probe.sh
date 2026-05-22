#!/usr/bin/env bash

# Copyright (c) 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Download grpc-health-probe static binaries for amd64 and arm64 and place in src/
set -euo pipefail

SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
VERBOSE=0
FORCE=0
SKIP_VERIFY=0 # No signature available; kept for interface consistency
AMD64_ONLY=0
ARM64_ONLY=0
MAX_RETRIES=3
RETRY_DELAY=5

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

show_help() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Download grpc-health-probe release binaries into src/ as:
  - \${SOURCE_DIR}/grpc-health-probe-amd64
  - \${SOURCE_DIR}/grpc-health-probe-arm64

Options:
  --amd64-only       Download x86_64 only
  --arm64-only       Download aarch64 only
  --force            Re-download even if files exist
  --verbose|-v       Verbose output
  --skip-verify      Ignored (no signatures available)
  -h, --help         Show help

Uses version and names from da_build.conf: GRPC_HEALTH_PROBE_VERSION, GRPC_HEALTH_PROBE_X86_NAME, GRPC_HEALTH_PROBE_ARM_NAME
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --amd64-only) AMD64_ONLY=1; shift;;
    --arm64-only) ARM64_ONLY=1; shift;;
    --force) FORCE=1; shift;;
    --skip-verify) SKIP_VERIFY=1; shift;;
    --verbose|-v) VERBOSE=1; shift;;
    -h|--help) show_help; exit 0;;
    *) err "Unknown option: $1"; show_help; exit 1;;
  esac
done

if [[ ! -f da_build.conf ]]; then err "da_build.conf not found"; exit 1; fi
# shellcheck disable=SC1091
source da_build.conf

# Application configuration
if [[ ! -f artifacts.json ]]; then
    echo "Error: artifacts.json file not found" >&2
    exit 1
fi
while IFS=$'\t' read -r outer_key inner_key value; do
  readonly "${outer_key}_${inner_key}"="$value"
done < <(jq -r '.SOURCE | to_entries[] | .key as $outer_key | .value | to_entries[] |  [$outer_key, .key, .value] | @tsv' artifacts.json)

mkdir -p "${SOURCE_DIR}"

need_amd64=1
need_arm64=1
[[ $AMD64_ONLY -eq 1 ]] && need_arm64=0
[[ $ARM64_ONLY -eq 1 ]] && need_amd64=0

# Build URLs based on version
v="${GRPC_HEALTH_PROBE_VERSION#v}"
URL_AMD64="https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/v${v}/grpc_health_probe-linux-amd64"
URL_ARM64="https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/v${v}/grpc_health_probe-linux-arm64"

fetch() {
  local url="$1" arch="$2" outname="$3"
  local outfile="${SOURCE_DIR}/${outname}"
  if [[ -f "$outfile" && $FORCE -eq 0 ]]; then
    log "Skipping download for $outname, file exists."
    return 0
  fi
  local attempt=1
  while (( attempt <= MAX_RETRIES )); do
    if curl -fSL --retry 3 --retry-delay 3 -o "$outfile" "$url"; then
      break
    fi
    log "Retry $attempt/$MAX_RETRIES failed for $url; sleeping ${RETRY_DELAY}s"
    sleep "$RETRY_DELAY"
    attempt=$((attempt+1))
  done
  if [[ ! -s "$outfile" ]]; then
    err "Failed to download $url"
    return 1
  fi
  chmod +x "$outfile"
  log "Downloaded $outname"
}

if [[ $need_amd64 -eq 1 ]]; then
  fetch "$URL_AMD64" "amd64" "$GRPC_HEALTH_PROBE_X86_NAME"
fi
if [[ $need_arm64 -eq 1 ]]; then
  fetch "$URL_ARM64" "arm64" "$GRPC_HEALTH_PROBE_ARM_NAME"
fi
