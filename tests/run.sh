#!/bin/bash
# Test runner for agent-memory.
#
# Pure bash 3.2 (the macOS default) with no extra dependencies. agent-memory
# itself only requires git/rg/jq, so the tests must not add bats on top.
#
# Every case runs against an isolated fixture rooted at CLAUDE_CONFIG_DIR and
# CODEX_HOME, so a developer's real Claude Code memory is never read or
# written by the suite.

set -u

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
agent_memory="$repo_root/bin/agent-memory"

[ -x "$agent_memory" ] || { printf 'not executable: %s\n' "$agent_memory" >&2; exit 1; }

EX_OK=0
EX_NOMATCH=1
EX_USAGE=64
EX_DATAERR=65
EX_NOINPUT=66

pass_count=0
fail_count=0
failed_names=()

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-memory-test.XXXXXX") || exit 1
tmp_root=$(cd "$tmp_root" && pwd -P)

# shellcheck disable=SC2329  # reached through the EXIT trap installed below.
cleanup() {
  # Only ever remove the directory mktemp handed us, never an expanded surprise.
  case "${tmp_root:-}" in
    */agent-memory-test.*) rm -rf "$tmp_root" ;;
  esac
}
trap cleanup EXIT

# Isolate every lookup away from the developer's real memory.
export CLAUDE_CONFIG_DIR="$tmp_root/claude"
export CODEX_HOME="$tmp_root/codex"
unset CLAUDE_CODE_PROJECT_DIR_NAME
mkdir -p "$CLAUDE_CONFIG_DIR/projects"

stderr_file="$tmp_root/.stderr"

# ---------------------------------------------------------------- helpers

pass() {
  pass_count=$((pass_count + 1))
  printf '  ok   %s\n' "$1"
}

failx() {
  fail_count=$((fail_count + 1))
  failed_names[${#failed_names[@]}]=$1
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
  return 0
}

section() { printf '\n%s\n' "$1"; }

run_am() {
  am_stdout=$("$agent_memory" "$@" 2>"$stderr_file")
  am_status=$?
  am_stderr=$(cat "$stderr_file")
}

expect_status() {
  if [ "$am_status" -eq "$2" ]; then
    pass "$1"
  else
    failx "$1" "expected exit $2, got $am_status; stderr: $am_stderr"
  fi
}

expect_stdout_has() {
  case "$am_stdout" in
    *"$2"*) pass "$1" ;;
    *) failx "$1" "stdout lacked '$2'; got: $am_stdout" ;;
  esac
}

expect_stdout_lacks() {
  case "$am_stdout" in
    *"$2"*) failx "$1" "stdout unexpectedly contained '$2'" ;;
    *) pass "$1" ;;
  esac
}

expect_stderr_has() {
  case "$am_stderr" in
    *"$2"*) pass "$1" ;;
    *) failx "$1" "stderr lacked '$2'; got: $am_stderr" ;;
  esac
}

expect_line_count() {
  actual_lines=$(printf '%s' "$am_stdout" | grep -c '' 2>/dev/null)
  [ -z "$am_stdout" ] && actual_lines=0
  if [ "$actual_lines" -eq "$2" ]; then
    pass "$1"
  else
    failx "$1" "expected $2 line(s), got $actual_lines"
  fi
}

# expect_jq NAME FILTER EXPECTED -- asserts jq over the first stdout line.
expect_jq() {
  jq_actual=$(printf '%s' "$am_stdout" | head -1 | jq -r "$2" 2>&1)
  if [ "$jq_actual" = "$3" ]; then
    pass "$1"
  else
    failx "$1" "jq '$2' expected '$3', got '$jq_actual'"
  fi
}

slug_of() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

memory_dir_for() {
  printf '%s/projects/%s/memory' "$CLAUDE_CONFIG_DIR" "$(slug_of "$1")"
}

# new_project PATH -- creates the project dir plus its memory dir, echoes memory dir.
new_project() {
  mkdir -p "$1"
  new_project_root=$(cd "$1" && pwd -P)
  new_project_memory=$(memory_dir_for "$new_project_root")
  mkdir -p "$new_project_memory"
  printf '%s' "$new_project_memory"
}

