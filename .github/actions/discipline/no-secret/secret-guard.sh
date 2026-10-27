#!/bin/sh
# secret-guard.sh [<remote> <url>] < <pre-push ref list>
#
# Refuses a push that adds a credential-shaped secret, in the pushed tree or
# in any commit the push sends, even one that a later commit deletes. The rule
# is the global brief's: never commit a secret value. Discipline feeds it
# a pre-push ref list for each commit in the range.
# secret-guard-selftest.sh beside it pins it.
#
# Flags only credential-shaped values: a Neon role password (npg_ and 8+
# alphanumerics) or a URI whose password is 10+ alphanumerics. The fleet's
# placeholder passwords (password, pw, e2e, <password>, ...) never match.
# tr maps NUL bytes to spaces so awk cannot drop a credential after a NUL.
# One awk pass then extracts added hunk lines; one grep -a matches the
# pattern. Exits 1 on a hit, 2 when a command on the scan path fails, 0
# otherwise.
#
# Deliberate exception: git push --no-verify

# Byte tools must not decode the diff as text. BSD tr under UTF-8 rejects a
# byte such as 0xff ("Illegal byte sequence") and a harmless binary push
# then fails closed. C locale makes tr, awk and grep read bytes.
LC_ALL=C
export LC_ALL

empty_tree=$(git hash-object -t tree /dev/null) || {
  echo "BLOCKED: secret guard could not hash the empty tree." >&2
  exit 2
}
pattern='npg_[A-Za-z0-9]{8,}|://[A-Za-z0-9._%+-]+:[A-Za-z0-9]{10,}@'
rule='Never commit a secret value.'

diff_file=$(mktemp) || {
  echo "BLOCKED: secret guard could not create a temporary file." >&2
  exit 2
}
added_file=$(mktemp) || {
  echo "BLOCKED: secret guard could not create a temporary file." >&2
  rm -f "$diff_file"
  exit 2
}
trap 'rm -f "$diff_file" "$added_file"' EXIT

# is_zero <sha>: git's all-zero sha, in either object format.
is_zero() { [ -z "$(printf '%s' "$1" | tr -d 0)" ]; }

status=0
# The || keeps a final ref line that lacks its newline.
while read -r _local_ref local_sha remote_ref remote_sha || [ -n "$local_sha" ]; do
  [ -n "$local_sha" ] || continue
  is_zero "$local_sha" && continue # deleting a ref, nothing to scan

  # A new ref, or one whose remote tip this clone has never fetched (a force
  # push over unseen work), scans everything being introduced: the whole tree,
  # and each commit that no remote-tracking ref already has; every reachable
  # commit when the clone has no remote-tracking ref.
  if is_zero "$remote_sha" || ! git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
    base="$empty_tree"
    remotes=$(git for-each-ref --count=1 refs/remotes) || {
      echo "BLOCKED: secret guard could not list remote-tracking refs for $remote_ref." >&2
      status=2
      continue
    }
    if [ -n "$remotes" ]; then set -- --not --remotes; else set --; fi
  else
    base="$remote_sha"
    set -- --not "$remote_sha"
  fi

  # Plain text whatever the user's or repo's diff config: colour, an external
  # diff, a textconv or a -diff attribute would otherwise hide added lines.
  if ! git diff --no-color --no-ext-diff --no-textconv --text "$base" "$local_sha" \
    -- ':(top)' ':(top,exclude).githooks/**' > "$diff_file"; then
    echo "BLOCKED: secret guard could not diff $base..$local_sha for $remote_ref." >&2
    status=2
    continue
  fi
  # The tree diff misses a credential that a later commit deletes; the push
  # still sends the commit that adds it. Scan each commit the push introduces,
  # merges as a combined diff. --full-history keeps a merged side branch whose
  # net change is nothing, which a path-limited log would simplify away.
  if ! git log --full-history --no-color --no-ext-diff --no-textconv --text -p --cc --format= \
    "$local_sha" "$@" -- ':(top)' ':(top,exclude).githooks/**' >> "$diff_file"; then
    echo "BLOCKED: secret guard could not read the commits in $local_sha for $remote_ref." >&2
    status=2
    continue
  fi

  # One True Awk stores a record as a C string and prints only the bytes
  # before the first NUL. Map NULs to spaces first so a credential after a
  # NUL on the same added line still reaches grep. A space keeps the line
  # and separates the prefix from the credential.
  if ! tr '\000' ' ' < "$diff_file" > "$added_file"; then
    echo "BLOCKED: secret guard could not translate the diff for $remote_ref." >&2
    status=2
    continue
  fi
  # diff --git / diff --cc starts a file header. Skip until the first @@ hunk
  # line. Inside a hunk, every line that starts with + is added content, so
  # +++ or ++ inside a hunk is never a header. GNU grep would treat NUL bytes
  # as binary; awk copies the added lines and grep -a matches the pattern.
  if ! awk '
    /^diff / { in_hunk = 0; next }
    /^@@/ { in_hunk = 1; next }
    !in_hunk { next }
    /^\+/ { print }
  ' "$added_file" > "$diff_file"; then
    echo "BLOCKED: secret guard could not scan $remote_ref." >&2
    status=2
    continue
  fi
  if ! cat "$diff_file" >/dev/null; then
    echo "BLOCKED: secret guard could not read the added lines for $remote_ref." >&2
    status=2
    continue
  fi
  hits=$(grep -a -E "$pattern" "$diff_file")
  gs=$?
  if [ "$gs" -eq 1 ]; then
    continue
  fi
  if [ "$gs" -ne 0 ]; then
    echo "BLOCKED: secret guard could not scan $remote_ref." >&2
    status=2
    continue
  fi
  if [ -z "$hits" ]; then
    echo "BLOCKED: secret guard could not scan $remote_ref." >&2
    status=2
    continue
  fi

  if ! printf '%s\n' "$hits" > "$added_file"; then
    echo "BLOCKED: secret guard could not write matching lines for $remote_ref." >&2
    status=2
    continue
  fi

  echo >&2
  echo "BLOCKED: push to $remote_ref adds a line that looks like a real credential:" >&2
  if ! sed -E -e 's#(://[^:]+:)[^@]{3}[^@]*@#\1<redacted>@#g' -e 's#npg_[A-Za-z0-9]{8,}#npg_<redacted>#g' -e 's/^/  /' "$added_file" >&2; then
    echo "BLOCKED: secret guard could not redact matching lines for $remote_ref." >&2
    status=2
    continue
  fi
  echo >&2
  echo "House rule (digio-michelin briefs/AGENTS.md):" >&2
  echo "  $rule" >&2
  echo >&2
  echo "If this is a false positive: git push --no-verify" >&2
  echo >&2
  [ "$status" -ne 0 ] || status=1
done

exit "$status"
