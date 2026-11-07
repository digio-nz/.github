#!/usr/bin/env bash
# Offline test of lib/host.sh on the host it runs on. CI runs it on GitHub's Linux and macOS runners.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd -P)"
LIB="$DIR/host.sh"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
passes=0 failures=0
pass() { printf 'ok: %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
expect() { local name="$1" want="$2" got; shift 2; got="$("$@" 2>/dev/null)"; if [ "$got" = "$want" ]; then pass "$name"; else fail "$name: got [$got], want [$want]"; fi; }
code() { local name="$1" want="$2" got; shift 2; "$@" >/dev/null 2>&1; got=$?; if [ "$got" = "$want" ]; then pass "$name"; else fail "$name: exit $got, want $want"; fi; }
# shellcheck source=host.sh
. "$LIB"

os="$(host_os)"
case "$(uname -s)" in Darwin) want=darwin ;; *) want=linux ;; esac
expect "host_os names this host" "$want" echo "$os"
echo "host: $os ($(uname -sm))"
code "the library run as a command exits 2" 2 bash "$LIB"

f="$tmp/file"; printf 'alpha\nbeta\n' >"$f"
TZ=UTC touch -t 202001020304.05 "$f"
expect "host_mtime prints epoch seconds" 1577934245 host_mtime "$f"
code "host_mtime of a missing file exits 2" 2 host_mtime "$tmp/none"
chmod 640 "$f"; expect "host_mode prints 640" 640 host_mode "$f"
chmod 600 "$f"; expect "host_mode prints 600" 600 host_mode "$f"
chmod 4755 "$f"; expect "host_mode keeps the setuid bit" 4755 host_mode "$f"
chmod 0 "$f"; expect "host_mode prints 0 for no bits" 0 host_mode "$f"
chmod 600 "$f"
code "host_mode with no file exits 2" 2 host_mode

expect "host_epoch reads a UTC time" 1577934245 host_epoch 2020-01-02T03:04:05Z
expect "host_epoch reads a day as its UTC midnight" 1577923200 host_epoch 2020-01-02
code "host_epoch refuses a relative date" 2 host_epoch yesterday
code "host_epoch refuses a time with an offset" 2 host_epoch 2020-01-02T03:04:05+01:00
code "host_epoch refuses month 13" 2 host_epoch 2020-13-02
expect "host_date prints UTC ISO 8601 by default" 2020-01-02T03:04:05Z host_date 1577934245
expect "host_date takes a format" 1970-01-01 host_date 0 +%Y-%m-%d
expect "host_date and host_epoch round-trip" 1700000000 host_epoch "$(host_date 1700000000)"
expect "host_date subtracts days by arithmetic" 2019-12-26 host_date $((1577934245 - 7 * 86400)) +%Y-%m-%d
code "host_date refuses a word" 2 host_date soon
code "host_date refuses a format without +" 2 host_date 0 %Y

host_sed_i 's/alpha/gamma/' "$f"
expect "host_sed_i edits the file in place" "gamma beta" sh -c "tr '\n' ' ' <'$f' | sed 's/ \$//'"
expect "host_sed_i leaves no backup file" "file" sh -c "ls '$tmp'"
host_sed_i -E 's/(gam)ma/\1ut/' "$f"
expect "host_sed_i takes -E" "gamut" head -1 "$f"
cp "$f" "$tmp/second"; host_sed_i 's/beta/delta/' "$f" "$tmp/second"
expect "host_sed_i edits each file it names" "delta delta" echo "$(tail -1 "$f") $(tail -1 "$tmp/second")"
rm -f "$tmp/second"
code "host_sed_i without a file exits 2" 2 host_sed_i 's/a/b/'
code "host_sed_i on a missing file fails" 1 bash -c ". '$LIB'; host_sed_i 's/a/b/' '$tmp/none' && exit 0 || exit 1"

expect "host_hex reads stdin" 610a00ff bash -c ". '$LIB'; printf 'a\n\0\377' | host_hex"
printf 'a\n\0\377' >"$tmp/bytes"
expect "host_hex reads a file" 610a00ff host_hex "$tmp/bytes"
expect "host_hex of nothing is empty" "" bash -c ". '$LIB'; printf '' | host_hex"
expect "host_hex proves a file ends in one newline" 0a bash -c ". '$LIB'; tail -c1 '$f' | host_hex"
code "host_hex of a missing file exits 2" 2 host_hex "$tmp/none"
long="$(head -c 100 /dev/zero | host_hex)"
expect "host_hex writes no line breaks in a long dump" 200 echo "${#long}"

for impl in host_timeout _host_timeout_bash; do
  start=$SECONDS
  code "$impl stops a slow command with 124" 124 "$impl" 1 sleep 5
  [ $((SECONDS - start)) -le 3 ] && pass "$impl stops it on time" || fail "$impl took $((SECONDS - start))s"
  "$impl" 1 bash -c 'sleep 47 & sleep 48' >/dev/null 2>&1; sleep 1
  expect "$impl stops the children the command started" 0 sh -c "ps -eo args | grep -cE '^sleep 4[78]\$'"
  expect "$impl keeps the command's stderr" err bash -c ". '$LIB'; $impl 5 sh -c 'echo err >&2' 2>&1"
  code "$impl passes the command's exit" 7 "$impl" 5 sh -c 'exit 7'
  expect "$impl passes stdin" hi bash -c ". '$LIB'; echo hi | $impl 5 cat"
  start=$SECONDS
  : "$("$impl" 1 sleep 5)"
  [ $((SECONDS - start)) -le 3 ] && pass "$impl does not hold a captured output open" || fail "$impl held the capture $((SECONDS - start))s"
done
code "host_timeout refuses a bad duration" 2 host_timeout 1s true
code "host_timeout refuses a missing command" 2 host_timeout 1

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
