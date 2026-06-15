#!/usr/bin/env python3
"""
Reconstruct main.dart using only reads from the SAME file size (final state).
This ensures consistency - only reads from the final ~18899-line version are used.
"""
import json, sys
from collections import defaultdict

JSONL_PATH = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"
STOP_LINE = 18617

def is_main_dart(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

print("Phase 1: Collect all reads grouped by totalLines...", flush=True)

# reads_by_size[total_lines] = list of (jsonl_lineno, startLine, content_lines)
reads_by_size = defaultdict(list)
jsonl_lineno_to_read = []  # for ordering

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
        tool_result = obj.get('toolUseResult')
        if not tool_result or not isinstance(tool_result, dict):
            continue
        file_info = tool_result.get('file')
        if not file_info:
            continue
        if not is_main_dart(file_info.get('filePath', '')):
            continue

        content = file_info.get('content', '')
        start_line = file_info.get('startLine', 1)
        num_lines = file_info.get('numLines', 0)
        total_lines = file_info.get('totalLines', 0)

        if not content or num_lines == 0 or total_lines == 0:
            continue

        content_lines = content.split('\n')
        if content_lines and content_lines[-1] == '':
            content_lines = content_lines[:-1]

        reads_by_size[total_lines].append((jsonl_lineno, start_line, content_lines))

print(f"\nFile sizes seen:")
for size in sorted(reads_by_size.keys(), reverse=True)[:10]:
    print(f"  {size} lines: {len(reads_by_size[size])} reads")

# Find the final file size (largest totalLines seen before the mistake)
# Also need to check which size has the most comprehensive coverage near the end
final_sizes = sorted(reads_by_size.keys(), reverse=True)
print(f"\nAll sizes: {sorted(reads_by_size.keys(), reverse=True)[:20]}")

# Use the most reads from the largest sizes
# Strategy: for each line, use the LATEST read (highest jsonl_lineno) for that line
# but only from reads where the file was the SAME SIZE as at that time

# Find last jsonl_lineno for each totalLines
last_reads = {}
for size, reads in reads_by_size.items():
    last_reads[size] = max(r[0] for r in reads)

print(f"\nLast read for each size:")
for size in sorted(last_reads.keys(), reverse=True)[:10]:
    print(f"  {size} lines: last read at JSONL line {last_reads[size]}")

# The FINAL file had the maximum totalLines
max_size = max(reads_by_size.keys())
print(f"\nFinal file size: {max_size} lines")
print(f"Reads at final size: {len(reads_by_size[max_size])}")

# Build reconstruction using ONLY reads from the final size
# (Use latest read for each line if multiple reads cover it)
lines = {}  # line_num -> (content, jsonl_lineno)

print(f"\nPhase 2: Reconstructing from final-size reads only...", flush=True)

for jsonl_lineno, start_line, content_lines in reads_by_size[max_size]:
    for i, line_content in enumerate(content_lines):
        line_num = start_line + i
        if line_num not in lines or lines[line_num][1] < jsonl_lineno:
            lines[line_num] = (line_content, jsonl_lineno)

coverage_final = len(lines)
gaps = [i for i in range(1, max_size + 1) if i not in lines]
print(f"Coverage from final-size reads: {coverage_final}/{max_size} = {100*coverage_final//max_size}%")
print(f"Gaps: {len(gaps)}")

# Fill remaining gaps using reads from OTHER sizes (penultimate, etc.)
# sorted by size desc, then by jsonl_lineno desc (more recent = better)
print(f"\nPhase 3: Filling gaps from other-size reads...", flush=True)
remaining_gaps = set(gaps)

for size in sorted(reads_by_size.keys(), reverse=True):
    if size == max_size:
        continue
    if not remaining_gaps:
        break
    for jsonl_lineno, start_line, content_lines in sorted(reads_by_size[size], key=lambda x: x[0], reverse=True):
        for i, line_content in enumerate(content_lines):
            line_num = start_line + i
            if line_num in remaining_gaps:
                lines[line_num] = (line_content, jsonl_lineno)
                remaining_gaps.discard(line_num)

print(f"After cross-size fill: {len(lines)}/{max_size} = {100*len(lines)//max_size}%")
print(f"Remaining gaps: {len(remaining_gaps)}")

# Write output
output_path = r"C:\shoppilot\lib\main_v2.dart"
with open(output_path, 'w', encoding='utf-8') as out:
    for i in range(1, max_size + 1):
        if i in lines:
            out.write(lines[i][0] + '\n')
        else:
            out.write(f"// [GAP: LINE {i} NOT CAPTURED]\n")

print(f"\nWritten to: {output_path}")

# Show gap ranges
if remaining_gaps:
    sorted_gaps = sorted(remaining_gaps)
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
    print(f"\nRemaining gaps in {len(ranges)} ranges:")
    for s, e in ranges[:20]:
        print(f"  Lines {s}-{e} ({e-s+1} lines)")
    if len(ranges) > 20:
        print(f"  ... and {len(ranges)-20} more")
