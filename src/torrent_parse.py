#!/usr/bin/env python3
"""Torrent search-JSON field extractor for _play_one_torrent / _prep_start_torrent.

One python spawn per episode replaces the old chain of five `python3 -c`
heredocs (validation, top fields, choices render, idx re-parse, fallback
magnets). At ~60ms process startup + parse each, that was the single
largest fixed cost on the torrent path.

stdin:  provider_search JSON array
argv1:  mode — "summary" | "choices" | "pick" | "magnets"
env:    IDX   (pick) 1-based index of the chosen candidate
        CHOSEN (magnets) magnet to exclude from the fallback list

stdout: mode-dependent newline-separated fields.
"""
import sys, json, os


def load():
    try:
        d = json.load(sys.stdin)
        return d if isinstance(d, list) else []
    except Exception:
        return []


def summary(d):
    print(len(d))
    if not d:
        return
    r = d[0]
    print(r.get('magnet', '') or '')
    print(r.get('group', '') or '')
    print(r.get('resolution', '') or '')
    print(r.get('size', '') or '')
    print(r.get('target_season', '') or '')


def choices(d):
    for i, r in enumerate(d[:5]):
        g = r.get('group', '') or '?'
        res = r.get('resolution', '') or '?'
        sz = r.get('size', '') or '?'
        sd = r.get('seeds', 0) or 0
        batch = ' [BATCH]' if r.get('is_batch') else ''
        trust = ' ✓' if r.get('trusted') else ''
        print(f"{i+1}\t[{g}] {res} {sz} {sd}s{batch}{trust}")


def pick(d):
    try:
        i = int(os.environ.get('IDX', '1')) - 1
    except ValueError:
        i = 0
    if 0 <= i < len(d):
        r = d[i]
        print(r.get('magnet', '') or '')
        print(r.get('group', '') or '')
        print(r.get('resolution', '') or '')
        print(r.get('target_season', '') or '')


def magnets(d):
    chosen = os.environ.get('CHOSEN', '')
    for r in d[:3]:
        m = r.get('magnet', '') or ''
        if m and m != chosen:
            print(m)


def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    d = load()
    mode = sys.argv[1]
    if mode == 'summary':
        summary(d)
    elif mode == 'choices':
        choices(d)
    elif mode == 'pick':
        pick(d)
    elif mode == 'magnets':
        magnets(d)
    else:
        sys.exit(1)


if __name__ == '__main__':
    main()
