#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Download Mozilla CA certificate bundle from curl project
# See: https://curl.se/docs/caextract.html

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source environment
# shellcheck source=../.envrc
source "${PROJECT_ROOT}/da_build.conf"

# Application configuration
if [[ ! -f artifacts.json ]]; then
    echo "Error: artifacts.json file not found" >&2
    exit 1
fi
while IFS=$'\t' read -r outer_key inner_key value; do
  readonly "${outer_key}_${inner_key}"="$value"
done < <(jq -r '.SOURCE | to_entries[] | .key as $outer_key | .value | to_entries[] |  [$outer_key, .key, .value] | @tsv' artifacts.json)

# Ensure SOURCE_DIR is set
SOURCE_DIR="${SOURCE_DIR:-${PROJECT_ROOT}/src}"

CACERT_URL="https://curl.se/ca/cacert-${CACERT_VERSION}.pem"
CACERT_SHA256_URL="https://curl.se/ca/cacert-${CACERT_VERSION}.pem.sha256"
CACERT_FILE="${SOURCE_DIR}/cacert.pem"
CACERT_SHA256_FILE="${SOURCE_DIR}/cacert.pem.sha256"
CACERT_VERSION_FILE="${SOURCE_DIR}/cacert.version"

log() { echo "[$(date +'%F %T')] $*"; }
err() { echo "[$(date +'%F %T')] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }



get_bundle_date() {
    local file="$1"
    # Extract date from comment like: "## Certificate data from Mozilla as of: Tue Nov  4 04:12:02 2025 GMT"
    local date_line
    date_line=$(head -n 20 "${file}" | grep -i 'certificate data from Mozilla as of:' || true)
    if [[ -n "$date_line" ]]; then
        local date_str
        date_str=$(echo "$date_line" | sed -E 's/.*as of: (.+) GMT.*/\1/')
        # Convert to YYYY-MM-DD
        date -d "$date_str" +%Y-%m-%d 2>/dev/null || echo ""
    fi
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local retries=3
    local delay=3

    log "Downloading ${url}..."
    for i in $(seq 1 $retries); do
        if curl -fsSL --retry 3 --retry-delay 2 -o "${output}" "${url}"; then
            log "Downloaded successfully: ${output}"
            return 0
        fi
        err "Download attempt $i failed for ${url}"
        [[ $i -lt $retries ]] && sleep $delay
    done
    die "Failed to download ${url} after ${retries} attempts"
}

verify_sha256() {
    local file="$1"
    local sha256_file="$2"

    log "Verifying SHA256 checksum..."

    # Extract just the hash from the .sha256 file (format: "hash  filename")
    local expected_hash
    expected_hash=$(awk '{print $1}' "${sha256_file}")

    # Compute actual hash
    local actual_hash
    actual_hash=$(sha256sum "${file}" | awk '{print $1}')

    if [[ "${actual_hash}" == "${expected_hash}" ]]; then
        log "SHA256 verification passed"
        return 0
    else
        err "SHA256 mismatch!"
        err "Expected: ${expected_hash}"
        err "Got:      ${actual_hash}"
        return 1
    fi
}

main() {
    log "Downloading Mozilla CA certificate bundle..."

    mkdir -p "${SOURCE_DIR}"

    # Check if we already have the correct version
    if [[ -f "${CACERT_FILE}" && -f "${CACERT_VERSION_FILE}" ]]; then
        local existing_version
        existing_version=$(cat "${CACERT_VERSION_FILE}")
        if [[ "${existing_version}" == "${CACERT_VERSION}" ]]; then
            log "CA certificate bundle version ${CACERT_VERSION} already downloaded"
            return 0
        else
            log "Existing version ${existing_version} differs from target ${CACERT_VERSION}, re-downloading..."
        fi
    fi

    # Download the certificate bundle
    download_with_retry "${CACERT_URL}" "${CACERT_FILE}"

    # Download the SHA256 checksum
    download_with_retry "${CACERT_SHA256_URL}" "${CACERT_SHA256_FILE}"

    # Verify the checksum
    if ! verify_sha256 "${CACERT_FILE}" "${CACERT_SHA256_FILE}"; then
        die "CA certificate verification failed"
    fi

    # Extract and verify the bundle date
    local bundle_date
    bundle_date=$(get_bundle_date "${CACERT_FILE}")

    if [[ -z "${bundle_date}" ]]; then
        err "WARNING: Could not extract date from certificate bundle"
        log "Bundle info: $(head -n 20 "${CACERT_FILE}" | grep -i 'certificate data from' || echo 'Not found')"
    else
        log "Bundle date: ${bundle_date}"

        # Check if the downloaded bundle matches or is newer than the pinned version
        if [[ "${bundle_date}" < "${CACERT_VERSION}" ]]; then
            err "WARNING: Downloaded bundle date (${bundle_date}) is older than pinned version (${CACERT_VERSION})"
            err "This may indicate the upstream has not been updated yet"
            err "Consider checking ${CACERT_URL}"
        elif [[ "${bundle_date}" != "${CACERT_VERSION}" ]]; then
            log "NOTE: Downloaded bundle date (${bundle_date}) differs from pinned version (${CACERT_VERSION})"
            log "Update CACERT_VERSION in da_build.conf to ${bundle_date} to pin this version"
        fi
    fi

    # Show certificate stats
    local cert_count
    cert_count=$(grep -c 'BEGIN CERTIFICATE' "${CACERT_FILE}" || echo "0")
    log "Downloaded ${cert_count} CA certificates"

    # Save the actual bundle date as the version
    if [[ -n "${bundle_date}" ]]; then
        echo "${bundle_date}" > "${CACERT_VERSION_FILE}"
        log "Saved bundle version: ${bundle_date}"
    else
        echo "${CACERT_VERSION}" > "${CACERT_VERSION_FILE}"
        log "Saved pinned version: ${CACERT_VERSION}"
    fi

    log "CA certificate bundle ready at: ${CACERT_FILE}"
}

main "$@"
