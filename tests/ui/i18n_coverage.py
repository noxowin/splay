"""Static interface-translation coverage for the three runtime Lua scripts.

Each script keeps Chinese source text as the lookup key: T('...') translates at
use time and N_('...') marks table values that are translated when read. This
check fails when such a key has no entry in the script's English table, when an
entry is unused or changes the format placeholders, and when a Chinese string
literal appears outside T/N_ and the table. A line ending in the comment
'i18n: fixed' holds text shown unchanged in both languages (language names).
Comments are ignored. No player is needed.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ('scripts/splay.lua', 'scripts/splay_overlay.lua', 'scripts/splay_playlist.lua')
CJK = re.compile('[　-〿぀-ヿ㐀-䶿一-鿿豈-﫿＀-￯]')
PLACEHOLDER = re.compile(r'%[-+ #0-9.]*[a-zA-Z%]')
ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', 'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v',
           '\\': '\\', '"': '"', "'": "'", '\n': '\n'}


def unescape(body):
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c != '\\':
            out.append(c); i += 1; continue
        n = body[i + 1]
        if n.isdigit():
            digits = re.match(r'\d{1,3}', body[i + 1:]).group()
            out.append(chr(int(digits))); i += 1 + len(digits)
        elif n == 'x':
            out.append(chr(int(body[i + 2:i + 4], 16))); i += 4
        else:
            out.append(ESCAPES.get(n, n)); i += 2
    # Byte escapes form UTF-8 sequences; keep plain text as it is.
    text = ''.join(out)
    try:
        return text.encode('latin-1').decode('utf-8')
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text


def tokens(source):
    """Yield (kind, value, line) for strings, names and single punctuation."""
    i, line, size = 0, 1, len(source)
    long_open = re.compile(r'\[(=*)\[')
    while i < size:
        c = source[i]
        if c == '\n':
            line += 1; i += 1; continue
        if c.isspace():
            i += 1; continue
        if source.startswith('--', i):
            match = long_open.match(source, i + 2)
            if match:
                end = source.index(']' + match.group(1) + ']', match.end())
                end += len(match.group(1)) + 2
            else:
                end = source.find('\n', i)
                end = size if end < 0 else end
            yield 'comment', source[i:end], line
            line += source.count('\n', i, end); i = end; continue
        match = long_open.match(source, i)
        if match:
            end = source.index(']' + match.group(1) + ']', match.end())
            yield 'string', source[match.end():end], line
            stop = end + len(match.group(1)) + 2
            line += source.count('\n', i, stop); i = stop; continue
        if c in '\'"':
            j = i + 1
            while source[j] != c:
                j += 2 if source[j] == '\\' else 1
            yield 'string', unescape(source[i + 1:j]), line
            line += source.count('\n', i, j); i = j + 1; continue
        match = re.compile(r'[A-Za-z_][A-Za-z0-9_]*').match(source, i)
        if match:
            yield 'name', match.group(), line; i = match.end(); continue
        yield 'punct', c, line; i += 1


def check(path):
    source = (ROOT / path).read_text(encoding='utf-8')
    all_tokens = list(tokens(source))
    fixed = {line for kind, value, line in all_tokens if kind == 'comment' and value.rstrip().endswith('i18n: fixed')}
    code = [t for t in all_tokens if t[0] != 'comment']
    errors, table, table_span = [], {}, None
    for i in range(len(code) - 3):
        if code[i][1] == 'local' and code[i + 1][1] == 'EN' and code[i + 2][1] == '=' and code[i + 3][1] == '{':
            depth, j = 0, i + 3
            while True:
                if code[j][0] == 'punct' and code[j][1] == '{': depth += 1
                if code[j][0] == 'punct' and code[j][1] == '}':
                    depth -= 1
                    if depth == 0: break
                j += 1
            table_span = (i + 3, j)
            k = i + 4
            while k < j:
                if (code[k][1] == '[' and code[k + 1][0] == 'string' and code[k + 2][1] == ']' and
                        code[k + 3][1] == '=' and code[k + 4][0] == 'string'):
                    key, value = code[k + 1][1], code[k + 4][1]
                    if key in table:
                        errors.append(f'{path}:{code[k][2]}: duplicate English entry {key!r}')
                    table[key] = value
                    if PLACEHOLDER.findall(key) != PLACEHOLDER.findall(value):
                        errors.append(f'{path}:{code[k][2]}: placeholders differ: {key!r} -> {value!r}')
                    if CJK.search(value):
                        errors.append(f'{path}:{code[k][2]}: English entry contains Chinese: {value!r}')
                    k += 5
                else:
                    k += 1
            break
    if table_span is None:
        return [f'{path}: no "local EN={{...}}" English table']
    used = set()
    for i, (kind, value, line) in enumerate(code):
        if kind != 'string' or table_span[0] < i < table_span[1]:
            continue
        keyed = (i >= 2 and code[i - 1][1] == '(' and code[i - 2][0] == 'name' and code[i - 2][1] in ('T', 'N_')
                 and i + 1 < len(code) and code[i + 1][1] == ')')
        if keyed:
            used.add(value)
            if value not in table:
                errors.append(f'{path}:{line}: no English entry for {value!r}')
        elif CJK.search(value) and line not in fixed:
            errors.append(f'{path}:{line}: Chinese literal outside T()/N_(): {value!r}')
    for key in sorted(set(table) - used):
        errors.append(f'{path}: unused English entry {key!r}')
    return errors, len(used)


# Reports quote Chinese and typographic characters; a legacy console code page
# must not turn a coverage failure into an encoding error.
sys.stdout.reconfigure(errors='backslashreplace')
failures, summary = [], []
for script in SCRIPTS:
    result = check(script)
    if isinstance(result, list):
        failures += result; continue
    errors, count = result
    failures += errors
    summary.append(f'{Path(script).name} {count}')
if failures:
    print('\n'.join(failures))
    raise SystemExit(f'Interface translation coverage: {len(failures)} problem(s)')
print('Interface translation coverage passed: every T()/N_() key has an English entry, placeholders match, '
      'no Chinese literals outside lookups (keys: ' + ', '.join(summary) + ')')
