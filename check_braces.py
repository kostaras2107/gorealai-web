#!/usr/bin/env python3
"""Check brace balance in main.dart"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

with open(r"C:\shoppilot\lib\main.dart", encoding='utf-8', errors='replace') as f:
    content = f.read()

depth = 0
in_string = False
in_comment = False
string_char = None
i = 0
problem_areas = []
chars_to_check = 8000  # First 8000 chars

while i < min(len(content), chars_to_check):
    c = content[i]

    # Handle multi-line comments
    if not in_string and content[i:i+2] == '/*':
        in_comment = True
        i += 2
        continue
    if in_comment and content[i:i+2] == '*/':
        in_comment = False
        i += 2
        continue
    if in_comment:
        i += 1
        continue

    # Handle line comments
    if not in_string and content[i:i+2] == '//':
        while i < len(content) and content[i] != '\n':
            i += 1
        continue

    # Handle strings (skip backslash escapes)
    if not in_string and c in ('"', "'"):
        in_string = True
        string_char = c
        i += 1
        continue
    if in_string and c == '\\':
        i += 2  # Skip escaped character
        continue
    if in_string and c == string_char:
        in_string = False
        i += 1
        continue
    if in_string:
        i += 1
        continue

    if c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth < 0:
            line_num = content[:i].count('\n') + 1
            problem_areas.append(f'Line {line_num}: depth went negative (extra }})')
            depth = 0

    i += 1

line_pos = content[:chars_to_check].count('\n') + 1
print(f"After first {chars_to_check} chars (up to ~line {line_pos}): brace depth = {depth}")
if problem_areas:
    for p in problem_areas:
        print(f"  PROBLEM: {p}")
else:
    print("  No extra } found in this range")

# Now check depth at specific line ranges
def check_depth_at_line(content, target_line):
    """Returns brace depth just before target_line"""
    lines = content.split('\n')
    depth = 0
    in_str = False
    str_char = None
    for line_no, line in enumerate(lines[:target_line], 1):
        i = 0
        while i < len(line):
            c = line[i]
            if line[i:i+2] == '//':
                break  # rest is comment
            if not in_str and c in ('"', "'"):
                in_str = True
                str_char = c
                i += 1
                continue
            if in_str and c == '\\':
                i += 2
                continue
            if in_str and c == str_char:
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
            i += 1
    return depth

print()
for check_line in [20, 25, 30, 35, 40, 50, 100, 150, 185, 200, 290, 310]:
    d = check_depth_at_line(content, check_line)
    print(f"Brace depth at end of line {check_line}: {d}")
