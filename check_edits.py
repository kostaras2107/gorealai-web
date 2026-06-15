#!/usr/bin/env python3
import json, subprocess, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"

def is_main(path):
    if not path: return False
    p = path.lower().replace('\\', '/').replace('//', '/')
    return p.endswith('shoppilot/lib/main.dart') and 'worktree' not in p

# Get git version
result = subprocess.run(['git', '-C', r'C:\shoppilot', 'show', '23ce570:lib/main.dart'],
    capture_output=True, text=True, encoding='utf-8', errors='replace')
git_content = result.stdout
print(f"Git 23ce570 content: {len(git_content.splitlines())} lines")

# Collect all edits
edits = []
with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        try:
            obj = json.loads(raw)
        except: continue
        if obj.get('type') != 'assistant': continue
        msg = obj.get('message', {})
        for block in msg.get('content', []):
            if not isinstance(block, dict): continue
            if block.get('name') == 'Edit' and block.get('type') == 'tool_use':
                inp = block.get('input', {})
                if is_main(inp.get('file_path', '')):
                    edits.append((i, inp.get('old_string', ''), inp.get('new_string', ''), inp.get('replace_all', False)))

print(f"Total edits: {len(edits)}")

# Check how many of ALL edits can be found in git version
found = sum(1 for _, old, _, _ in edits if old in git_content)
print(f"Edits found in git 23ce570: {found}/{len(edits)}")

# Now try applying edits to git version and see how far we get
content = git_content
applied = 0
failed = 0
for i, (jsonl_i, old, new, replace_all) in enumerate(edits):
    if not old: continue
    if old in content:
        if replace_all:
            content = content.replace(old, new)
        else:
            content = content.replace(old, new, 1)
        applied += 1
    else:
        failed += 1

print(f"\nAfter applying to git 23ce570:")
print(f"  Applied: {applied}, Failed: {failed}")
print(f"  Final lines: {len(content.splitlines())}")

# Save result
with open(r'C:\shoppilot\lib\main_from_git.dart', 'w', encoding='utf-8') as f:
    f.write(content)
print("Saved to main_from_git.dart")
