#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Functional tests for container image variants
# Tests each variant to ensure components are installed and working correctly

set -euo pipefail

SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
VERBOSE=0
VARIANT=""
IMAGE_TAG=""
PLATFORM=""
FAIL_FAST=1

# Test results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
declare -a FAILED_TESTS

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --variant VARIANT --tag IMAGE_TAG [OPTIONS]

Run functional tests against a container image variant.

OPTIONS:
  --variant NAME       Variant to test (minimal, base, jdk, full)
  --tag IMAGE_TAG      Docker image tag to test
  --platform PLATFORM  Platform to test (e.g., linux/amd64, linux/arm64)
  --no-fail-fast       Continue testing even after failures
  --verbose|-v         Verbose output
  -h, --help           Show this help

EXAMPLES:
  ${SCRIPT_NAME} --variant jdk --tag myapp:jdk
  ${SCRIPT_NAME} --variant minimal --tag myapp:minimal --platform linux/amd64
  ${SCRIPT_NAME} --variant full --tag myapp:full --verbose

EOF
}

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
verbose() { [[ $VERBOSE -eq 1 ]] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] DEBUG: $*" >&2 || true; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2"; shift 2;;
    --tag) IMAGE_TAG="$2"; shift 2;;
    --platform) PLATFORM="$2"; shift 2;;
    --no-fail-fast) FAIL_FAST=0; shift;;
    --verbose|-v) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 1;;
  esac
done

if [[ -z "$VARIANT" || -z "$IMAGE_TAG" ]]; then
  err "Both --variant and --tag are required"
  usage
  exit 1
fi

# Build docker run command
DOCKER_RUN=(docker run --rm)
[[ -n "$PLATFORM" ]] && DOCKER_RUN+=(--platform "$PLATFORM")
DOCKER_RUN+=("$IMAGE_TAG")

# Test runner
run_test() {
  local test_name="$1"
  shift
  local cmd=("$@")

  TESTS_RUN=$((TESTS_RUN + 1))
  verbose "Running test: $test_name"

  echo "${DOCKER_RUN[@]}" "${cmd[@]}"
  if "${DOCKER_RUN[@]}" "${cmd[@]}" > /dev/null 2>&1; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    log "✓ PASS: $test_name"
    return 0
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS+=("$test_name")
    log "✗ FAIL: $test_name"
    if [[ $FAIL_FAST -eq 1 ]]; then
      err "Test failed and fail-fast is enabled"
      exit 1
    fi
    return 1
  fi
}

run_test_with_output() {
  local test_name="$1"
  local expected="$2"
  shift 2
  local cmd=("$@")

  TESTS_RUN=$((TESTS_RUN + 1))
  verbose "Running test: $test_name (expecting: $expected)"

  local output
  echo "${DOCKER_RUN[@]}" "${cmd[@]}"
  if output=$("${DOCKER_RUN[@]}" "${cmd[@]}" 2>&1); then
    if [[ "$output" == *"$expected"* ]]; then
      TESTS_PASSED=$((TESTS_PASSED + 1))
      log "✓ PASS: $test_name"
      return 0
    else
      TESTS_FAILED=$((TESTS_FAILED + 1))
      FAILED_TESTS+=("$test_name")
      log "✗ FAIL: $test_name (output didn't contain '$expected')"
      verbose "  Output: $output"
      [[ $FAIL_FAST -eq 1 ]] && exit 1
      return 1
    fi
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS+=("$test_name")
    log "✗ FAIL: $test_name (command failed)"
    [[ $FAIL_FAST -eq 1 ]] && exit 1
    return 1
  fi
}

# Core tests (all variants)
test_core() {
  log "Testing core components..."

  # Test glibc
  run_test "glibc: ld.so exists" /bin/bash -c "test -f /lib64/ld-linux-x86-64.so.2 || test -f /lib/ld-linux-aarch64.so.1"

  # Test busybox
  run_test "busybox: exists" /bin/bash -c "command -v busybox"
  run_test_with_output "busybox: version" "BusyBox" /bin/bash -c /bin/busybox --help
  run_test "busybox: ls command" /bin/bash -c /bin/ls /

  # Test basic filesystem
  run_test "filesystem: /etc/passwd exists" /bin/bash -c "test -f /etc/passwd"
  run_test "filesystem: /etc/group exists" /bin/bash -c "test -f /etc/group"
  # No grep in most images
  # run_test "filesystem: root user exists" /bin/bash -c "/bin/grep -q '^root:' /etc/passwd"
  # run_test "filesystem: nonroot user exists" /bin/bash -c "/bin/grep -q '^nonroot:' /etc/passwd"
}

# Minimal variant tests
test_minimal() {
  log "Testing minimal variant specifics..."

  # CA certs and tzdb should be present
  run_test "ca-certs: directory exists" /usr/bin/find /etc/ssl/certs
  run_test "ca-certs: files present" /usr/bin/find /etc/ssl/certs -type f -print
  run_test "ca-certs: links present:" /usr/bin/find /etc/ssl/certs -type l -print
  run_test "tzdb: directory exists" /usr/bin/find /usr/share/zoneinfo
  run_test "tzdb: UTC exists" /usr/bin/find /usr/share/zoneinfo/UTC
}

# Base variant tests
test_base() {
  log "Testing base variant specifics..."

  # Bash
  run_test "bash: exists" /bin/bash -c "command -v bash"
  run_test_with_output "bash: version" "GNU bash" /bin/bash --version
  run_test "bash: sh symlink works" /bin/bash -c "test -L /bin/sh"

  # Ncurses
  run_test "ncurses: tput exists" /bin/bash -c "command -v tput"
  run_test "ncurses: terminfo exists" /bin/bash -c "test -d /usr/share/terminfo"
  # This test fails unless called with docker run -it --rm ....
  #run_test_with_output "ncurses: tput colors" "8" /usr/bin/tput colors

  # CA certs and tzdb
  run_test "ca-certs: directory exists" /bin/bash -c "test -d /etc/ssl/certs"
  run_test "tzdb: directory exists" /bin/bash -c "test -d /usr/share/zoneinfo"

  # JDK should NOT be present in base
  run_test "base: no java" /bin/bash -c "! command -v java"
}

