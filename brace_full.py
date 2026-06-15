#!/usr/bin/env python3
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

with open(r"C:\shoppilot\lib\main.dart", encoding='utf-8', errors='replace') as f:
    content = f.read()

lines = content.split('\n')
depth = 0
in_str = False
str_char = None
triple = False
problems = []

for line_no, line in enumerate(lines, 1):
    i = 0
    while i < len(line):
        c = line[i]
        # Skip // line comments
        if not in_str and line[i:i+2] == '//':
            break
        # Triple double quotes
        if not in_str and line[i:i+3] == '"""':
            in_str = True
            triple = True
            str_char = '"""'
            i += 3
            continue
        # Triple single quotes
        if not in_str and line[i:i+3] == "'''":
            in_str = True
            triple = True
            str_char = "'''"
            i += 3
            continue
        if in_str and triple and line[i:i+3] == str_char:
            in_str = False
            triple = False
            i += 3
            continue
        # Single char strings
        if not in_str and c in ('"', "'"):
            in_str = True
            str_char = c
            triple = False
            i += 1
            continue
        if in_str and not triple:
            if c == '\\':
                i += 2
                continue
            if c == str_char:
                in_str = False
                i += 1
                continue
        if in_str:
            i += 1
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth < 0:
                problems.append(f'Line {line_no}: depth went negative (extra }})')
                depth = 0
        i += 1

    if line_no % 2000 == 0:
        print(f'Line {line_no}: depth={depth}')

print(f'\nFinal depth: {depth}')
print(f'Total lines: {len(lines)}')
if problems:
    print(f'\nExtra }} found at:')
    for p in problems[:20]:
        print(f'  {p}')
else:
    print('No extra }} found')

if depth > 0:
    print(f'\nFile has {depth} unclosed brace(s) - classes/methods not closed!')
