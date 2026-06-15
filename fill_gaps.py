#!/usr/bin/env python3
"""
Fill gaps in main_reconstructed.dart using Edit tool old_strings from JSONL.
Strategy: if a gap line is BETWEEN two known lines in an old_string, we can extract it.
"""
import json, sys, re

JSONL_PATH = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"
RECONSTRUCTED = r"C:\shoppilot\lib\main_reconstructed.dart"
OUTPUT = r"C:\shoppilot\lib\main_filled.dart"
STOP_LINE = 18617

TARGET_PATHS = [
    r"C:\shoppilot\lib\main.dart",
    "/c/shoppilot/lib/main.dart",
    "c:/shoppilot/lib/main.dart",
]

# Load reconstructed file
print("Loading reconstructed file...", flush=True)
with open(RECONSTRUCTED, encoding='utf-8') as f:
    recon_lines = f.readlines()

# Build a dict of what's a gap
gap_lines = set()
for i, line in enumerate(recon_lines, 1):
    if line.startswith('// [GAP: LINE '):
        gap_lines.add(i)

print(f"Gaps to fill: {len(gap_lines)}")

# lines dict: 1-indexed line -> content (without newline)
lines = {}
for i, line in enumerate(recon_lines, 1):
    lines[i] = line.rstrip('\n')

def is_main_dart(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

filled = 0

print("Scanning JSONL for Edit old_strings...", flush=True)

# Collect ALL old_string from Edit tool calls for main.dart before line 18617
edit_snippets = []  # list of (new_string content lines)

with open(JSONL_PATH, encoding='utf-8', errors='replace') as f:
    for jsonl_lineno, raw in enumerate(f, 1):
        if jsonl_lineno > STOP_LINE:
            break
        if jsonl_lineno % 2000 == 0:
            print(f"  JSONL line {jsonl_lineno}...", flush=True)
        try:
            obj = json.loads(raw)
        except:
            continue

        if obj.get('type') != 'assistant':
            continue

        msg = obj.get('message', {})
        for item in msg.get('content', []):
            if item.get('type') != 'tool_use':
                continue
            if item.get('name') != 'Edit':
                continue
            inp = item.get('input', {})
            file_path = inp.get('file_path', '')
            if not is_main_dart(file_path):
                continue

            old_str = inp.get('old_string', '')
            new_str = inp.get('new_string', '')

            if old_str:
                edit_snippets.append(old_str)
            if new_str:
                edit_snippets.append(new_str)

print(f"Found {len(edit_snippets)} edit snippets")

# Now try to use edit snippets to fill gaps
# Strategy: look for each snippet in the reconstructed file context
# If a snippet contains multiple lines, we can match it to known lines
# and use the in-between lines for gaps

for snippet in edit_snippets:
    snippet_lines = snippet.split('\n')
    if len(snippet_lines) < 3:
        continue  # Too short to be useful

    # Try to find where this snippet starts in our reconstructed file
    # by matching the first known line
    first_line = snippet_lines[0].rstrip()
    if not first_line:
        continue

    # Look for this line in the reconstructed file (only non-gap lines)
    for line_num, content in lines.items():
        if line_num in gap_lines:
            continue
        if content.rstrip() == first_line:
            # Try to match the snippet from here
            match = True
            last_gap_end = None
            for j, sl in enumerate(snippet_lines):
                target_num = line_num + j
                if target_num not in lines:
                    match = False
                    break
                if target_num in gap_lines:
                    continue  # Gap - we'll fill later
                if lines[target_num].rstrip() != sl.rstrip():
                    match = False
                    break

            if match:
                # Fill in gaps
                for j, sl in enumerate(snippet_lines):
                    target_num = line_num + j
                    if target_num in gap_lines:
                        lines[target_num] = sl.rstrip('\r\n')
                        gap_lines.discard(target_num)
                        filled += 1
                break  # Found match, stop

print(f"\nFilled {filled} gap lines using edit snippets")
print(f"Remaining gaps: {len(gap_lines)}")

# Write output
with open(OUTPUT, 'w', encoding='utf-8') as out:
    for i in range(1, max(lines.keys()) + 1):
        if i in lines:
            out.write(lines[i] + '\n')

print(f"Written to: {OUTPUT}")

if gap_lines:
    sorted_gaps = sorted(gap_lines)
    ranges = []
    start = sorted_gaps[0]
    prev = sorted_gaps[0]
    for g in sorted_gaps[1:]:
        if g == prev + 1:
            prev = g
        else:
            ranges.append((start, prev))
            start = g
            prev = g
    ranges.append((start, prev))
    print(f"\nRemaining {len(gap_lines)} gap lines in {len(ranges)} ranges:")
    for s, e in ranges[:15]:
        print(f"  Lines {s}-{e} ({e-s+1} lines)")
