#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEST_BIN="${TMPDIR:-/tmp}/camp-tests-$(id -u)"
swiftc -o "$TEST_BIN" "$ROOT/scripts/test-camp.swift" "$ROOT"/Sources/CampCore/*.swift
exec "$TEST_BIN" "$@"
