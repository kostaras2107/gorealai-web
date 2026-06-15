#!/usr/bin/env python3
"""
Reconstruct main.dart by applying ALL Edit tool calls from the JSONL
to the May 8 base file (commit 23ce570 = worktree copy).
This is the CORRECT approach: replays all edits in chronological order.
"""
import json, sys

JSONL_PATH = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"
BASE_FILE = r"C:\shoppilot\.claude\worktrees\infallible-keller-8ca4d4\lib\main.dart"
OUTPUT_FILE = r"C:\shoppilot\lib\main_from_edits.dart"
STOP_LINE = 18617

def is_main_dart(path):
    """Check if path is the main project main.dart (not worktree)."""
    p = path.lower().replace('\\', '/').replace('//', '/')
    # Must end with shoppilot/lib/main.dart
    # Must NOT be in worktree or .claude directory
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and
            '.claude' not in p and
            '_test' not in p)

print(f"Loading base file: {BASE_FILE}", flush=True)
with open(BASE_FILE, encoding='utf-8') as f:
    content = f.read()
print(f"Base file: {len(content)} chars, {content.count(chr(10))+1} lines")

print(f"\nScanning JSONL for Edit calls targeting main.dart...", flush=True)
edits = []  # list of (jsonl_lineno, old_string, new_string)

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

            old_string = inp.get('old_string', '')
            new_string = inp.get('new_string', '')
            replace_all = inp.get('replace_all', False)

            edits.append((jsonl_lineno, old_string, new_string, replace_all))

print(f"Found {len(edits)} Edit calls for main.dart")
if not edits:
    print("ERROR: No edits found! Check path filter.")
    sys.exit(1)

# Show first and last edit JSONL line numbers
print(f"First edit at JSONL line {edits[0][0]}")
print(f"Last edit at JSONL line {edits[-1][0]}")

# Apply edits in order
print(f"\nApplying edits...", flush=True)
failed = []
applied = 0

for i, (jsonl_lineno, old_str, new_str, replace_all) in enumerate(edits):
    if not old_str:
        continue  # Skip edits with empty old_string

    if replace_all:
        count = content.count(old_str)
        if count > 0:
            content = content.replace(old_str, new_str)
            applied += 1
        else:
            failed.append((jsonl_lineno, f"replace_all: '{old_str[:80]}'"))
    else:
        if old_str in content:
            # Replace only first occurrence
            content = content.replace(old_str, new_str, 1)
            applied += 1
        else:
            failed.append((jsonl_lineno, f"'{old_str[:80]}'"))

    if (i + 1) % 100 == 0:
        line_count = content.count('\n') + 1
        print(f"  Applied {i+1}/{len(edits)} edits, current size: {line_count} lines, {len(failed)} failed", flush=True)

print(f"\nDone!")
print(f"Applied: {applied}/{len(edits)}")
print(f"Failed: {len(failed)}")
print(f"Final size: {content.count(chr(10))+1} lines, {len(content)} chars")

# Write result
with open(OUTPUT_FILE, 'w', encoding='utf-8') as out:
    out.write(content)
print(f"\nWritten to: {OUTPUT_FILE}")

if failed:
    print(f"\nFailed edits (first 20):")
    for jl, s in failed[:20]:
        print(f"  JSONL line {jl}: {s}")
    if len(failed) > 20:
        print(f"  ... and {len(failed)-20} more")