# ---------------------------------------------------------------- fixtures

alpha_root="$tmp_root/alpha"
alpha_memory=$(new_project "$alpha_root")

cat > "$alpha_memory/project_alpha.md" <<'FIXTURE_EOF'
# Alpha

- the quick brown fox jumps over the lazy dog
- MixedCase Sentinel lives here
- api token: supersecretvalue123
- contact: someone@example.com
- 見積もりは 300万円 だった
FIXTURE_EOF

cat > "$alpha_memory/reference_lookup_notes.md" <<'FIXTURE_EOF'
# Lookup notes

- unique_marker_in_reference
FIXTURE_EOF

cat > "$alpha_memory/credentials.md" <<'FIXTURE_EOF'
# Credentials

- only_inside_credentials_file
FIXTURE_EOF

ln -s "$alpha_memory/project_alpha.md" "$alpha_memory/symlinked_note.md"

# Filename screening used to be a regex plus a hardcoded case statement. The two
# were folded into one regex; these two fixtures cover what only the case
# statement caught before -- a substring match and an uppercase name.
printf '%s\n' '- inside_substring_credential_file' > "$alpha_memory/mycredentialsdump.md"
printf '%s\n' '- inside_uppercase_sensitive_file' > "$alpha_memory/PRIVATE_KEY_NOTES.md"

beta_root="$tmp_root/beta"
beta_memory=$(new_project "$beta_root")
printf '# Beta\n\n- beta_only_marker\n' > "$beta_memory/project_beta.md"

empty_root="$tmp_root/empty"
mkdir -p "$empty_root"

cd "$repo_root" || exit 1

# ---------------------------------------------------------------- dispatch

section 'dispatch'

run_am
expect_status 'no args exits EX_USAGE' "$EX_USAGE"
expect_stdout_has 'no args prints usage' 'Usage:'

run_am --help
expect_status '--help exits 0' "$EX_OK"

run_am help
expect_status 'help subcommand exits 0' "$EX_OK"

run_am definitely-not-a-command
expect_status 'unknown command exits EX_USAGE' "$EX_USAGE"
expect_stderr_has 'unknown command is reported' 'unknown command'

# ---------------------------------------------------------------- resolve

section 'resolve'

run_am resolve -C "$alpha_root"
expect_status 'resolve finds project memory' "$EX_OK"
expect_line_count 'resolve emits one source' 1
expect_jq 'resolve reports claude source' '.source' 'claude'
expect_jq 'resolve reports cwd relation' '.relation' 'cwd-logical'
expect_jq 'resolve reports the memory dir' '.dir' "$alpha_memory"

run_am resolve -C "$empty_root"
expect_status 'resolve without memory exits EX_NOINPUT' "$EX_NOINPUT"
expect_stderr_has 'resolve explains the miss' 'no Claude project memory found'

run_am resolve -C "$tmp_root/does-not-exist"
expect_status 'resolve on a missing dir exits EX_NOINPUT' "$EX_NOINPUT"

run_am resolve -C
expect_status 'resolve -C without a value exits EX_USAGE' "$EX_USAGE"

run_am resolve --bogus
expect_status 'resolve rejects unknown options' "$EX_USAGE"

# resolve from a subdirectory of a git repo reaches the repo-root memory.
git_root="$tmp_root/gitproj"
git_memory=$(new_project "$git_root")
printf '# Git\n\n- git_root_marker\n' > "$git_memory/project_git.md"
git -C "$git_root" init -q 2>/dev/null
mkdir -p "$git_root/nested/deeper"

run_am resolve -C "$git_root/nested/deeper"
expect_status 'resolve walks up to the git root' "$EX_OK"
expect_jq 'resolve labels the git-root relation' '.relation' 'git-root'
expect_jq 'resolve returns the git-root memory' '.dir' "$git_memory"

# ---------------------------------------------------------------- search

section 'search'

