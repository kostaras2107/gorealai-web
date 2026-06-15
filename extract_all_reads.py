#!/usr/bin/env python3
"""Extract all Read results for main.dart from JSONL and reconstruct the file"""
import json, sys, io, re
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"

def is_main(path):
    if not path: return False
    p = path.lower().replace('\\', '/').replace('//', '/')
    return p.endswith('shoppilot/lib/main.dart') and 'worktree' not in p

# Step 1: Collect all Read tool_use ids for main.dart with their line offsets
read_calls = {}  # id -> offset (0 if no offset)
with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        try:
            obj = json.loads(raw)
        except: continue
        if obj.get('type') != 'assistant': continue
        for block in obj.get('message', {}).get('content', []):
            if isinstance(block, dict) and block.get('name') == 'Read' and block.get('type') == 'tool_use':
                inp = block.get('input', {})
                if is_main(inp.get('file_path', '')):
                    tool_id = block.get('id')
                    offset = inp.get('offset', 0) or 0
                    limit = inp.get('limit', 2000) or 2000
                    read_calls[tool_id] = (offset, limit, i)

print(f"Found {len(read_calls)} Read calls for main.dart")

# Step 2: Find the corresponding tool_results
# In JSONL, tool results are in 'user' messages
segments = {}  # offset -> content_lines

with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        try:
            obj = json.loads(raw)
        except: continue
        if obj.get('type') != 'user': continue
        msg = obj.get('message', {})
        for block in msg.get('content', []):
            if not isinstance(block, dict): continue
            if block.get('type') != 'tool_result': continue
            tid = block.get('tool_use_id', '')
            if tid not in read_calls: continue

            offset, limit, call_line = read_calls[tid]
            inner = block.get('content', '')
            if isinstance(inner, list):
                for ib in inner:
                    if isinstance(ib, dict) and ib.get('type') == 'text':
                        inner = ib.get('text', '')
                        break
            if not isinstance(inner, str): continue

            # Parse line-numbered content: "  N\tcontent"
            parsed = {}
            for line in inner.split('\n'):
                m = re.match(r'^\s*(\d+)\t(.*)$', line)
                if m:
                    lnum = int(m.group(1))
                    content = m.group(2)
                    parsed[lnum] = content

            if parsed:
                min_l = min(parsed.keys())
                max_l = max(parsed.keys())
                print(f"JSONL line {i}: Read result for call line {call_line}, offset={offset}, covers lines {min_l}-{max_l} ({len(parsed)} lines)")
                segments[tid] = parsed

print(f"\nTotal Read results captured: {len(segments)}")

# Step 3: Reconstruct file from all segments
# Merge all line data
all_lines = {}
for tid, parsed in segments.items():
    for lnum, content in parsed.items():
        if lnum not in all_lines:
            all_lines[lnum] = content

if all_lines:
    max_line = max(all_lines.keys())
    min_line = min(all_lines.keys())
    print(f"Line coverage: {min_line} to {max_line}")

    # Find gaps
    missing = [l for l in range(min_line, max_line+1) if l not in all_lines]
    print(f"Missing lines: {len(missing)}")
    if missing[:20]:
        print(f"First missing lines: {missing[:20]}")

    # Save what we have
    out_path = r'C:\shoppilot\lib\main_from_reads.dart'
    with open(out_path, 'w', encoding='utf-8') as f:
        for lnum in range(1, max_line+1):
            f.write(all_lines.get(lnum, f'// MISSING LINE {lnum}') + '\n')
    print(f"\nSaved to {out_path}")
    print(f"Total lines written: {max_line}")
