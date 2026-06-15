#!/usr/bin/env python3
"""Find all reads from latest file versions and show what coverage we have"""
import sys, io, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"

MIN_TOTAL = 18000

def is_main(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

print(f"Scanning for reads with totalLines >= {MIN_TOTAL}...", flush=True)

reads = []
with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        if i > 18617:
            break
        if i % 5000 == 0:
            print(f"  JSONL {i}...", flush=True)
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
        if not fi or not is_main(fi.get('filePath', '')):
            continue
        total = fi.get('totalLines', 0)
        if total < MIN_TOTAL:
            continue
        start = fi.get('startLine', 1)
        num = fi.get('numLines', 0)
        reads.append((i, start, num, total, fi.get('content', '')))

print(f"\nFound {len(reads)} reads with totalLines >= {MIN_TOTAL}")
print("\nAll reads:")
for jsonl_i, start, num, total, content in sorted(reads):
    end = start + num - 1
    first_line = content.split('\n')[0][:60] if content else ''
    print(f"  JSONL {jsonl_i}: lines {start}-{end} of {total} | '{first_line}'")

# Now compute combined coverage
coverage = {}
for jsonl_i, start, num, total, content in reads:
    lines = content.split('\n')
    for j, line in enumerate(lines):
        ln = start + j
        if ln not in coverage or coverage[ln][1] < jsonl_i:
            coverage[ln] = (line, jsonl_i, total)

if coverage:
    covered_lines = sorted(coverage.keys())
    max_line = max(covered_lines)
    print(f"\nCombined coverage: {len(coverage)} lines (max line: {max_line})")

    # Show gaps
    gaps = []
    s = None
    for ln in range(1, max_line + 1):
        if ln not in coverage:
            if s is None:
                s = ln
        else:
            if s is not None:
                gaps.append((s, ln - 1))
                s = None
    if s is not None:
        gaps.append((s, max_line))

    total_gap = sum(e - s + 1 for s, e in gaps)
    print(f"Gaps: {total_gap} lines in {len(gaps)} ranges")
    print("\nFirst 20 gap ranges:")
    for s, e in gaps[:20]:
        print(f"  Lines {s}-{e} ({e-s+1} lines)")