run_am search -C "$alpha_root" -- 'quick brown fox'
expect_status 'search finds content' "$EX_OK"
expect_jq 'content hit is labelled' '.kind' 'content'
expect_jq 'content hit carries the file' '.file' "$alpha_memory/project_alpha.md"
expect_jq 'content hit carries a line number' '.line' '3'

run_am search -C "$alpha_root" -- 'lookup'
expect_status 'search matches filenames too' "$EX_OK"
expect_stdout_has 'filename hit is labelled' '"kind":"filename"'

run_am search -C "$alpha_root" -- 'string_that_appears_nowhere'
expect_status 'search without matches exits 1' "$EX_NOMATCH"

run_am search -C "$alpha_root" -- 'MIXEDCASE SENTINEL'
expect_status 'search is smart-case for lowercase-insensitive input' "$EX_NOMATCH"

run_am search -C "$alpha_root" -- 'mixedcase sentinel'
expect_status 'search matches case-insensitively when the query is lowercase' "$EX_OK"

run_am search -C "$beta_root" -- 'beta_only_marker'
expect_status 'search is scoped to the resolved project' "$EX_OK"

run_am search -C "$alpha_root" -- 'beta_only_marker'
expect_status 'search does not leak across projects by default' "$EX_NOMATCH"

run_am search --all-projects -- 'beta_only_marker'
expect_status '--all-projects widens the search' "$EX_OK"
expect_jq '--all-projects labels the relation' '.relation' 'all-projects'

run_am search -C "$alpha_root" --limit 1 -- 'a'
expect_status 'search honours --limit' "$EX_OK"
expect_line_count '--limit caps the output' 1
expect_stderr_has '--limit reports truncation' 'output truncated'

# ---------------------------------------------------------------- argument validation

section 'argument validation'

run_am search -C "$alpha_root" --
expect_status 'search without a literal exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" -- one two
expect_status 'search with two literals exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" -- ''
expect_status 'search with an empty literal exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" --limit 0 -- 'fox'
expect_status '--limit 0 exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" --limit 201 -- 'fox'
expect_status '--limit 201 exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" --limit abc -- 'fox'
expect_status '--limit abc exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" --limit -- 'fox'
expect_status '--limit swallowing -- exits EX_USAGE' "$EX_USAGE"

run_am search --all-projects --all-sources -- 'fox'
expect_status 'combining --all-projects and --all-sources exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" --all-projects -- 'fox'
expect_status 'combining -C and --all-projects exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" --all-sources -- 'fox'
expect_status 'combining -C and --all-sources exits EX_USAGE' "$EX_USAGE"

run_am search -C "$alpha_root" 'fox'
expect_status 'a literal before -- exits EX_USAGE' "$EX_USAGE"

# ---------------------------------------------------------------- secret handling

section 'secret handling'

run_am search -C "$alpha_root" -- 'password: hunter2example'
expect_status 'a secret-shaped query is refused' "$EX_DATAERR"
expect_stderr_has 'the refusal explains itself' 'resembles a secret'

run_am search -C "$alpha_root" -- 'AKIAABCDEFGHIJKLMNOP'
expect_status 'an AWS-key-shaped query is refused' "$EX_DATAERR"

run_am search -C "$alpha_root" -- 'supersecretvalue123'
expect_status 'a secret-bearing line is still searchable' "$EX_OK"
expect_stdout_has 'a secret-bearing line is redacted' 'REDACTED: potential secret'
expect_stdout_lacks 'the secret value never reaches stdout' 'supersecretvalue123'

run_am search -C "$alpha_root" -- 'example.com'
expect_status 'an email-bearing line is still searchable' "$EX_OK"
expect_stdout_has 'an email-bearing line is redacted' 'REDACTED: potential secret'

run_am search -C "$alpha_root" -- '300'
expect_status 'a money-bearing line is still searchable' "$EX_OK"
expect_stdout_has 'a money-bearing line is redacted' 'REDACTED: potential secret'

