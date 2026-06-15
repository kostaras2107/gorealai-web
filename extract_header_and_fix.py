#!/usr/bin/env python3
"""Extract the header (imports, constants) from latest file version and fix main.dart"""
import sys, io, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"

def is_main(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

# Target reads for extraction
TARGETS = {18413, 18105, 17817, 12192, 5797}

found = {}
with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        if i > 18617:
            break
        if i not in TARGETS:
            continue
        try:
            obj = json.loads(raw)
        except:
            continue
        tr = obj.get('toolUseResult', {})
        if not isinstance(tr, dict):
            continue
        fi = tr.get('file', {})
        if not fi or not is_main(fi.get('filePath', '')):
            continue
        found[i] = fi

for i in sorted(found.keys()):
    fi = found[i]
    start = fi.get('startLine', 0)
    num = fi.get('numLines', 0)
    total = fi.get('totalLines', 0)
    lines = fi.get('content', '').split('\n')
    print(f"\n{'='*60}")
    print(f"JSONL {i}: lines {start}-{start+num-1} of {total}")
    for j, l in enumerate(lines):
        print(f"{start+j}: {l}")
