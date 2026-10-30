#!/usr/bin/env bash
#
# Pre-publish lint. Blocks the things that are invisible on the author's machine
# but break for the next person or should never be published:
#   * hard-coded 12-digit AWS account IDs (except doc example 111122223333)
#   * AWS access key IDs (AKIA/ASIA...)
#   * routable IPv4 addresses (allow RFC 5737 doc ranges + private + loopback)
#   * absolute paths into a home directory
#
# The patterns use Perl regex (lookaheads), so they run under perl rather than
# grep -E, which does not support them. A check that cannot run fails the lint
# instead of silently passing.
#
# Exit non-zero if any are found.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Scan the files git would publish (tracked + untracked-but-not-ignored),
# skipping binaries and this script (its comments name the patterns it blocks).
files=()
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.png|*.zip|scripts/lint-repo.sh) continue ;;
  esac
  files+=("$f")
done < <(git ls-files --cached --others --exclude-standard)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "lint-repo: no files to scan (is this a git checkout?)" >&2
  exit 2
fi

fail=0
check() {
  local label="$1" pattern="$2" hits rc
  set +e
  hits=$(PATTERN="$pattern" perl -ne '
    BEGIN { $re = qr/$ENV{PATTERN}/ }
    print "$ARGV:$.:$_" if $_ =~ $re;
    close ARGV if eof;
  ' "${files[@]}")
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "lint-repo: check '$label' failed to run (perl exit $rc)" >&2
    exit 2
  fi
  if [[ -n "$hits" ]]; then
    echo "FAIL: $label"
    echo "$hits"
    echo
    fail=1
  fi
}

# Account IDs: 12 consecutive digits, excluding the AWS doc example.
check "hard-coded AWS account id" '(?<![0-9])(?!111122223333(?![0-9]))[0-9]{12}(?![0-9])'
check "AWS access key id" '(AKIA|ASIA)[A-Z0-9]{16}'
check "absolute home path" '/Users/[a-z]|/home/[a-z]'

# Routable IPv4: flag anything that is NOT 0.0.0.0, 10./127./192.168./
# 172.16-31. (private/loopback) or the RFC 5737 doc ranges.
check "possible routable IP address" \
  '(?<![0-9.])(?!0\.0\.0\.0(?![0-9]))(?!10\.)(?!127\.)(?!192\.168\.)(?!172\.(1[6-9]|2[0-9]|3[01])\.)(?!192\.0\.2\.)(?!198\.51\.100\.)(?!203\.0\.113\.)((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?![0-9.])'

if [[ "$fail" -ne 0 ]]; then
  echo "lint-repo: findings above must be resolved before publishing."
  exit 1
fi
echo "lint-repo: clean (${#files[@]} files scanned)."
