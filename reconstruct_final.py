#!/usr/bin/env python3
"""
Final reconstruction using ONLY reads from files with totalLines >= 20000.
These reads are all from the FINAL period of the file, so line numbers are consistent.
For remaining gaps, we'll try to fill using Edit old_strings from the same period.
"""
import json, sys
from collections import defaultdict

JSONL_PATH = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"
OUTPUT_FILE = r"C:\shoppilot\lib\main_final.dart"
STOP_LINE = 18617
MIN_TOTAL_LINES = 20000  # Only use reads from the final large file

def is_main(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

print("Phase 1: Scanning JSONL for late-period reads...", flush=True)

# Store: line_num -> (content, jsonl_lineno, total_lines)
lines = {}

with open(JSONL_PATH, encoding='utf-8', errors='replace') as f:
    for jsonl_lineno, raw in enumerate(f, 1):
        if jsonl_lineno > STOP_LINE:
            break
        if jsonl_lineno % 3000 == 0:
            print(f"  JSONL line {jsonl_lineno}...", flush=True)
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

        total = fi.get('totalLines', 0)
        if total < MIN_TOTAL_LINES:
            continue  # Skip reads from earlier file versions

        content = fi.get('content', '')
        start = fi.get('startLine', 1)
        num = fi.get('numLines', 0)

        if not content or num == 0:
            continue

        content_lines = content.split('\n')
        if content_lines and content_lines[-1] == '':
            content_lines = content_lines[:-1]

        for i, line in enumerate(content_lines):
            ln = start + i
            # Later reads (higher jsonl_lineno) win for same line
            if ln not in lines or lines[ln][1] < jsonl_lineno:
                lines[ln] = (line, jsonl_lineno, total)

max_line = max(lines.keys()) if lines else 0
print(f"\nLate-period reads coverage: {len(lines)} lines")
print(f"Max line: {max_line}")

# Fill with Edit old_strings for gaps in covered range
print("\nPhase 2: Filling gaps with Edit old_strings...", flush=True)

edit_snippets = []
with open(JSONL_PATH, encoding='utf-8', errors='replace') as f:
    for jsonl_lineno, raw in enumerate(f, 1):
        if jsonl_lineno > STOP_LINE:
            break
        try:
            obj = json.loads(raw)
        except:
            continue
        if obj.get('type') != 'assistant':
            continue
        for item in obj.get('message', {}).get('content', []):
            if item.get('type') != 'tool_use' or item.get('name') != 'Edit':
                continue
            if not is_main(item.get('input', {}).get('file_path', '')):
                continue
            for key in ('old_string', 'new_string'):
                s = item.get('input', {}).get(key, '')
                if s:
                    edit_snippets.append(s)

print(f"Edit snippets: {len(edit_snippets)}")

filled_from_edits = 0
gap_set = set(range(1, max_line + 1)) - set(lines.keys())

for snippet in edit_snippets:
    slines = snippet.split('\n')
    if len(slines) < 2:
        continue
    # Try to find anchor (first non-gap line)
    for ln, (content, jl, tl) in list(lines.items()):
        if content.rstrip() == slines[0].rstrip():
            # Check if snippet extends into a gap
            for j, sl in enumerate(slines[1:], 1):
                target = ln + j
                if target in gap_set:
                    lines[target] = (sl, -1, 0)  # gap-filled
                    gap_set.discard(target)
                    filled_from_edits += 1
            break

print(f"Filled {filled_from_edits} gaps from edits")
print(f"Remaining gaps: {len(gap_set)}")

# Write output
with open(OUTPUT_FILE, 'w', encoding='utf-8') as out:
    for i in range(1, max_line + 1):
        if i in lines:
            out.write(lines[i][0] + '\n')
        else:
            out.write(f"// [GAP: LINE {i}]\n")

print(f"\nWritten to: {OUTPUT_FILE}")
print(f"Total lines: {max_line}")

# Show gap ranges
if gap_set:
    sorted_gaps = sorted(gap_set)
    ranges = []
    s = sorted_gaps[0]; p = sorted_gaps[0]
    for g in sorted_gaps[1:]:
        if g == p + 1: p = g
        else: ranges.append((s, p)); s = g; p = g
    ranges.append((s, p))
    total_gaps = sum(e-s+1 for s,e in ranges)
    print(f"\n{total_gaps} gap lines in {len(ranges)} ranges:")
    for s, e in ranges[:20]:
        print(f"  Lines {s}-{e} ({e-s+1} lines)")
