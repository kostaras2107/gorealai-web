#!/usr/bin/env python3
"""
Reconstruct C:\shoppilot\lib\main.dart from JSONL session file.
Uses Read tool results (toolUseResult.file.content + startLine + numLines).
Stops at JSONL line 18617 (the mistake line).
"""
import json, sys

JSONL_PATH = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"
STOP_LINE = 18617
TARGET_PATHS = [
    r"C:\shoppilot\lib\main.dart",
    "/c/shoppilot/lib/main.dart",
    "c:/shoppilot/lib/main.dart",
    "c:\\shoppilot\\lib\\main.dart",
]

# Dictionary: line_number (1-indexed) -> code_line
lines = {}
max_line = 0
total_reads = 0
read_coverage = set()

print("Scanning JSONL...", flush=True)

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

        # We want user messages with tool_result that have file content
        if obj.get('type') != 'user':
            continue

        tool_result = obj.get('toolUseResult')
        if not tool_result:
            continue
        if not isinstance(tool_result, dict):
            continue

        # Check if it's a file read result
        file_info = tool_result.get('file')
        if not file_info:
            continue

        file_path = file_info.get('filePath', '')
        # Check if this is the main project main.dart (not worktree)
        is_main = False
        for tp in TARGET_PATHS:
            if file_path.lower() == tp.lower():
                is_main = True
                break
        # Also check by path components
        if not is_main:
            fp_lower = file_path.lower().replace('\\', '/').replace('//', '/')
            if fp_lower.endswith('shoppilot/lib/main.dart') and 'worktree' not in fp_lower and '.claude' not in fp_lower:
                is_main = True

        if not is_main:
            continue

        content = file_info.get('content', '')
        start_line = file_info.get('startLine', 1)
        num_lines = file_info.get('numLines', 0)
        total_lines = file_info.get('totalLines', 0)

        if not content or num_lines == 0:
            continue

        total_reads += 1

        # Split content into lines
        content_lines = content.split('\n')
        # Remove trailing empty line if split added one
        if content_lines and content_lines[-1] == '':
            content_lines = content_lines[:-1]

        # Store each line
        for i, line_content in enumerate(content_lines):
            line_num = start_line + i
            lines[line_num] = line_content
            read_coverage.add(line_num)

        if total_lines > max_line:
            max_line = total_lines

        actual_end = start_line + len(content_lines) - 1
        if actual_end > max_line:
            max_line = actual_end

print(f"\nDone scanning.")
print(f"Total Read results for main.dart: {total_reads}")
print(f"Lines captured: {len(read_coverage)}")
print(f"Max line seen in totalLines: {max_line}")
print(f"Actual max line in dictionary: {max(lines.keys()) if lines else 0}")

if not lines:
    print("ERROR: No lines found! Check path filtering.")
    sys.exit(1)

actual_max = max(lines.keys())
print(f"\nFile appears to have ~{actual_max} lines (based on captured content)")
print(f"Coverage: {len(lines)}/{actual_max} = {100*len(lines)//actual_max}%")

# Find gaps
gap_lines = []
for i in range(1, actual_max + 1):
    if i not in lines:
        gap_lines.append(i)

print(f"Gap lines: {len(gap_lines)}")
if gap_lines[:10]:
    print(f"First 10 gaps: {gap_lines[:10]}")

# Write reconstructed file
output_path = r"C:\shoppilot\lib\main_reconstructed.dart"
with open(output_path, 'w', encoding='utf-8') as out:
    for i in range(1, actual_max + 1):
        if i in lines:
            out.write(lines[i] + '\n')
        else:
            out.write(f"// [GAP: LINE {i} NOT CAPTURED]\n")

print(f"\nWritten to: {output_path}")
print(f"Total lines written: {actual_max}")

# Show gap ranges for analysis
if gap_lines:
    ranges = []
    start = gap_lines[0]
    prev = gap_lines[0]
    for g in gap_lines[1:]:
        if g == prev + 1:
            prev = g
        else:
            ranges.append((start, prev))
            start = g
            prev = g
    ranges.append((start, prev))
    print(f"\nGap ranges ({len(ranges)} ranges):")
    for s, e in ranges[:20]:
        print(f"  Lines {s}-{e} ({e-s+1} lines)")
    if len(ranges) > 20:
        print(f"  ... and {len(ranges)-20} more ranges")
