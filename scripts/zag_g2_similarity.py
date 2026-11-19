#!/usr/bin/env python3
"""G2 licence review: how much of one source file appears in another.

    python3 -I scripts/zag_g2_similarity.py <file> <comparison file> [...]

For each comparison file it prints:
  - shared string literals (distinct, longer than three characters);
  - shared comments of four words or more (compared as lower-case words);
  - the three longest common token runs, after removing string literals and
    comments and lower-casing identifiers (greedy, non-overlapping).
Shared literals are mostly protocol names any implementation must use; long
identical token runs and copied comments suggest copied code. Evidence for a
reviewer, not a conclusion. Reads the files as data only.
"""
import re
import sys

STRING = re.compile(r'r#*"(?:.|\n)*?"#*|"(?:\\.|[^"\\])*"|`[^`]*`')
LINE_COMMENT = re.compile(r'//[^\n]*')
BLOCK_COMMENT = re.compile(r'/\*(?:.|\n)*?\*/|/\+(?:.|\n)*?\+/')
TOKEN = re.compile(r'[A-Za-z_][A-Za-z0-9_]*|\d+|\S')


def literals(text):
    return {m.group(0).strip('r#"`') for m in STRING.finditer(text) if len(m.group(0).strip('r#"`')) > 3}


def comments(text):
    found = set()
    for m in list(LINE_COMMENT.finditer(text)) + list(BLOCK_COMMENT.finditer(text)):
        words = re.findall(r'[a-z0-9]+', m.group(0).lower())
        if len(words) >= 4:
            found.add(' '.join(words))
    return found


def tokens(text):
    text = BLOCK_COMMENT.sub(' ', text)
    text = STRING.sub(' S ', text)
    text = LINE_COMMENT.sub(' ', text)
    return [t.lower() for t in TOKEN.findall(text)]


def longest_runs(a, b, count=3, k=3):
    index = {}
    for j in range(len(b) - k + 1):
        index.setdefault(tuple(b[j:j + k]), []).append(j)
    runs = []
    for i in range(len(a) - k + 1):
        for j in index.get(tuple(a[i:i + k]), ()):
            if i and j and a[i - 1] == b[j - 1]:
                continue  # not the start of a maximal run
            n = k
            while i + n < len(a) and j + n < len(b) and a[i + n] == b[j + n]:
                n += 1
            runs.append((n, i))
    chosen, used = [], set()
    for n, i in sorted(runs, reverse=True):
        span = set(range(i, i + n))
        if span & used:
            continue
        chosen.append(n)
        used |= span
        if len(chosen) == count:
            break
    return chosen


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    source = open(argv[1], encoding='utf-8', errors='replace').read()
    for other_path in argv[2:]:
        other = open(other_path, encoding='utf-8', errors='replace').read()
        print(f'{argv[1]}  vs  {other_path}')
        print(f'  shared literals: {len(literals(source) & literals(other))}')
        print(f'  shared comments (4+ words): {len(comments(source) & comments(other))}')
        print(f'  longest common token runs: {longest_runs(tokens(source), tokens(other))}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
