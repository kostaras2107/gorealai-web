#!/usr/bin/env python3
"""Extract main.dart content from first Read operation in JSONL"""
import json, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"

# First pass: find the first Read tool_use id for main.dart
def is_main(path):
    if not path: return False
    p = path.lower().replace('\\', '/').replace('//', '/')
    return p.endswith('shoppilot/lib/main.dart') and 'worktree' not in p

# Scan first 300 lines to find structure
print("Scanning first 300 lines for structure...")
with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        if i > 300: break
        try:
            obj = json.loads(raw)
        except: continue
        t = obj.get('type', '')
        if t not in ('assistant', 'user', 'tool', 'system'): continue
        msg = obj.get('message', {})
        role = msg.get('role', t)
        content = msg.get('content', [])
        if isinstance(content, list) and content:
            for block in content:
                if isinstance(block, dict):
                    btype = block.get('type', '')
                    if btype == 'tool_result':
                        tid = block.get('tool_use_id', '')
                        # Check if this is for our Read
                        print(f"Line {i}: tool_result for id={tid[:20]}")
                        inner = block.get('content', [])
                        if isinstance(inner, list):
                            for ib in inner:
                                if isinstance(ib, dict) and ib.get('type') == 'text':
                                    text = ib.get('text', '')
                                    print(f"  text len={len(text)}, first 100: {text[:100]!r}")
                        elif isinstance(inner, str):
                            print(f"  content str len={len(inner)}, first 100: {inner[:100]!r}")
