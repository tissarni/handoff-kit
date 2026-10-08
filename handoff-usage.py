#!/usr/bin/env python3
"""Price a Claude Code session transcript from its own usage rows.

    python3 handoff-usage.py <transcript.jsonl> <brief> <stage> [--since <epoch seconds>]

Reads the transcript and, beside it, every subagent transcript under
<transcript path without .jsonl>/subagents/*.jsonl. Dedupes assistant
messages by id (every row repeats its message's final usage; the row with
the largest output_tokens wins), drops zero-cost messages, prices what is
left against the table below and prints one line:

    USAGE <brief> <stage> turns=<n> in=<n> cw=<n> cr=<n> out=<n> cost=<%.4f>

ending with " unpriced=<n>" when n messages had no recognised model. Never
fails on a missing transcript or an unparseable row — it prints what it can.

With --since, a row counts only when its timestamp is at or after that time,
and a row with no timestamp does not count: a resumed session appends to the
transcript it continues, and the earlier stage's turns are already priced.
"""
import json
import os
import sys
from datetime import datetime

# USD per million tokens.
PRICES = {
    'opus':   {'input': 5,  'cache_write_1h': 10, 'cache_write_5m': 6.25, 'cache_read': 0.50, 'output': 25},
    'sonnet': {'input': 3,  'cache_write_1h': 6,  'cache_write_5m': 3.75, 'cache_read': 0.30, 'output': 15},
    'haiku':  {'input': 1,  'cache_write_1h': 2,  'cache_write_5m': 1.25, 'cache_read': 0.10, 'output': 5},
}


def price_family(model):
    m = (model or '').lower()
    for fam in ('opus', 'sonnet', 'haiku'):
        if fam in m:
            return fam
    return None


def row_time(row):
    ts = row.get('timestamp')
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def iter_assistant_rows(path, since=None):
    try:
        f = open(path, encoding='utf-8', errors='replace')
    except OSError:
        return
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict) or row.get('type') != 'assistant':
                continue
            if since is not None:
                t = row_time(row)
                if t is None or t < since:
                    continue
            msg = row.get('message')
            if not isinstance(msg, dict):
                continue
            usage = msg.get('usage')
            if not isinstance(usage, dict):
                continue
            yield msg


def main():
    args = sys.argv[1:]
    since = None
    if len(args) == 5 and args[3] == '--since':
        try:
            since = float(args[4])
            args = args[:3]
        except ValueError:
            pass
    if len(args) != 3:
        print('usage: handoff-usage.py <transcript.jsonl> <brief> <stage> [--since <epoch seconds>]', file=sys.stderr)
        return 2
    transcript, brief, stage = args

    if not os.path.isfile(transcript):
        print(f'USAGE {brief} {stage} unavailable — no transcript at {transcript}')
        return 0

    files = [transcript]
    subdir = transcript[:-6] + '/subagents' if transcript.endswith('.jsonl') else transcript + '/subagents'
    if os.path.isdir(subdir):
        for n in sorted(os.listdir(subdir)):
            if n.endswith('.jsonl'):
                files.append(os.path.join(subdir, n))

    groups = {}   # id (or a fresh key for id-less rows) -> best message
    anon = 0
    for path in files:
        for msg in iter_assistant_rows(path, since):
            mid = msg.get('id')
            if mid is None:
                anon += 1
                key = ('__anon__', path, anon)
            else:
                key = mid
            out = (msg.get('usage') or {}).get('output_tokens') or 0
            prev = groups.get(key)
            if prev is None or out > (prev.get('usage') or {}).get('output_tokens', 0):
                groups[key] = msg

    turns = 0
    tin = tcw = tcr = tout = 0
    unpriced = 0
    cost = 0.0
    for msg in groups.values():
        usage = msg.get('usage') or {}
        i = usage.get('input_tokens') or 0
        cw = usage.get('cache_creation_input_tokens') or 0
        cr = usage.get('cache_read_input_tokens') or 0
        o = usage.get('output_tokens') or 0
        if i == 0 and cw == 0 and cr == 0 and o == 0:
            continue
        turns += 1
        tin += i; tcw += cw; tcr += cr; tout += o
        fam = price_family(msg.get('model'))
        if fam is None:
            unpriced += 1
            continue
        p = PRICES[fam]
        cc = usage.get('cache_creation') or {}
        cw_1h = cc.get('ephemeral_1h_input_tokens') or 0
        cw_5m = cw - cw_1h
        cost += (i * p['input'] + cw_1h * p['cache_write_1h'] + cw_5m * p['cache_write_5m']
                 + cr * p['cache_read'] + o * p['output']) / 1_000_000

    line = f'USAGE {brief} {stage} turns={turns} in={tin} cw={tcw} cr={tcr} out={tout} cost={cost:.4f}'
    if unpriced:
        line += f' unpriced={unpriced}'
    print(line)
    return 0


if __name__ == '__main__':
    sys.exit(main())
