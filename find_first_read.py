#!/usr/bin/env python3
import json

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"

def is_main(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

print("Finding first reads of main project main.dart...")
count = 0
with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        if i > 1000:
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
        path = fi.get('filePath', '')
        if not is_main(path):
            continue
        start = fi.get('startLine', 0)
        nl = fi.get('numLines', 0)
        tl = fi.get('totalLines', 0)
        content_preview = fi.get('content', '')[:100].replace('\n', ' ')
        print(f'JSONL {i}: lines {start}-{start+nl-1} of {tl}: "{content_preview}"')
        count += 1
        if count >= 10:
            break

print(f"\nFound {count} reads in first 1000 JSONL lines")
