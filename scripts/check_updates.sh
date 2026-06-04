#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Check upstream for newer versions of components whose versions are specified in artifacts.json (da_build.conf may only provide paths, not version pins)
# Outputs a human-readable report by default, or JSON with --json

set -euo pipefail

SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
JSON=0
VERBOSE=0

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--json] [--verbose]

Checks upstream sources for newer releases of:
- BusyBox, glibc, ncurses, bash
- TZDB (IANA time zone database)
- OpenJDK Temurin 21 (Linux x64/aarch64)
- Tini (GitHub releases)

Exit codes:
  0: No updates found or ran with --json
  2: Updates found (only in text mode)

EOF
}

log() { [[ $VERBOSE -eq 1 ]] && echo "[$(date +'%F %T')] $*" >&2; }
err() { echo "[$(date +'%F %T')] ERROR: $*" >&2; }

die() { err "$*"; exit 1; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift;;
    --verbose|-v) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

# Application configuration
if [[ ! -f artifacts.json ]]; then
    echo "Error: artifacts.json file not found" >&2
    exit 1
fi
while IFS='=' read -r key value; do
  readonly "$key"="$value"
done < <(jq -r '.SOURCE | to_entries | map("\(.key)_VERSION=\(.value.VERSION)") | .[]' artifacts.json)

# Helpers
curl_get() { curl -fsSL --retry 3 --retry-delay 3 "$1"; }

semver_latest_from_list() {
  # Reads versions on stdin, prints the highest with sort -V
  sed 's/^v//' | sort -V | tail -1
}

