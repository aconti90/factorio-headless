#!/usr/bin/env bash
# Unit tests for the pure-logic helpers in docker/update-mods.sh — the
# functions that don't need network access. Run manually or via lint.sh;
# no CI wiring for these, matching this repo's existing bash-only test
# conventions (the live mod-portal-update path is verified manually, not
# by an automated test — see docs/superpowers/specs/2026-09-25-mod-auto-update-design.md).
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=docker/update-mods.sh
source docker/update-mods.sh

fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" != "${actual}" ]; then
    echo "FAIL: ${desc} — expected '${expected}', got '${actual}'"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
}

assert_true() {
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc}"
    fail=1
  fi
}

assert_false() {
  local desc="$1"; shift
  if "$@"; then
    echo "FAIL: ${desc} (expected false)"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
}

assert_true  "1.3.0 is newer than 1.2.3" mod_version_newer "1.2.3" "1.3.0"
assert_false "1.2.3 is not newer than itself" mod_version_newer "1.2.3" "1.2.3"
assert_false "1.2.3 is not newer than 1.10.0" mod_version_newer "1.10.0" "1.2.3"
assert_true  "1.10.0 is newer than 1.9.0 (numeric, not lexical)" mod_version_newer "1.9.0" "1.10.0"

assert_eq "parses simple mod filename" "some-mod 1.2.3" "$(parse_mod_filename 'some-mod_1.2.3.zip')"
assert_eq "parses mod name containing underscores" "my_mod_name 0.10.5" "$(parse_mod_filename 'my_mod_name_0.10.5.zip')"
assert_eq "rejects filename with no version" "" "$(parse_mod_filename 'not-a-versioned-mod.zip')"

assert_true  "name found in ignore list" is_ignored "foo" "bar,foo,baz"
assert_true  "name found in ignore list with spaces" is_ignored "foo" "bar, foo , baz"
assert_false "name not in ignore list" is_ignored "qux" "bar,foo,baz"
assert_false "empty ignore list matches nothing" is_ignored "foo" ""

exit "${fail}"