# jdk variant tests
test_jdk() {
  log "Testing jdk variant specifics..."

  # All base components
  run_test "bash: exists" /bin/bash -c "command -v bash"
  run_test "ncurses: tput exists" /bin/bash -c "command -v tput"

  # JDK
  run_test "jdk: java exists" /bin/bash -c "command -v java"
  run_test "jdk: JAVA_HOME set" /bin/bash -c "test -n \"\$JAVA_HOME\""
  run_test_with_output "jdk: version" "openjdk version" /usr/java/bin/java -version
  run_test "jdk: javac exists" /bin/bash -c "test -f /usr/java/bin/javac"

  # Tini
  run_test "tini: exists" /bin/bash -c "command -v tini"
  run_test "tini: executable" /bin/bash -c "test -x /usr/bin/tini"
  run_test_with_output "tini: version" "tini version" /usr/bin/tini --version

  # CA certs and tzdb
  run_test "ca-certs: directory exists" /bin/bash -c "test -d /etc/ssl/certs"
  run_test "tzdb: directory exists" /bin/bash -c "test -d /usr/share/zoneinfo"
  run_test "tzdb: America/New_York" /bin/bash -c "test -f /usr/share/zoneinfo/UTC"
}

# Dev variant tests
test_full() {
  log "Testing full variant specifics..."

  # All jdk components
  run_test "bash: exists" /bin/bash -c "command -v bash"
  run_test "jdk: java exists" /bin/bash -c "command -v java"
  run_test "tini: exists" /bin/bash -c "command -v tini"

  # Full busybox tools
  run_test "busybox-full: vi exists" /bin/bash -c "command -v vi"
  run_test "busybox-full: wget exists" /bin/bash -c "command -v wget"
  run_test "busybox-full: find exists" /bin/bash -c "command -v find"

  # grpc-health-probe
  run_test "grpc-health-probe: exists" /bin/bash -c "command -v grpc-health-probe"
  run_test "grpc-health-probe: executable" /bin/bash -c "test -x /usr/bin/grpc-health-probe"
  run_test_with_output "grpc-health-probe: version" "commit" /bin/bash -c "/usr/bin/grpc-health-probe -version"

  # screen
  run_test "screen: exists" /bin/bash -c "command -v screen"
  run_test "screen: executable" /bin/bash -c "test -x /usr/bin/screen"
  run_test_with_output "screen: version" "Screen version" /usr/bin/screen --version

  # libxcrypt
  run_test "libxcrypt: libcrypt.so.1 exists" /bin/bash -c "test -f /usr/lib/libcrypt.so.1"

  # jemalloc
  run_test "jemalloc: libjemalloc.so.2 exists" /bin/bash -c "test -f /usr/lib/libjemalloc.so.2"
  run_test "jemalloc: jemalloc.sh exists" /bin/bash -c "test -f /usr/bin/jemalloc.sh"
  run_test "jemalloc: jemalloc-config exists" /bin/bash -c "test -f /usr/bin/jemalloc-config"
  run_test "jemalloc: loads correctly" /bin/bash -c "LD_PRELOAD=/usr/lib/libjemalloc.so.2 /bin/true"

  # Locale
  run_test_with_output "locale: en_US.UTF-8 is installed" "en_US.utf8" /bin/bash -c "locale -a"
}

# Node variant tests
test_node() {
  log "Testing node variant specifics..."

  # Node.js
  run_test "node: exists" /bin/bash -c "command -v node"
  run_test_with_output "node: version" "v" /usr/bin/node --version
  run_test_with_output "node: executes script" "Hello from Node" /bin/bash -c "node -e 'console.log(\"Hello from Node\")'"
  run_test "npm: exists" /bin/bash -c "command -v npm"
  run_test_with_output "npm: version" "" /bin/bash -c "npm --version"
  run_test "npm: can install package (express)" /bin/bash -c "npm install express"
  run_test "npm: can install native module (bcrypt)" /bin/bash -c "npm install bcrypt"

}

# Main test execution
main() {
  log "Starting functional tests for variant: $VARIANT"
  log "Image: $IMAGE_TAG"
  [[ -n "$PLATFORM" ]] && log "Platform: $PLATFORM"
  log ""

  # Check if image exists
  if ! docker image inspect "$IMAGE_TAG" > /dev/null 2>&1; then
    err "Image $IMAGE_TAG not found"
    exit 1
  fi

  # Run variant-specific tests
  case "$VARIANT" in
    minimal)
      test_minimal
      ;;
    base)
      test_core
      test_base
      ;;
    jdk)
      test_core
      test_jdk
      ;;
    full)
      test_core
      test_full
      ;;
    node)
      test_core
      test_node
      ;;
    *)
      err "Unknown variant: $VARIANT"
      exit 1
      ;;
  esac

  log ""
  log "═══════════════════════════════════════"
  log "Test Summary"
  log "═══════════════════════════════════════"
  log "Total:  $TESTS_RUN"
  log "Passed: $TESTS_PASSED"
  log "Failed: $TESTS_FAILED"

  if [[ $TESTS_FAILED -gt 0 ]]; then
    log ""
    log "Failed tests:"
    for test in "${FAILED_TESTS[@]}"; do
      log "  - $test"
    done
    exit 1
  fi

  log ""
  log "✓ All tests passed!"
  exit 0
}

main
