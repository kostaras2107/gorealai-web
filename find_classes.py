#!/usr/bin/env python3
"""Find reads covering InAppNotifOverlay and ChatScreen classes"""
import sys, io, json, re
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

JSONL = r"C:\Users\bosinakos\.claude\projects\C--shoppilot--claude-worktrees-infallible-keller-8ca4d4\f5b96356-c969-492d-a13b-802cb96b2c69.jsonl"

def is_main(path):
    p = path.lower().replace('\\', '/').replace('//', '/')
    return (p.endswith('shoppilot/lib/main.dart') and
            'worktree' not in p and '.claude' not in p)

print("Scanning for InAppNotifOverlay body and ChatScreen...", flush=True)

found = {}

with open(JSONL, encoding='utf-8', errors='replace') as f:
    for i, raw in enumerate(f, 1):
        if i > 18617:
            break
        if i % 5000 == 0:
            print(f"  JSONL line {i}...", flush=True)
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
        start = fi.get('startLine', 1)
        num = fi.get('numLines', 0)
        total = fi.get('totalLines', 0)
        end = start + num

        # Check for key items
        has_chat = 'class ChatScreen' in content
        has_notif_full = 'class InAppNotifOverlay' in content and '_InAppNotifOverlayState' in content
        has_notif_state_body = '_InAppNotifOverlayState' in content and 'build' in content
        has_chat_state = 'class _ChatScreenState' in content
        has_audio_methods = '_startVoice' in content or 'startStream' in content

        if has_chat or has_notif_full or has_notif_state_body or has_chat_state or has_audio_methods:
            key = f"JSONL_{i}"
            found[key] = {
                'jsonl': i, 'start': start, 'end': end, 'total': total,
                'has_chat': has_chat,
                'has_notif_full': has_notif_full,
                'has_notif_state_body': has_notif_state_body,
                'has_chat_state': has_chat_state,
                'has_audio': has_audio_methods,
                'content': content
            }

print(f"\nFound {len(found)} relevant reads:")
for key, d in sorted(found.items()):
    print(f"\n  JSONL {d['jsonl']}: lines {d['start']}-{d['end']} of {d['total']}")
    print(f"    ChatScreen={d['has_chat']}, NotifFull={d['has_notif_full']}, NotifBody={d['has_notif_state_body']}, ChatState={d['has_chat_state']}, Audio={d['has_audio']}")

# Save the best ChatScreen read
chat_reads = [(k, d) for k, d in found.items() if d['has_chat']]
if chat_reads:
    best_chat = max(chat_reads, key=lambda x: x[1]['total'])
    print(f"\n=== BEST ChatScreen read: JSONL {best_chat[1]['jsonl']}, lines {best_chat[1]['start']}-{best_chat[1]['end']} of {best_chat[1]['total']} ===")
    lines = best_chat[1]['content'].split('\n')
    for j, line in enumerate(lines[:100]):
        print(f"{best_chat[1]['start']+j}: {line}")

# Save the best full InAppNotifOverlay read
notif_reads = [(k, d) for k, d in found.items() if d['has_notif_state_body']]
if notif_reads:
    best_notif = max(notif_reads, key=lambda x: x[1]['total'])
    print(f"\n=== BEST InAppNotifOverlay body read: JSONL {best_notif[1]['jsonl']}, lines {best_notif[1]['start']}-{best_notif[1]['end']} of {best_notif[1]['total']} ===")
    lines = best_notif[1]['content'].split('\n')
    for j, line in enumerate(lines[:100]):
        print(f"{best_notif[1]['start']+j}: {line}")
