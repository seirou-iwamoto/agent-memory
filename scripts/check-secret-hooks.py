#!/usr/bin/env python3
"""Real scanners/hooks; synthetic secrets stay in temporary repositories, never pushed remotely."""
import os
import pathlib
import runpy
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV = {**os.environ, 'GIT_AUTHOR_NAME': 'Hook Test', 'GIT_AUTHOR_EMAIL': 'test@example.invalid',
       'GIT_COMMITTER_NAME': 'Hook Test', 'GIT_COMMITTER_EMAIL': 'test@example.invalid',
       'MISE_TRUSTED_CONFIG_PATHS': str(ROOT)}
# Construct a nonfunctional high-entropy test credential, never store a literal in this repo.
SECRET = 'ghp_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'


def run(repo, *args, expected=0, stdin=None, env=None):
    result = subprocess.run(args, cwd=repo, env=env or ENV, input=stdin,
                            capture_output=True, text=True, timeout=240)
    assert SECRET not in result.stdout + result.stderr, 'Secret appeared in diagnostics'
    assert result.returncode == expected, f'{args[0]}: expected {expected}, got {result.returncode} (output suppressed)'
    return result.stdout.strip()


with tempfile.TemporaryDirectory(prefix='secret-hooks-') as directory:
    repo = pathlib.Path(directory).resolve() / 'repo'
    repo.mkdir()
    # Explicit trust is scoped to our disposable test fixture only.
    ENV['MISE_TRUSTED_CONFIG_PATHS'] = str(repo)
    for name in ('mise.toml', 'lefthook.yml', '.gitleaks.toml'):
        shutil.copyfile(ROOT / name, repo / name)
    (repo / 'scripts').mkdir()
    for name in ('check-push-secrets.py', 'check-denylist.py'):
        shutil.copyfile(ROOT / 'scripts' / name, repo / 'scripts' / name)
    run(repo, 'git', 'init', '-q', '-b', 'main')
    run(repo, 'mise', 'exec', '--', 'lefthook', 'install')
    (repo / 'sample.txt').write_text('clean\n')
    run(repo, 'git', 'add', '.')
    run(repo, 'git', 'commit', '-qm', 'clean')
    base = run(repo, 'git', 'rev-parse', 'HEAD')
    # A clean index must pass even when the working tree contains an unstaged secret.
    (repo / 'sample.txt').write_text(SECRET + '\n')
    run(repo, 'mise', 'exec', '--', 'lefthook', 'run', 'pre-commit')
    run(repo, 'git', 'add', 'sample.txt')
    # Replacing the working copy must not hide a secret already in the index.
    (repo / 'sample.txt').write_text('clean\n')
    run(repo, 'git', 'commit', '-qm', 'must be blocked', expected=1)
    # Seed bad history deliberately in this throwaway fixture to test pre-push.
    run(repo, 'git', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'synthetic secret')
    bad = run(repo, 'git', 'rev-parse', 'HEAD')
    run(repo, 'git', 'add', 'sample.txt')
    run(repo, 'git', 'commit', '-qm', 'remove synthetic secret')
    tip = run(repo, 'git', 'rev-parse', 'HEAD')
    remote = pathlib.Path(directory) / 'remote.git'
    run(repo, 'git', 'init', '--bare', '-q', str(remote))
    run(repo, 'git', 'remote', 'add', 'origin', str(remote))
    run(repo, 'git', 'push', 'origin', f'{base}:refs/heads/main')
    run(repo, 'git', 'push', 'origin', 'main', expected=1)
    run(repo, 'git', 'push', 'origin', f'{tip}:refs/heads/new-branch', expected=1)
    # Current HEAD is clean; push a different secret-bearing ref anyway.
    run(repo, 'git', 'checkout', '-q', '--detach', base)
    run(repo, 'git', 'push', 'origin', f'{bad}:refs/heads/other', expected=1)
    run(repo, 'git', 'tag', '-a', 'bad-tag', bad, '-m', 'test annotated tag')
    run(repo, 'git', 'push', 'origin', 'bad-tag', expected=1)
    # A remote that has never received origin's history: pushing to it scans that history. Seed origin's main with the
    # secret-bearing history first (hooks bypassed, the way a commit made elsewhere would arrive).
    run(repo, 'git', '-c', 'core.hooksPath=/dev/null', 'push', '-q', 'origin', f'{tip}:refs/heads/main', '--force')
    public = pathlib.Path(directory) / 'public.git'
    run(repo, 'git', 'init', '--bare', '-q', str(public))
    run(repo, 'git', 'remote', 'add', 'public', str(public))
    run(repo, 'git', 'push', 'public', f'{tip}:refs/heads/main', expected=1)
    run(repo, 'git', 'push', 'origin', f'{tip}:refs/heads/again')
    # Same remote name, different push URL: origin's tracking refs describe the fetch side, not the target.
    run(repo, 'git', 'remote', 'set-url', '--push', 'origin', str(public))
    run(repo, 'git', 'push', 'origin', f'{tip}:refs/heads/main', expected=1)
    run(repo, 'git', 'remote', 'set-url', '--delete', '--push', 'origin', str(public))
    run(repo, 'git', '-c', 'core.hooksPath=/dev/null', 'push', '-q', 'origin', f'{base}:refs/heads/main', '--force')
    run(repo, 'git', 'push', 'origin', f'{base}:refs/heads/delete-me')
    run(repo, 'git', 'push', 'origin', ':refs/heads/delete-me')
    saved_cwd = pathlib.Path.cwd()
    try:
        os.chdir(repo)
        revisions = runpy.run_path(str(ROOT / 'scripts/check-push-secrets.py'))['revisions']
        # Rewinding to an ancestor adds nothing to scan.
        assert list(revisions([f'refs/heads/main {base} refs/heads/main {tip}'])) == []
        # An old ref the clone does not have falls back to the merge base with the target's main, or with no
        # target named, to the whole history.
        assert list(revisions([f'refs/heads/main {tip} refs/heads/main {"f" * 40}'], 'origin')) == [(tip, base)]
        assert list(revisions([f'refs/heads/main {tip} refs/heads/main {"f" * 40}'])) == [(tip, None)]
        assert len(list(revisions([f'a {tip} b {base}', f'c {bad} d {base}']))) == 2
        # A full-history request (all-zero base, no remote) must not fall back to origin: that span would be empty
        # and pass unscanned. Pushing to another remote must not borrow origin's refs either.
        zero = '0' * 40
        assert list(revisions([f'local {base} local {zero}'], 'origin')) == []
        assert list(revisions([f'local {base} local {zero}'])) == [(base, None)]
        assert list(revisions([f'local {base} local {zero}'], 'public')) == [(base, None)]
    finally:
        os.chdir(saved_cwd)
    # TruffleHog must independently detect the synthetic secret without online verification.
    result = subprocess.run(['trufflehog', 'git', repo.as_uri(), '--branch', bad,
                             '--since-commit', base, '--json', '--no-update', '--no-verification',
                             '--skip-additional-refs', '--fail', '--fail-on-scan-errors'],
                            capture_output=True, text=True, cwd=repo, env=ENV, timeout=240)
    assert result.returncode == 183 and result.stdout, 'TruffleHog missed the synthetic secret'
    # CI executes trusted base controls, even if a PR replaces its own policy/script.
    (repo / '.gitleaks.toml').write_text('[extend]\nuseDefault = true\n[[allowlists]]\nregexes = [".*"]\n')
    (repo / 'scripts/check-push-secrets.py').write_text('raise SystemExit(0)\n')
    (repo / 'sample.txt').write_text(SECRET + ' # gitleaks:allow trufflehog:ignore\n')
    run(repo, 'git', 'add', '.')
    run(repo, 'git', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'untrusted scan controls')
    untrusted = run(repo, 'git', 'rev-parse', 'HEAD')
    run(repo, 'python3', str(ROOT / 'scripts/check-push-secrets.py'), str(repo),
        stdin=f'ci {untrusted} ci {base}\n', expected=1)
    # Deletion-only pushes skip scanning; malformed hook input fails closed.
    run(repo, 'python3', str(ROOT / 'scripts/check-push-secrets.py'), str(repo), stdin='invalid\n', expected=1)

    # Machine-local words: no local.denylist means nothing to check; with one, commit and push both stop.
    words = pathlib.Path(directory).resolve() / 'words'
    words.mkdir()
    for name in ('mise.toml', 'lefthook.yml', '.gitleaks.toml'):
        shutil.copyfile(ROOT / name, words / name)
    (words / 'scripts').mkdir()
    for name in ('check-push-secrets.py', 'check-denylist.py'):
        shutil.copyfile(ROOT / 'scripts' / name, words / 'scripts' / name)
    ENV['MISE_TRUSTED_CONFIG_PATHS'] = str(words)
    run(words, 'git', 'init', '-q', '-b', 'main')
    run(words, 'mise', 'exec', '--', 'lefthook', 'install')
    (words / '.gitignore').write_text('local.denylist\n')
    (words / 'notes.txt').write_text('start\n')
    run(words, 'git', 'add', '.')
    run(words, 'git', 'commit', '-qm', 'start')
    # Without local.denylist the word passes.
    (words / 'notes.txt').write_text('tuned for Placeholder-Owner\n')
    run(words, 'git', 'add', 'notes.txt')
    run(words, 'mise', 'exec', '--', 'lefthook', 'run', 'pre-commit')
    run(words, 'git', 'checkout', '-q', 'HEAD', '--', 'notes.txt')
    (words / 'local.denylist').write_text('# comment\nplaceholder-owner\n')
    (words / 'notes.txt').write_text('tuned for Placeholder-Owner, again\n')
    run(words, 'git', 'add', 'notes.txt')
    run(words, 'git', 'commit', '-qm', 'word in a line', expected=1)
    (words / 'notes.txt').write_text('neutral\n')
    run(words, 'git', 'add', 'notes.txt')
    run(words, 'git', 'commit', '-qm', 'neutral line')
    remote = pathlib.Path(directory) / 'words.git'
    run(words, 'git', 'init', '--bare', '-q', str(remote))
    run(words, 'git', 'remote', 'add', 'origin', str(remote))
    run(words, 'git', 'push', '-q', 'origin', 'main')
    # A hook-bypassed commit carrying the word in its message is caught at push.
    (words / 'notes.txt').write_text('still neutral\n')
    run(words, 'git', 'add', 'notes.txt')
    run(words, 'git', 'commit', '--no-verify', '-qm', 'as Placeholder-Owner asked')
    run(words, 'git', 'push', 'origin', 'main', expected=1)
    run(words, 'git', 'commit', '--amend', '--no-verify', '-qm', 'neutral message')
    run(words, 'git', 'push', 'origin', 'main')
print('PASS: clean commit/push, staged-only checks, redaction, deleted-secret history, new/other refs, merge-base span, malformed input, both scanners, local denylist')