run_am search -C "$alpha_root" -- 'only_inside_credentials_file'
expect_status 'a credentials-named file is excluded from search' "$EX_NOMATCH"

run_am search -C "$alpha_root" -- 'inside_substring_credential_file'
expect_status 'a sensitive filename is caught without word boundaries' "$EX_NOMATCH"

run_am search -C "$alpha_root" -- 'inside_uppercase_sensitive_file'
expect_status 'a sensitive filename is caught regardless of case' "$EX_NOMATCH"

run_am search -C "$alpha_root" -- 'the quick brown fox'
expect_stdout_lacks 'symlinked memory files are skipped' 'symlinked_note.md'

# ---------------------------------------------------------------- path hardening

section 'path hardening'

run_am search -C "$alpha_root" -- "$(printf 'a\nb')"
expect_status 'a query with a newline is refused' "$EX_DATAERR"
expect_stderr_has 'the control-character refusal explains itself' 'control character'

# This fixture gets its own config root on purpose. A rejected memory directory
# is fail-closed, so leaving it in the shared root would abort every later
# --all-projects sweep -- which is exactly what the last case here pins down.
symlink_config="$tmp_root/claude-symlink"
symlink_root="$tmp_root/symlinked"
mkdir -p "$symlink_root" "$tmp_root/elsewhere-memory"
symlink_memory="$symlink_config/projects/$(slug_of "$(cd "$symlink_root" && pwd -P)")/memory"
mkdir -p "$(dirname "$symlink_memory")"
ln -s "$tmp_root/elsewhere-memory" "$symlink_memory"

CLAUDE_CONFIG_DIR="$symlink_config" run_am resolve -C "$symlink_root"
expect_status 'a symlinked memory dir is refused' "$EX_DATAERR"
expect_stderr_has 'the symlink refusal explains itself' 'symlinked memory directory'

expect_stderr_has 'the symlink refusal names the offending path' "$symlink_memory"

CLAUDE_CONFIG_DIR="$symlink_config" run_am search --all-projects -- 'anything'
expect_status 'one symlinked memory dir fails the whole --all-projects sweep' "$EX_DATAERR"
expect_stderr_has 'the sweep failure names the offending path' "$symlink_memory"

# A logical path and its physical target that collapse to the same project key
# must be refused rather than silently resolved to one of them.
mkdir -p "$tmp_root/collide/inner"
ln -s "$tmp_root/collide/inner" "$tmp_root/collide-inner"
collide_memory=$(memory_dir_for "$tmp_root/collide/inner")
mkdir -p "$collide_memory"

cd "$tmp_root/collide-inner" || exit 1
run_am resolve
collide_status=$am_status
collide_stderr=$am_stderr
cd "$repo_root" || exit 1

if [ "$collide_status" -eq "$EX_DATAERR" ]; then
  pass 'a project-key collision is refused'
else
  failx 'a project-key collision is refused' "expected exit $EX_DATAERR, got $collide_status; stderr: $collide_stderr"
fi
case "$collide_stderr" in
  *collision*) pass 'the collision refusal explains itself' ;;
  *) failx 'the collision refusal explains itself' "stderr: $collide_stderr" ;;
esac
case "$collide_stderr" in
  *"$tmp_root/collide/inner"*) pass 'the collision refusal names both paths' ;;
  *) failx 'the collision refusal names both paths' "stderr: $collide_stderr" ;;
esac

# ---------------------------------------------------------------- env fallback

section 'CLAUDE_CODE_PROJECT_DIR_NAME fallback'

alpha_slug=$(slug_of "$alpha_root")

cd "$empty_root" || exit 1
CLAUDE_CODE_PROJECT_DIR_NAME="$alpha_slug" run_am resolve
expect_status 'the env fallback resolves when nothing else matches' "$EX_OK"
expect_jq 'the env fallback is labelled' '.relation' 'project-dir-name'

CLAUDE_CODE_PROJECT_DIR_NAME='a/b' run_am resolve
expect_status 'the env fallback rejects a nested name' "$EX_DATAERR"

