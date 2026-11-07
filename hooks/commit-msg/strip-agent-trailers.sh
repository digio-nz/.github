#!/bin/sh
# strip-agent-trailers.sh <commit-msg-file>
#
# Removes agent co-author trailers from a commit message in place. The rule is
# house process (briefs/AGENTS.md: never add your agent name as co-author), and
# a brief cannot beat a harness commit template, so the fix sits where the
# commit is minted. hooks/run.sh runs it for the commit-msg trigger (through
# hooks/shims/commit-msg) in every clone that uses Michelin's hooks, then chains
# to the repo's own .git/hooks and .githooks hook. Michelin owns it; dotfiles
# installs this runner rather than keeping a copy.
# strip-agent-trailers-selftest.sh beside it covers it.
#
# Strips, any case:
#   Co-Authored-By: Claude...
#   Claude-Session: ...
# A human co-author trailer never matches.

msg_file="$1"
[ -f "$msg_file" ] || exit 0

tmp="$msg_file.strip-agent-trailers.$$"
grep -viE '^co-authored-by: *claude|^claude-session:' "$msg_file" > "$tmp"

# Drop the trailing blank lines a removed trailer block leaves behind. awk
# holds a blank run and prints it only when a non-blank line follows.
awk 'BEGIN{n=0} /^[[:space:]]*$/{n++; next} {for(i=0;i<n;i++) print ""; n=0; print}' "$tmp" > "$msg_file"
rm -f "$tmp"
