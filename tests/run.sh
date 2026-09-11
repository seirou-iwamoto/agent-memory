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

# shellcheck disable=SC2329,SC2317  # reached through the EXIT trap installed below.
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
# The redaction overrides are part of the tool's public surface, so a developer may
# well have them exported. Leaving them set silently reshapes the secret-handling
# expectations below; the suite must supply its own values, never inherit them.
unset AGENT_MEMORY_SENSITIVE_PATTERN
unset AGENT_MEMORY_SENSITIVE_FILENAME_PATTERN
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

expect_stderr_lacks() {
  case "$am_stderr" in
    *"$2"*) failx "$1" "stderr unexpectedly contained '$2'" ;;
    *) pass "$1" ;;
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
# Assert the search actually succeeded first: a wholesale failure also produces
# stdout without that filename in it, which would pass the check below for free.
expect_status 'the symlink-skip case really searched' "$EX_OK"
expect_stdout_has 'the symlink-skip case found the real file' 'project_alpha.md'
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
  *"$tmp_root/collide/inner"*) pass 'the collision refusal names the physical path' ;;
  *) failx 'the collision refusal names the physical path' "stderr: $collide_stderr" ;;
esac
case "$collide_stderr" in
  *"$tmp_root/collide-inner"*) pass 'the collision refusal names the logical path too' ;;
  *) failx 'the collision refusal names the logical path too' "stderr: $collide_stderr" ;;
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
expect_status 'resolve never reads the redaction pattern' "$EX_OK"

# ---------------------------------------------------------------- regression cases
#
# Everything below pins a defect found in review on 2026-09-12. Each case failed
# before the corresponding fix and states the behaviour that must not come back.

section 'regression: --limit is parsed as decimal'

run_am search -C "$alpha_root" --limit 010 -- 'a'
expect_status 'a leading-zero limit is refused rather than read as octal' "$EX_USAGE"

run_am search -C "$alpha_root" --limit 08 -- 'a'
expect_status 'a leading-zero limit outside octal is refused too' "$EX_USAGE"
expect_stderr_lacks 'no arithmetic error leaks out of the limit check' 'value too great'

run_am search -C "$alpha_root" --limit 18446744073709551616 -- 'a'
expect_status 'a limit past the integer range is refused' "$EX_USAGE"
expect_stderr_lacks 'no integer-expression error leaks out' 'integer expression expected'

run_am search -C "$alpha_root" --limit 200 -- 'a'
expect_status 'the documented maximum is still accepted' "$EX_OK"

section 'regression: every control character is refused'

run_am search -C "$alpha_root" -- "$(printf 'a\033b')"
expect_status 'an ESC in the query is refused' "$EX_DATAERR"

run_am search -C "$alpha_root" -- "$(printf 'a\177b')"
expect_status 'a DEL in the query is refused' "$EX_DATAERR"

run_am resolve -C "$(printf '%s/missing\033[31m' "$tmp_root")"
expect_status 'an ESC in a path is refused' "$EX_DATAERR"
case "$am_stderr" in
  *$'\033'*) failx 'no raw escape sequence reaches stderr' 'stderr carried a raw ESC' ;;
  *) pass 'no raw escape sequence reaches stderr' ;;
esac

section 'regression: cd is hardened'

mkdir -p "$tmp_root/cdpath-trap/alpha"
cd "$tmp_root" || exit 1
CDPATH="$tmp_root/cdpath-trap" run_am resolve -C alpha
cd "$repo_root" || exit 1
expect_status 'a relative -C ignores CDPATH' "$EX_OK"
expect_jq 'a relative -C resolves against the working directory' '.dir' "$alpha_memory"

dashp_memory=$(new_project "$tmp_root/-P")
printf '%s\n' '- inside_option_like_directory' > "$dashp_memory/note.md"
cd "$tmp_root" || exit 1
run_am resolve -C -P
cd "$repo_root" || exit 1
expect_status 'a directory named like a cd option still resolves' "$EX_OK"
expect_jq 'the option-like directory resolves to its own memory' '.dir' "$dashp_memory"

section 'regression: one engine decides whether a filename is sensitive'

# The filename screen used to be evaluated by bash [[ =~ ]] and by jq as well as rg.
# Three engines agreeing on syntax does not make them agree on meaning, and whenever
# they disagreed a name meant to be hidden was emitted. rg is now the only judge, so
# both of these patterns have to behave exactly as rg reads them.

# rg accepts this; bash ERE does not. It must screen the file, not be rejected.
AGENT_MEMORY_SENSITIVE_FILENAME_PATTERN='(?:credential)' \
  run_am search -C "$alpha_root" -- 'only_inside_credentials_file'
expect_status 'an rg-valid group syntax screens the file' "$EX_NOMATCH"

