# agent-memory

[![ci](https://github.com/seirou-iwamoto/agent-memory/actions/workflows/ci.yml/badge.svg)](https://github.com/seirou-iwamoto/agent-memory/actions/workflows/ci.yml)

Read Claude Code's project memory from the command line, so that any agent —
Claude Code, Codex, or your own tooling — searches the same corpus instead of
keeping a private copy of it.

```console
$ agent-memory resolve
{"source":"claude","relation":"cwd-logical","dir":"/Users/you/.claude/projects/-Users-you-myrepo/memory"}

$ agent-memory search -- 'deploy pipeline'
{"source":"claude","relation":"cwd-logical","file":".../memory/project_deploy.md","line":12,"text":"- the deploy pipeline runs on tags only","kind":"content"}
```

## Why

Claude Code writes durable per-project memory to
`~/.claude/projects/<project-key>/memory/*.md`, but ships no way to read it from
outside the session. The obvious workaround — copying those files somewhere a
second agent can see — is the thing you actually want to avoid: once copied, the
same fact exists at two versions and the stale one wins about half the time.

`agent-memory` resolves the live directory on every invocation and greps it in
place. It has no cache, no write path, and no sync. The corpus that Claude Code
maintains stays the single source of truth; this tool is only a reader.

## Install

```sh
git clone https://github.com/seirou-iwamoto/agent-memory.git
mkdir -p ~/.local/bin
ln -s "$PWD/agent-memory/bin/agent-memory" ~/.local/bin/agent-memory
```

`~/.local/bin` has to be on your `PATH` for the last step to be useful; add it in
your shell's rc file if it isn't already. Any other directory on `PATH` works
just as well — nothing in the script cares where it is linked from.

Requires `bash` (3.2 is fine — it targets the macOS default), plus `git`,
[`rg`](https://github.com/BurntSushi/ripgrep) and `jq` on `PATH`. No particular
Git version is needed: `rev-parse --path-format` is used when available and the
relative form is absolutised by hand otherwise.

## Usage

```
agent-memory resolve [-C DIR]
agent-memory search [-C DIR] [--all-projects|--all-sources] [--limit N] -- LITERAL
```

`resolve` prints the memory directories that apply to a directory, as JSON
Lines. `search` prints matches from those directories, also as JSON Lines.

`LITERAL` is always a fixed string, never a regex.

### How a directory resolves to a memory directory

Four candidate roots are derived from the working directory and tried in order:

| relation | source |
|---|---|
| `cwd-logical` | `pwd -L` |
| `cwd-physical` | `pwd -P` |
| `git-root` | `git rev-parse --show-toplevel` |
| `git-common-root` | the parent of `git rev-parse --git-common-dir` |

Each is converted to a project key by replacing every non-alphanumeric character
with `-`, and kept if `~/.claude/projects/<key>/memory` exists. The
`git-common-root` entry is what lets a worktree reach the memory of its parent
repository.

If nothing matches and `-C` was not given, `$CLAUDE_CODE_PROJECT_DIR_NAME` is
used as a last resort. If that fails too, the command exits `66`.

### Widening the search

By default only the current project's memory is read. Two flags widen that, and
they are mutually exclusive with each other and with `-C`:

- `--all-projects` — every Claude project memory directory.
- `--all-sources` — the above, plus Codex's consolidated memory
  (`$CODEX_HOME/memories/MEMORY.md` and `memory_summary.md`) and Computer
  History summaries.

`--all-sources` works with no Claude memory at all: a machine that only has the
Codex feed still searches it. `--all-projects` keeps the stricter contract and
fails when no Claude project memory exists.

The extra sources in `--all-sources` are labelled `"source":"codex"` in the
output. Treat them as a recent feed rather than durable truth: they are a
by-product of another agent's session, not a curated corpus.

### Output

One JSON object per line. `search` emits:

| field | meaning |
|---|---|
| `source` | `claude` or `codex` |
| `relation` | which candidate root produced this source |
| `file` | absolute path of the matching file |
| `line` | line number, or `null` for a filename match |
| `text` | the matching line (truncated to 400 characters), or the filename |
| `kind` | `content` or `filename` |

`--limit` takes a plain decimal from 1 to 200 with no leading zeros — `010` is
rejected rather than quietly read as octal 8.

Exit codes follow `sysexits.h`: `0` success, `1` no matches, `64` usage error,
`65` malformed data, `66` nothing to read, `69` a missing dependency, `74` I/O
failure.

## What the redaction does and does not do

Lines that look like they carry a secret are replaced with
`[REDACTED: potential secret]` before being printed, files whose *names* look
sensitive are skipped entirely, and a query that itself resembles a secret is
refused outright.

**This is spill control, not access control.** The file path and line number of
a redacted match are still printed, and anyone who can run this command can also
`sed -n '12p'` the file. The point is to keep secrets out of agent transcripts,
logs and scrollback — places where text tends to be copied onward — not to
protect the files from their owner.

The default pattern is deliberately broad. It treats email addresses and
currency amounts as sensitive, which means a search for `invoice` may come back
as a column of redactions. That is the intended trade-off for the author's use;
if it is wrong for yours, override it from the environment:

```sh
# Narrow redaction down to credential shapes only.
export AGENT_MEMORY_SENSITIVE_PATTERN='AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}'
```

`AGENT_MEMORY_SENSITIVE_FILENAME_PATTERN` overrides the filename screen the same
way. Both are validated before a search runs: an empty value is refused (it would
redact every line rather than none), and so is anything the engines cannot parse.
`resolve` does not read either pattern and so never validates them.

The content pattern is read by **both** `rg` (Rust regex) and `jq` (Oniguruma) —
rg selects the lines, jq redacts the preview — so it has to be valid in both
dialects. The check tests it against each and names the one that rejected it.

The filename pattern is read by `rg` alone, so only rg's dialect applies to it;
`(?:...)` and `\w` work there and are accepted. That single-engine rule is
deliberate. The pattern was once evaluated by three engines, and agreeing on
syntax is not the same as agreeing on meaning: `\w+` compiles everywhere but
means nothing to bash 3.2's POSIX ERE, so a name the pattern was meant to hide
came back in the output. One engine decides, and what rg matches is what gets
screened.

`RIPGREP_CONFIG_PATH` is unset before any of this runs. A caller's ripgrep
configuration could otherwise change the output format the screening reads, and
a single `--line-number` in that file was enough to let a screened file through.

## Fail-closed behaviour

The tool stops rather than guessing when the corpus looks wrong:

- `~/.claude/projects` itself is resolved to a physical path and trusted as the
  root, but **no component below it may be a symlink** — not the project
  directory, not `memory`. A symlinked component could point at another project's
  memory, or outside the root entirely
- a dangling `memory` symlink is refused rather than skipped, so it cannot quietly
  drop one project out of a sweep
- a memory directory that resolves outside the projects root is refused
- two different paths that collapse to the same project key are refused as
  ambiguous, and the error names both paths
- paths and queries containing any C0 control character or DEL are refused. This
  also keeps escape sequences out of the diagnostics this tool prints

One consequence is worth stating plainly: a single symlinked memory directory
makes `--all-projects` fail for the whole sweep, not just for that project.
This is intentional — a partial result that silently omits a project is worse
than an error — but it does mean one bad directory blocks the wide search until
you remove it.

## The fragile joint

The project-key derivation above is not a documented Claude Code interface. It
was determined by observation and matches every directory in the author's
installation, but nothing stops Claude Code from changing it. If that happens,
this tool will not silently return wrong results — it will fail to resolve and
exit `66`. That is the failure mode to expect, and `resolve` is the command to
run when diagnosing it.

## Tests

```sh
./tests/run.sh
```

138 cases in plain bash, no test framework. Every case runs against a fixture
under `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, so the suite never reads or writes real
memory.

CI runs the suite and `shellcheck` on both Linux and macOS. The macOS leg is the
one that matters: `/bin/bash` there is 3.2, which is the interpreter this script
actually targets.

## License

MIT
