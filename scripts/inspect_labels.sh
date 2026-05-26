#!/usr/bin/env bash

# Copyright (c) canton-base-images contributors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Display image labels in a readable format

set -euo pipefail

IMAGE="${1:-}"

if [[ -z "$IMAGE" ]]; then
    echo "Usage: $0 <image>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 myimage:latest" >&2
    exit 1
fi

if ! docker inspect "$IMAGE" &>/dev/null; then
    echo "Error: Image '$IMAGE' not found" >&2
    exit 1
fi

# Get all labels as JSON
LABELS=$(docker inspect "$IMAGE" --format='{{json .Config.Labels}}')

if [[ "$LABELS" == "null" || "$LABELS" == "{}" ]]; then
    echo "No labels found on image: $IMAGE"
    exit 0
fi

# Pretty print with formatting
echo "═══════════════════════════════════════════════════════════"
echo "DA Base Image Labels"
echo "═══════════════════════════════════════════════════════════"
echo "Image: $IMAGE"
echo ""

# OCI Standard Labels
echo "OCI Standard Labels:"
echo "$LABELS" | jq -r '
  to_entries |
  map(select(.key | startswith("org.opencontainers.image."))) |
  sort_by(.key) |
  .[] |
  "  \(.key | split(".") | .[-1]): \(.value)"
' 2>/dev/null || echo "  (none)"

echo ""

# Custom Image Labels
echo "Custom Labels:"
echo "$LABELS" | jq -r '
  to_entries |
  map(select(.key | startswith("io.dach.image."))) |
  sort_by(.key) |
  .[] |
  "  \(.key | split(".") | .[-1]): \(.value)"
' 2>/dev/null || echo "  (none)"

echo ""

# Component Version Labels
echo "Component Versions:"
echo "$LABELS" | jq -r '
  to_entries |
  map(select(.key | startswith("io.dach.component."))) |
  sort_by(.key) |
  .[] |
  "  \(.key | split(".") | .[-2]): \(.value)"
' 2>/dev/null || echo "  (none)"

echo ""

# Other Labels
OTHER=$(echo "$LABELS" | jq -r '
  to_entries |
  map(select(.key | startswith("org.opencontainers.image.") or startswith("io.dach.") | not)) |
  length
')

if [[ "$OTHER" -gt 0 ]]; then
    echo "Other Labels:"
    echo "$LABELS" | jq -r '
      to_entries |
      map(select(.key | startswith("org.opencontainers.image.") or startswith("io.dach.") | not)) |
      sort_by(.key) |
      .[] |
      "  \(.key): \(.value)"
    '
    echo ""
fi

echo "═══════════════════════════════════════════════════════════"

# Show raw JSON if --json flag
if [[ "${2:-}" == "--json" ]]; then
    echo ""
    echo "Raw JSON:"
    echo "$LABELS" | jq .
fi