# \w means "word character" to rg but nothing to bash 3.2's POSIX ERE, where the
# pattern silently failed to match and let every filename through.
AGENT_MEMORY_SENSITIVE_FILENAME_PATTERN='\w+' \
  run_am search -C "$alpha_root" -- 'the quick brown fox'
expect_status 'a pattern matching every name screens every file' "$EX_NOMATCH"

AGENT_MEMORY_SENSITIVE_FILENAME_PATTERN='\w+' \
  run_am search -C "$alpha_root" -- 'project_alpha'
expect_status 'not even a filename hit survives that pattern' "$EX_NOMATCH"
expect_stdout_lacks 'no path leaks through the filename screen' 'project_alpha.md'

section 'regression: symlinks are refused at every component'

symlink_component_config="$tmp_root/claude-symlink-component"
symlink_component_root="$tmp_root/symlink-component"
mkdir -p "$symlink_component_root" "$symlink_component_config/projects/real/memory"
printf '%s\n' '- reached_through_symlinked_project' > "$symlink_component_config/projects/real/memory/n.md"
component_slug=$(slug_of "$(cd "$symlink_component_root" && pwd -P)")
ln -s "$symlink_component_config/projects/real" "$symlink_component_config/projects/$component_slug"

CLAUDE_CONFIG_DIR="$symlink_component_config" run_am resolve -C "$symlink_component_root"
expect_status 'a symlinked project component is refused' "$EX_DATAERR"
expect_stderr_has 'the refusal names the component' 'symlinked project directory'

dangling_config="$tmp_root/claude-dangling"
mkdir -p "$dangling_config/projects/ok/memory" "$dangling_config/projects/broken"
printf '%s\n' '- healthy_entry' > "$dangling_config/projects/ok/memory/n.md"
ln -s "$tmp_root/does-not-exist-at-all" "$dangling_config/projects/broken/memory"

CLAUDE_CONFIG_DIR="$dangling_config" run_am search --all-projects -- 'healthy_entry'
expect_status 'a dangling memory symlink stops the whole sweep' "$EX_DATAERR"
expect_stdout_lacks 'the sweep returns no partial result' 'healthy_entry'

# A project symlink that cannot be followed all the way to memory never appears in a
# */memory glob, so checking only the glob results let the sweep return a partial
# answer with exit 0. Project entries are enumerated and checked on their own now.
broken_project_config="$tmp_root/claude-broken-project"
mkdir -p "$broken_project_config/projects/ok/memory" "$broken_project_config/target-without-memory"
printf '%s\n' '- healthy_entry' > "$broken_project_config/projects/ok/memory/n.md"
ln -s "$tmp_root/no-such-target-at-all" "$broken_project_config/projects/dangling-project"

CLAUDE_CONFIG_DIR="$broken_project_config" run_am search --all-projects -- 'healthy_entry'
expect_status 'a dangling project symlink stops the whole sweep' "$EX_DATAERR"
expect_stderr_has 'the refusal names the project directory' 'symlinked project directory'
expect_stdout_lacks 'no partial result survives a dangling project symlink' 'healthy_entry'

rm "$broken_project_config/projects/dangling-project"
ln -s "$broken_project_config/target-without-memory" "$broken_project_config/projects/memoryless-project"

CLAUDE_CONFIG_DIR="$broken_project_config" run_am search --all-projects -- 'healthy_entry'
expect_status 'a project symlink whose target lacks memory stops the sweep too' "$EX_DATAERR"
expect_stdout_lacks 'no partial result survives a memory-less project symlink' 'healthy_entry'

section 'regression: --all-sources reaches Codex without Claude'

codex_only_claude="$tmp_root/claude-empty"
codex_only_home="$tmp_root/codex-only"
mkdir -p "$codex_only_claude/projects" "$codex_only_home/memories" "$tmp_root/codex-only-cwd"
printf '%s\n' '- codex_only_marker' > "$codex_only_home/memories/MEMORY.md"

CLAUDE_CONFIG_DIR="$codex_only_claude" CODEX_HOME="$codex_only_home" \
  run_am search --all-sources -C "$tmp_root/codex-only-cwd" -- 'codex_only_marker'
expect_status 'combining -C with --all-sources is still refused' "$EX_USAGE"

cd "$tmp_root/codex-only-cwd" || exit 1
CLAUDE_CONFIG_DIR="$codex_only_claude" CODEX_HOME="$codex_only_home" \
  run_am search --all-sources -- 'codex_only_marker'
cd "$repo_root" || exit 1
expect_status 'Codex is searched even with zero Claude projects' "$EX_OK"
expect_jq 'the Codex-only hit is labelled as codex' '.source' 'codex'

empty_both_claude="$tmp_root/claude-none"
empty_both_home="$tmp_root/codex-none"
mkdir -p "$empty_both_claude/projects" "$empty_both_home" "$tmp_root/empty-both-cwd"
cd "$tmp_root/empty-both-cwd" || exit 1
CLAUDE_CONFIG_DIR="$empty_both_claude" CODEX_HOME="$empty_both_home" \
  run_am search --all-sources -- 'anything'
