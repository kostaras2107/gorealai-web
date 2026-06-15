#!/usr/bin/env python3
"""
Extract specific class definitions from JSONL Read results.
We look for class declarations and extract full code blocks.
"""
import json, re, sys

JSONL_PATH = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"
STOP_LINE = 18617

# Classes we're looking for that are MISSING from the 8499-line version
TARGET_CLASSES = [
    'InAppNotifOverlay', '_InAppNotif', '_InAppNotifOverlayState',
    'MessagesScreen', '_MessagesScreenState',
    '_ChatScreen', '_ChatScreenState',
    'ReminderService',
    'AuthService',
]

def is_main(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

print("Searching JSONL for class definitions...", flush=True)

# Store: class_name -> list of (jsonl_lineno, content_with_context)
found_classes = {c: [] for c in TARGET_CLASSES}

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

        content = fi.get('content', '')
        if not content:
            continue

        start_line = fi.get('startLine', 1)
        total_lines = fi.get('totalLines', 0)

        for cls in TARGET_CLASSES:
            # Check if this class appears in the content
            pattern = rf'class {cls}\b'
            if re.search(pattern, content):
                found_classes[cls].append((jsonl_lineno, start_line, total_lines, content))

# Print results
for cls in TARGET_CLASSES:
    reads = found_classes[cls]
    if reads:
        # Use the most recent read (highest JSONL line)
        best = max(reads, key=lambda x: x[0])
        jl, sl, tl, content = best
        print(f"\n{'='*60}")
        print(f"CLASS: {cls}")
        print(f"Found in {len(reads)} reads. Best: JSONL line {jl}, file lines {sl}+, total={tl}")
        # Find the class in the content
        lines = content.split('\n')
        for i, line in enumerate(lines):
            if re.search(rf'class {cls}\b', line):
                start = max(0, i - 2)
                end = min(len(lines), i + 50)
                preview = '\n'.join(f"  {sl+start+j}: {lines[start+j]}" for j in range(end-start))
                print(f"Preview (lines {sl+start}-{sl+end}):")
                print(preview)
                break
    else:
        print(f"\nCLASS {cls}: NOT FOUND in any read")

# Also search for key features
print(f"\n{'='*60}")
print("Searching for Messages tab, Audio recording, kFreeForAll...")
feature_searches = {
    'Messages tab': r"Μηνύματα|MessagesTab|messages.*tab",
    'Audio recording': r"record\.|AudioRecorder|_audioRec|\.startStream",
    'kFreeForAll usage': r'kFreeForAll',
    'Mini CV': r'Mini CV|miniCV|mini_cv',
    'Social Media': r'Social Media|socialMedia',
}

for feature, pattern in feature_searches.items():
    last_found = None
    with open(JSONL_PATH, encoding='utf-8', errors='replace') as f:
        for jsonl_lineno, raw in enumerate(f, 1):
            if jsonl_lineno > STOP_LINE:
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
            if not fi or not is_main(fi.get('filePath', '')):
                continue
            content = fi.get('content', '')
            if re.search(pattern, content, re.IGNORECASE):
                last_found = (jsonl_lineno, fi.get('startLine', 0), fi.get('totalLines', 0))

    if last_found:
        print(f"  {feature}: found in JSONL {last_found[0]}, lines from {last_found[1]} (total={last_found[2]})")
    else:
        print(f"  {feature}: NOT FOUND")
