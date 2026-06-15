#!/usr/bin/env python3
import json

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"

def is_main(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

reads_late = []
with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        if i > 18617:
            break
        try:
            obj = json.loads(raw)
        except:
            continue
        if obj.get('type') != 'user':
            continue
        tr = obj.get('toolUseResult', {})
        if not isinstance(tr, dict):
            continue
        fi = tr.get('file', {})
        if not fi:
            continue
        if not is_main(fi.get('filePath', '')):
            continue
        start = fi.get('startLine', 0)
        nl = fi.get('numLines', 0)
        tl = fi.get('totalLines', 0)
        if i >= 18000:
            reads_late.append((i, start, nl, tl))

print(f'Reads in JSONL lines 18000-18617: {len(reads_late)}')
for r in reads_late:
    print(f'  JSONL {r[0]}: lines {r[1]}-{r[1]+r[2]-1} (of {r[3]} total)')