cd "$repo_root" || exit 1
expect_status 'no sources at all is still EX_NOINPUT' "$EX_NOINPUT"

section 'regression: a worktree reaches its parent repository'

# git-common-root is the only candidate that covers this, and it needs a real
# worktree to exercise -- the suite had no coverage for it before.
wt_parent="$tmp_root/wtparent"
mkdir -p "$wt_parent"
git -C "$wt_parent" init -q
git -C "$wt_parent" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
wt_parent_memory=$(new_project "$wt_parent")
printf '%s\n' '- parent_repo_marker' > "$wt_parent_memory/project_parent.md"
git -C "$wt_parent" worktree add -q "$tmp_root/wtchild" -b regression-probe

run_am resolve -C "$tmp_root/wtchild"
expect_status 'a worktree resolves' "$EX_OK"
expect_jq 'a worktree reaches the parent repository memory' '.dir' "$wt_parent_memory"
expect_jq 'the worktree candidate is labelled git-common-root' '.relation' 'git-common-root'

run_am search -C "$tmp_root/wtchild" -- 'parent_repo_marker'
expect_status 'a worktree searches the parent repository memory' "$EX_OK"

section 'regression: the caller environment cannot bend the screening'

# ripgrep reads arguments from RIPGREP_CONFIG_PATH. A caller with --line-number in
# theirs reshaped the output the filename screening parses, and a screened file came
# back in full. The tool unsets that variable now.
caller_rg_config="$tmp_root/ripgreprc"
printf '%s\n' '--line-number' > "$caller_rg_config"

RIPGREP_CONFIG_PATH="$caller_rg_config" run_am search -C "$alpha_root" -- 'only_inside_credentials_file'
expect_status "a caller's ripgrep config cannot expose a screened file" "$EX_NOMATCH"
expect_stdout_lacks 'no screened path leaks under a caller rg config' 'credentials.md'

RIPGREP_CONFIG_PATH="$caller_rg_config" run_am search -C "$alpha_root" -- 'the quick brown fox'
expect_status 'an ordinary search still works under a caller rg config' "$EX_OK"

section 'regression: project enumeration is complete and sanitised'

enum_config="$tmp_root/claude-enumeration"
enum_cwd="$tmp_root/enumeration-cwd"
mkdir -p "$enum_config/projects/.hidden-project/memory" "$enum_cwd"
printf '%s\n' '- hidden_project_marker' > "$enum_config/projects/.hidden-project/memory/n.md"

cd "$enum_cwd" || exit 1
CLAUDE_CONFIG_DIR="$enum_config" run_am search --all-projects -- 'hidden_project_marker'
cd "$repo_root" || exit 1
expect_status 'a dot-prefixed project is enumerated' "$EX_OK"

ln -s "$tmp_root/nowhere-at-all" "$enum_config/projects/.hidden-symlink"
cd "$enum_cwd" || exit 1
CLAUDE_CONFIG_DIR="$enum_config" run_am search --all-projects -- 'hidden_project_marker'
cd "$repo_root" || exit 1
expect_status 'a dot-prefixed project symlink is checked too' "$EX_DATAERR"
rm "$enum_config/projects/.hidden-symlink"

# The refusal prints the offending path, so it has to be screened for control
# characters first -- otherwise a crafted entry name injects terminal sequences.
esc_project_name=$(printf 'bad\033[31m-project')
ln -s "$tmp_root/nowhere-at-all" "$enum_config/projects/$esc_project_name"
cd "$enum_cwd" || exit 1
CLAUDE_CONFIG_DIR="$enum_config" run_am search --all-projects -- 'hidden_project_marker'
cd "$repo_root" || exit 1
expect_status 'a control character in a project entry name is refused' "$EX_DATAERR"
case "$am_stderr" in
  *$'\033'*) failx 'project enumeration keeps escapes out of stderr' 'stderr carried a raw ESC' ;;
  *) pass 'project enumeration keeps escapes out of stderr' ;;
esac

# ---------------------------------------------------------------- read-only guarantee

section 'read-only guarantee'

# Hash file contents AND the directory listing with each entry's type, so a created,
# deleted, or retyped entry is caught too -- a content-only digest misses all three.
fixture_snapshot() {
  find "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" -type f -exec shasum {} \; | sort
  find "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" -type d -print | sed 's|^|d |' | sort
  find "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" -type l -print | sed 's|^|l |' | sort
  find "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" -type f -print | sed 's|^|f |' | sort
}
fixture_digest_before=$(fixture_snapshot | shasum)
run_am search --all-sources -- 'fox'
expect_status 'the read-only probe search really ran' "$EX_OK"
run_am resolve -C "$alpha_root"
expect_status 'the read-only probe resolve really ran' "$EX_OK"
fixture_digest_after=$(fixture_snapshot | shasum)

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
