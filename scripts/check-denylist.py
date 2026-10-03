#!/usr/bin/env python3
"""Stop words that belong on this machine only from reaching a commit or a push.

The repository is public while the clone sits next to private notes; what slips
through is a name, a local path or a working term copied into a comment or a
commit message. Patterns come from local.denylist (one Python regex per line,
case-insensitive, '#' starts a comment), which is git-ignored and never leaves
this machine. Without that file (another clone, a CI runner) nothing is checked.

  --staged  added lines of the index (pre-commit)
  default   added lines and messages of commits not on any remote (pre-push)

Only the commit, file and matching pattern are printed, never the line itself.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def patterns(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            out.append((re.compile(line, re.IGNORECASE), line))
    return out


def added(log):
    """`git log -p` / `git diff` text -> (commit, file, text) for added lines and message lines."""
    commit, path, in_message = '(staged)', None, False
    for line in log.splitlines():
        m = re.match(r'commit ([0-9a-f]{7,64})$', line)
        if m:
            commit, path, in_message = m.group(1)[:7], None, True
        elif line.startswith('diff --git '):
            in_message, path = False, re.sub(r'^diff --git a/.* b/', '', line)
        elif in_message and line.startswith('    '):
            yield commit, '(commit message)', line[4:]
        elif not in_message and line.startswith('+') and not line.startswith('+++'):
            yield commit, path, line[1:]


def git(*args):
    return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def main():
    denylist = ROOT / 'local.denylist'
    pats = patterns(denylist.read_text(encoding='utf-8')) if denylist.is_file() else []
    if not pats:
        return 0
    if '--staged' in sys.argv[1:]:
        log = git('diff', '--cached', '--no-color', '--no-ext-diff', '-U0')
    else:
        log = git('log', 'HEAD', '--branches', '--not', '--remotes', '-p', '--no-color', '--no-ext-diff',
                  '--format=commit %H%n%n%w(0,4,4)%B')
    hits = [(c, f, label) for c, f, text in added(log) for rx, label in pats if rx.search(text)]
    for commit, path, label in hits:
        print(f'denylist: {commit} {path}: matches {label}', file=sys.stderr)
    if hits:
        print('Stopped: local-only words in the changes above (local.denylist). '
              'Rewrite them, or bypass with --no-verify if intended.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, re.error, subprocess.SubprocessError) as exc:
        print(f'Denylist check failed: {type(exc).__name__}', file=sys.stderr)
        sys.exit(1)
