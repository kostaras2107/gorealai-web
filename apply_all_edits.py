#!/usr/bin/env python3
"""Apply all 718 Edit operations from JSONL to reconstruct main.dart"""
import json, sys, io, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"
START_FILE = r"C:\shoppilot\.claude\worktrees\infallible-keller-8ca4d4\lib\main.dart"
OUTPUT_FILE = r"C:\shoppilot\lib\main_rebuilt.dart"

def is_main(path):
    if not path: return False
    p = path.lower().replace('\\', '/').replace('//', '/')
    return p.endswith('shoppilot/lib/main.dart') and 'worktree' not in p

# Load starting file
with open(START_FILE, encoding='utf-8', errors='replace') as f:
    content = f.read()
print(f"Starting file: {len(content.splitlines())} lines")

# Collect all Edit operations in order
print("Scanning JSONL for Edit operations...")
edits = []
with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        try:
            obj = json.loads(raw)
        except:
            continue
        if obj.get('type') == 'assistant':
            msg = obj.get('message', {})
            content_blocks = msg.get('content', [])
            if not isinstance(content_blocks, list): continue
            for block in content_blocks:
                if not isinstance(block, dict): continue
                if block.get('name') == 'Edit' and block.get('type') == 'tool_use':
                    inp = block.get('input', {})
                    fp = inp.get('file_path', '')
                    if is_main(fp):
                        old = inp.get('old_string', '')
                        new = inp.get('new_string', '')
                        replace_all = inp.get('replace_all', False)
                        edits.append((i, old, new, replace_all))

print(f"Found {len(edits)} Edit operations")

# Apply all edits in sequence
applied = 0
failed = 0
failures = []

for i, (jsonl_line, old, new, replace_all) in enumerate(edits):
    if not old:
        continue

    if replace_all:
        if old in content:
            content = content.replace(old, new)
            applied += 1
        else:
            failed += 1
            failures.append((jsonl_line, i, len(old), 'NOT FOUND (replace_all)'))
    else:
        if old in content:
            content = content.replace(old, new, 1)
            applied += 1
        else:
            failed += 1
            failures.append((jsonl_line, i, len(old), 'NOT FOUND'))

    if (i+1) % 100 == 0:
        lines = len(content.splitlines())
        print(f"  After {i+1} edits: {lines} lines, {applied} ok, {failed} failed")

final_lines = len(content.splitlines())
print(f"\nFinal: {final_lines} lines")
print(f"Applied: {applied}, Failed: {failed}")

if failures:
    print(f"\nFirst 10 failures:")
    for jsonl_line, edit_i, old_len, reason in failures[:10]:
        print(f"  Edit #{edit_i} (JSONL line {jsonl_line}): {reason}, old_string len={old_len}")

# Save output
with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
    f.write(content)
print(f"\nSaved to: {OUTPUT_FILE}")
print(f"File size: {os.path.getsize(OUTPUT_FILE)/1024:.0f}KB")
