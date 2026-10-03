#!/usr/bin/env python3
"""Inspect every pushed ref, including intermediate commits; never print secret values."""
import argparse
import os
import json
import pathlib
import re
import subprocess
import sys


def git(*args):
    return subprocess.run(['git', *args], capture_output=True, text=True, check=True).stdout.strip()


def revisions(lines, remote=None):
    """remote: a pushed-to remote whose tracking refs reflect the push target (see tracked_remote)."""
    for line in lines:
        fields = line.split()
        if len(fields) != 4 or any(not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', s) for s in (fields[1], fields[3])):
            raise ValueError('Invalid pre-push input')
        _, tip, _, old = fields
        if set(tip) == {'0'}:  # Remote ref deletion sends no content.
            continue
        tip = git('rev-parse', '--verify', tip + '^{commit}')
        # Scan what the push adds: the commits after the merge base with the old remote ref, or for a new ref with the
        # default branch of the remote being pushed to. Only when neither is known is the whole history scanned.
        # Scanning the whole history on every new-ref push (every PR branch) would re-judge old commits that history,
        # never rewritten, keeps. The fallback uses only the push target's own refs: another remote's refs (say origin
        # while pushing a new public remote) would skip commits the target has never received. CI and the full-history
        # task pass no remote, so an all-zero base there means the whole history.
        base = None
        refs = [old] if set(old) != {'0'} else []
        if remote:
            refs += [f'refs/remotes/{remote}/HEAD', f'refs/remotes/{remote}/main']
        for ref in refs:
            try:
                base = git('merge-base', git('rev-parse', '--verify', ref + '^{commit}'), tip)
                break
            except subprocess.CalledProcessError:
                continue
        if base == tip:  # nothing new on this ref
            print(f'Nothing new to scan on {tip[:12]}', flush=True)
            continue
        yield tip, base


def tracked_remote(remote, url):
    """The remote whose tracking refs may stand in for the push target, or None.

    Tracking refs record what was fetched, from the fetch URL. When the push goes elsewhere (a separate pushurl, a
    remote renamed to a new repository, a push straight to a URL), they say nothing about what the target holds.
    """
    if not remote or not url:
        return None
    try:
        fetch_url = git('remote', 'get-url', remote)
    except subprocess.CalledProcessError:
        return None
    return remote if fetch_url == url else None


def scan(command, scanner):
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    # Scanner JSON may contain raw credentials. Only emit selected metadata.
    if scanner == 'gitleaks':
        findings = json.loads(result.stdout or '[]')
        for f in findings:
            print(json.dumps({'scanner': scanner, 'file': f.get('File'),
                              'line': f.get('StartLine'), 'rule': f.get('RuleID')}, ensure_ascii=False))
    else:
        findings = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        for f in findings:
            location = f.get('SourceMetadata', {}).get('Data', {}).get('Git', {})
            print(json.dumps({'scanner': scanner, 'file': location.get('file'),
                              'line': location.get('line'), 'rule': f.get('DetectorName')}, ensure_ascii=False))
    if findings or result.returncode:
        print(f'{scanner}: scan failed (findings or scan error, exit={result.returncode}).', file=sys.stderr)
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', nargs='?', default='.', help='Repository to scan (CI may use trusted code from another checkout)')
    parser.add_argument('--remote', help='Name of the remote being pushed to (pre-push passes it); its refs may '
                        'stand in for an unknown base. Omitted: only the base given on stdin counts (CI, full scan)')
    parser.add_argument('--url', help='URL being pushed to (pre-push passes it); required with --remote')
    args = parser.parse_args()
    controls = pathlib.Path(__file__).resolve().parent.parent
    os.chdir(args.repository)
    repo = pathlib.Path(git('rev-parse', '--show-toplevel')).resolve()
    ok = True
    for tip, base in dict.fromkeys(revisions(sys.stdin, tracked_remote(args.remote, args.url))):
        span = f'{base}..{tip}' if base else tip
        print(f'Scanning pushed history: {span}', flush=True)
        ok = scan(['gitleaks', 'git', '--redact=100', '--no-banner', '--report-format=json',
                   '--report-path=-', '--config=' + str(controls / '.gitleaks.toml'),
                   '--gitleaks-ignore-path=' + str(controls / '.gitleaksignore'), '--ignore-gitleaks-allow',
                   '--log-opts=--full-history --diff-merges=first-parent ' + span,
                   str(repo)], 'gitleaks') and ok
        command = ['trufflehog', 'git', repo.as_uri(), '--branch', tip, '--json', '--no-update',
                   '--no-verification', '--results=verified,unknown,unverified', '--fail',
                   '--fail-on-scan-errors', '--no-ignore-tag', '--skip-additional-refs', '--concurrency=2']
        if base:
            command += ['--since-commit', base]
        ok = scan(command, 'trufflehog') and ok
    if not ok:
        raise SystemExit(1)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        # Exceptions may embed scanner output or command arguments; keep them private.
        print('Secret scan failed. Check tool installation and Git refs.', file=sys.stderr)
        raise SystemExit(1)