CLAUDE_CODE_PROJECT_DIR_NAME='..' run_am resolve
expect_status 'the env fallback rejects ..' "$EX_DATAERR"
cd "$repo_root" || exit 1

CLAUDE_CODE_PROJECT_DIR_NAME="$alpha_slug" run_am resolve -C "$empty_root"
expect_status 'an explicit -C suppresses the env fallback' "$EX_NOINPUT"

# ---------------------------------------------------------------- codex sources

section 'codex sources'

mkdir -p "$CODEX_HOME/memories"
printf '# Codex\n\n- codex_feed_marker\n' > "$CODEX_HOME/memories/MEMORY.md"
printf '%s\n' '- stray_sidecar_marker' > "$CODEX_HOME/memories/unrelated.md"

run_am search --all-sources -- 'codex_feed_marker'
expect_status '--all-sources reaches the codex feed' "$EX_OK"
expect_jq 'the codex feed is labelled as codex' '.source' 'codex'
expect_jq 'the codex relation is reported' '.relation' 'codex-consolidated'

run_am search --all-sources -- 'stray_sidecar_marker'
expect_status 'the codex feed reads only its two known files' "$EX_NOMATCH"

run_am search --all-projects -- 'codex_feed_marker'
expect_status '--all-projects excludes the codex feed' "$EX_NOMATCH"

# ---------------------------------------------------------------- configurable redaction

section 'configurable redaction'

AGENT_MEMORY_SENSITIVE_PATTERN='AKIA[0-9A-Z]{16}' run_am search -C "$alpha_root" -- '300'
expect_status 'a narrowed pattern still searches' "$EX_OK"
expect_stdout_has 'a narrowed pattern lets the money line through' '300'
expect_stdout_lacks 'a narrowed pattern stops redacting' 'REDACTED'

AGENT_MEMORY_SENSITIVE_FILENAME_PATTERN='matches-no-real-filename' \
  run_am search -C "$alpha_root" -- 'only_inside_credentials_file'
expect_status 'a narrowed filename pattern exposes the skipped file' "$EX_OK"

AGENT_MEMORY_SENSITIVE_PATTERN='' run_am search -C "$alpha_root" -- 'fox'
expect_status 'an empty pattern is refused' "$EX_USAGE"
expect_stderr_has 'the empty-pattern refusal explains itself' 'must not be empty'

AGENT_MEMORY_SENSITIVE_FILENAME_PATTERN='' run_am search -C "$alpha_root" -- 'fox'
expect_status 'an empty filename pattern is refused' "$EX_USAGE"

AGENT_MEMORY_SENSITIVE_PATTERN='[unclosed' run_am search -C "$alpha_root" -- 'fox'
expect_status 'a malformed pattern is refused' "$EX_USAGE"
expect_stderr_has 'the malformed-pattern refusal names the engine' 'not a valid'

AGENT_MEMORY_SENSITIVE_PATTERN='AKIA[0-9A-Z]{16}' run_am resolve -C "$alpha_root"
expect_status 'resolve ignores the redaction pattern entirely' "$EX_OK"

# ---------------------------------------------------------------- read-only guarantee

section 'read-only guarantee'

fixture_digest_before=$(find "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" -type f -exec shasum {} \; | sort | shasum)
run_am search --all-sources -- 'fox'
run_am resolve -C "$alpha_root"
fixture_digest_after=$(find "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" -type f -exec shasum {} \; | sort | shasum)

if [ "$fixture_digest_before" = "$fixture_digest_after" ]; then
  pass 'searching never mutates the memory corpus'
else
  failx 'searching never mutates the memory corpus' 'fixture digest changed'
fi

# ---------------------------------------------------------------- summary

printf '\n----------------------------------------\n'
printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -gt 0 ]; then
  printf '\nfailed cases:\n'
  failed_index=0
  while [ "$failed_index" -lt "${#failed_names[@]}" ]; do
    printf '  - %s\n' "${failed_names[$failed_index]}"
    failed_index=$((failed_index + 1))
  done
  exit 1
fi
exit 0
