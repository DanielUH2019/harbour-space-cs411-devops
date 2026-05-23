#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
app_dir="${APP_DIR:-${repo_root}/app}"

failures=0

check() {
  local name="$1"
  shift

  if "$@"; then
    printf 'PASS %s\n' "${name}"
  else
    printf 'FAIL %s\n' "${name}"
    failures=$((failures + 1))
  fi
}

check "app/main-arm64 contains aarch64 fingerprint" \
  bash -c "cd '${app_dir}' && file ./main-arm64 2>/dev/null | grep -q aarch64"

check "app/main-stripped is stripped" \
  bash -c "cd '${app_dir}' && file ./main-stripped 2>/dev/null | grep -q 'stripped$'"

check "app/app.rb contains sinatra" \
  bash -c "grep -q sinatra '${app_dir}/app.rb' 2>/dev/null"

if [ "${failures}" -ne 0 ]; then
  printf '\n%d auto-tick check(s) failed.\n' "${failures}"
  exit 1
fi

printf '\nAll auto-tick checks passed.\n'