compare_tzdb() {
  # Compares tzdb versions like 2025b, 2025c
  # echo newer|equal|older relative to $1 vs $2
  local cur="$1" lat="$2"
  local cy=${cur%%[a-zA-Z]*}; local cl=${cur#$cy}
  local ly=${lat%%[a-zA-Z]*}; local ll=${lat#$ly}
  if (( ly > cy )); then echo newer; return; fi
  if (( ly < cy )); then echo older; return; fi
  # same year
  if [[ "$ll" > "$cl" ]]; then echo newer; elif [[ "$ll" == "$cl" ]]; then echo equal; else echo older; fi
}

adoptium_latest_21() {
  local url="https://api.github.com/repos/adoptium/temurin21-binaries/releases/latest"
  local tag; tag=$(curl_get "$url" | sed -n 's/.*"tag_name": "jdk-\([^"]\+\)".*/\1/p') || true
  # Convert 21.0.9+11 -> 21.0.9_11
  echo "$tag" | sed 's/+/_/'
}

# Checkers
check_busybox() {
  local url="https://busybox.net/downloads/"
  local latest; latest=$(curl_get "$url" | grep -oE 'busybox-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.bz2' | sed -E 's/^busybox-|\.tar\.bz2$//g' | semver_latest_from_list) || true
  echo "$latest"
}

check_glibc() {
  local url="https://ftp.gnu.org/gnu/libc/"
  local latest; latest=$(curl_get "$url" | grep -oE 'glibc-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.xz' | sed -E 's/^glibc-|\.tar\.xz$//g' | semver_latest_from_list) || true
  echo "$latest"
}

check_ncurses() {
  local url="https://ftp.gnu.org/pub/gnu/ncurses/"
  local latest; latest=$(curl_get "$url" | grep -oE 'ncurses-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.gz' | sed -E 's/^ncurses-|\.tar\.gz$//g' | semver_latest_from_list) || true
  echo "$latest"
}

check_bash() {
  local url="https://ftp.gnu.org/gnu/bash/"
  local latest; latest=$(curl_get "$url" | grep -oE 'bash-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.gz' | sed -E 's/^bash-|\.tar\.gz$//g' | semver_latest_from_list) || true
  echo "$latest"
}

check_tzdb() {
  local url="https://data.iana.org/time-zones/releases/"
  local latest; latest=$(curl_get "$url" | grep -oE 'tzdb-[0-9]{4}[a-z]\.tar\.lz' | sed -E 's/^tzdb-|\.tar\.lz$//g' | sort -r | head -n1) || true
  echo "$latest"
}

check_tini() {
  local url="https://api.github.com/repos/krallin/tini/releases/latest"
  local tag; tag=$(curl_get "$url" | sed -n 's/.*"tag_name": "v\([^"]\+\)".*/\1/p') || true
  echo "$tag"
}

check_grpc_health_probe() {
  local url="https://api.github.com/repos/grpc-ecosystem/grpc-health-probe/releases/latest"
  local latest; latest=$(curl_get "$url" | sed -n 's/.*"tag_name": "\([^"]\+\)".*/\1/p') || true
  echo "$latest"
}

check_cacert() {
  # The cacert.pem file has a comment at the top with the date
  # Format: "## Certificate data from Mozilla as of: Wed Jan  1 04:12:06 2025 GMT"
  local url="https://curl.se/ca/cacert.pem"
  local date_line; date_line=$(curl_get "$url" 2>/dev/null | grep -m1 "Certificate data from Mozilla as of:" || true)
  if [[ -n "$date_line" ]]; then
    # Extract and convert date to YYYY-MM-DD
    # Example: "## Certificate data from Mozilla as of: Wed Jan  1 04:12:06 2025 GMT"
    local date_str; date_str=$(echo "$date_line" | sed -E 's/.*as of: (.+) GMT.*/\1/')
    # Use date command to parse and format (requires GNU date)
    local parsed_date; parsed_date=$(date -d "$date_str" +%Y-%m-%d 2>/dev/null || echo "")
    echo "$parsed_date"
  fi
}

check_screen() {
  local url="https://ftp.gnu.org/gnu/screen/"
  local latest; latest=$(curl_get "$url" | grep -oE 'screen-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.gz' | sed -E 's/^screen-|\.tar\.gz$//g' | semver_latest_from_list) || true
  echo "$latest"
}

check_jemalloc() {
  local url="https://api.github.com/repos/jemalloc/jemalloc/releases/latest"
  local tag; tag=$(curl_get "$url" | sed -n 's/.*"tag_name": "\([^"]\+\)".*/\1/p') || true
  echo "$tag"
}

# Perform checks
declare -A CURRENT LATEST URLS TYPE
URLS[busybox]="https://busybox.net/downloads/"
URLS[glibc]="https://ftp.gnu.org/gnu/libc/"
URLS[ncurses]="https://ftp.gnu.org/pub/gnu/ncurses/"
URLS[bash]="https://ftp.gnu.org/gnu/bash/"
URLS[tzdb]="https://data.iana.org/time-zones/releases/"
URLS[openjdk]="https://adoptium.net/temurin/releases/?version=21"
URLS[tini]="https://github.com/krallin/tini/releases"
URLS[grpc_health_probe]="https://github.com/grpc-ecosystem/grpc-health-probe/releases"
URLS[cacert]="https://curl.se/docs/caextract.html"
URLS[screen]="https://ftp.gnu.org/gnu/screen/"
URLS[jemalloc]="https://github.com/jemalloc/jemalloc/releases"

CURRENT[busybox]="$BUSYBOX_VERSION"
CURRENT[glibc]="$GLIBC_VERSION"
CURRENT[ncurses]="$NCURSES_VERSION"
CURRENT[bash]="$BASH_VERSION"
CURRENT[tzdb]="$TZDB_VERSION"
CURRENT[openjdk]="$OPENJDK_VERSION"
CURRENT[tini]="${TINI_VERSION#v}"
CURRENT[grpc_health_probe]="$GRPC_HEALTH_PROBE_VERSION"
CURRENT[cacert]="$CACERT_VERSION"
CURRENT[screen]="$SCREEN_VERSION"
CURRENT[jemalloc]="$JEMALLOC_VERSION"

LATEST[busybox]=$(check_busybox || true)
LATEST[glibc]=$(check_glibc || true)
LATEST[ncurses]=$(check_ncurses || true)
LATEST[bash]=$(check_bash || true)
LATEST[tzdb]=$(check_tzdb || true)
LATEST[openjdk]=$(adoptium_latest_21 || true)
LATEST[tini]=$(check_tini || true)
LATEST[grpc_health_probe]=$(check_grpc_health_probe || true)
LATEST[cacert]=$(check_cacert || true)
LATEST[screen]=$(check_screen || true)
LATEST[jemalloc]=$(check_jemalloc || true)

# Normalize Tini to include leading v for output consistency
if [[ -n ${LATEST[tini]} ]]; then LATEST[tini]="${LATEST[tini]}"; fi

updates_found=0

if [[ $JSON -eq 1 ]]; then
  printf '{"components":{'
  first=1
  for k in busybox glibc ncurses bash tzdb openjdk tini grpc_health_probe cacert screen jemalloc; do
    cur=${CURRENT[$k]:-}
    lat=${LATEST[$k]:-}
    url=${URLS[$k]}
    # Determine update availability
    upd=false
    if [[ -n "$cur" && -n "$lat" ]]; then
      if [[ "$k" == "tzdb" ]]; then
        cmp=$(compare_tzdb "$cur" "$lat")
        [[ "$cmp" == "newer" ]] && upd=true
      elif [[ "$k" == "openjdk" ]]; then
        cur_norm=${cur/+/_}
        lat_norm=${lat/+/_}
        if [[ "$lat_norm" != "$cur_norm" ]]; then upd=true; fi
      else
        if [[ "$lat" != "$cur" ]]; then upd=true; fi
      fi
    fi
    [[ $first -eq 0 ]] && printf ',' || first=0
    printf '"%s":{"current":"%s","latest":"%s","update":%s,"url":"%s"}' "$k" "${cur}" "${lat}" "$upd" "$url"
    if [[ "$upd" == true ]]; then updates_found=1; fi
  done
  printf '}}\n'
  exit 0
else
  printf "%-20s\t%-10s\t%-10s\t%-10s\t%-10s\n" "Component" "Current" "Latest" "Update"  "URL"
  for k in busybox glibc ncurses bash tzdb openjdk tini grpc_health_probe cacert screen jemalloc; do
    cur=${CURRENT[$k]:-}
    lat=${LATEST[$k]:-}
    url=${URLS[$k]}
    upd="NO"
    if [[ -n "$cur" && -n "$lat" ]]; then
      if [[ "$k" == "tzdb" ]]; then
        cmp=$(compare_tzdb "$cur" "$lat")
        [[ "$cmp" == "newer" ]] && upd="YES"
      elif [[ "$k" == "openjdk" ]]; then
        cur_norm=${cur/+/_}
        lat_norm=${lat/+/_}
        [[ "$lat_norm" != "$cur_norm" ]] && upd="YES"
      else
        [[ "$lat" != "$cur" ]] && upd="YES"
      fi
    fi
    printf "%-20s\t%-10s\t%-10s\t%-10s\t%-10s\n" "$k" "${cur:-?}" "${lat:-?}" "${upd:-}" "$url"
    [[ "$upd" == "YES" ]] && updates_found=1
  done
  if [[ $updates_found -eq 1 ]]; then
    echo "Updates available. Consider bumping versions in artifacts.json and running download/build scripts." >&2
    exit 2
  fi
fi
