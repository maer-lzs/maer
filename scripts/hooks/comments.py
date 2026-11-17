"""The comments of a whole source file, by line, for the commit hook.

One reader per language: Python through its own tokenizer and syntax tree,
the C family (Swift, Kotlin, JavaScript, TypeScript) and shell through a
small state machine each. `comments(path, text)` answers a dict from line
number (1-based) to the comment text on that line, with its marker, and
raises `Unreadable` when the file cannot be read as its language: an open
string, an open block comment, a syntax error. The hook refuses such a file
as not read instead of letting it pass. Files of other languages answer
None.

Swift and JavaScript regex literals are read as literals: the extended
Swift form #/…/# always, the bare form /…/ where the language starts one
(after = ( , : [ { ; ! & | ? or return, on one line, not before a space and
not closing after a space). Python counts every string statement as a
comment, wherever it stands. Kotlin and JavaScript templates ${…} hold code.
Limits, named: a bare regex in another place counts as code; a shell
construct the machine does not know ends up as code, never as a comment.
"""
import ast
import io
import re
import tokenize


class Unreadable(Exception):
    pass


def comments(path, text):
    if path.endswith(".py"):
        return python_comments(text)
    if path.endswith((".swift", ".kt", ".kts", ".js", ".ts")):
        return c_family_comments(text, swift=path.endswith(".swift"),
                                 regex=path.endswith((".swift", ".js", ".ts")))
    if path.endswith((".sh", ".bash")):
        return shell_comments(text)
    return None


def _add(found, line, piece):
    found[line] = (found[line] + " " + piece) if line in found else piece


def python_comments(text):
    found = {}
    try:
        for token in tokenize.generate_tokens(io.StringIO(text).readline):
            if token.type == tokenize.COMMENT:
                _add(found, token.start[0], token.string)
        tree = ast.parse(text)
    except (tokenize.TokenError, SyntaxError, IndentationError) as error:
        raise Unreadable(f"Python does not parse: {error}")
    lines = text.split("\n")
    # Every statement that is only a string: docstrings of modules, classes
    # and functions, docstrings of attributes and blocks between statements.
    for node in ast.walk(tree):
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) \
                and isinstance(node.value.value, str):
            for number in range(node.lineno, (node.end_lineno or node.lineno) + 1):
                piece = lines[number - 1].strip().replace('"""', " ").replace("'''", " ").strip()
                if piece:
                    _add(found, number, "# " + piece)
    return found


def c_family_comments(text, swift, regex):
    """Line and nested block comments outside strings. Strings: "…" with
    escapes, triple-quoted multiline strings, in Swift raw strings with
    hashes and interpolation \\( … ), in Kotlin and JavaScript templates
    ${ … }; an interpolation holds code again."""
    found = {}
    i, n, line = 0, len(text), 1
    # A stack of open contexts: a string is (delimiter, hashes, 0), code
    # inside an interpolation is ("code", its opening bracket, depth).
    stack = []
    single_quotes = not swift
    closing = {"(": ")", "{": "}"}

    def at(s):
        return text.startswith(s, i)

    while i < n:
        c = text[i]
        if stack and stack[-1][0] == "code":
            # Code inside an interpolation: count its brackets to its end.
            opener = stack[-1][1]
            if c == opener:
                stack[-1] = ("code", opener, stack[-1][2] + 1)
            elif c == closing[opener]:
                depth = stack[-1][2] - 1
                if depth == 0:
                    stack.pop()
                    i += 1
                    continue
                stack[-1] = ("code", opener, depth)
        if stack and stack[-1][0] in ('"', '"""', "'", "`"):
            delimiter, hashes, _ = stack[-1]
            close = delimiter + "#" * hashes
            if c == "\n":
                if delimiter not in ('"""', "`"):
                    raise Unreadable(f"an open string at line {line}")
                line += 1
                i += 1
                continue
            if c == "\\" and text.startswith("#" * hashes, i + 1):
                after = i + 1 + hashes
                if swift and after < n and text[after] == "(":
                    stack.append(("code", "(", 1))
                    i = after + 1
                    continue
                i = after + 1
                continue
            if not swift and delimiter != "'" and at("${"):
                stack.append(("code", "{", 1))
                i += 2
                continue
            if at(close):
                stack.pop()
                i += len(close)
                continue
            i += 1
            continue
        # Code.
        if c == "\n":
            line += 1
            i += 1
            continue
        if at("//"):
            end = text.find("\n", i)
            end = n if end < 0 else end
            _add(found, line, text[i:end].strip())
            i = end
            continue
        if at("/*"):
            depth, j, start = 1, i + 2, i
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            if depth:
                raise Unreadable(f"an open block comment from line {line}")
            for k, piece in enumerate(text[start:j].split("\n")):
                if piece.strip():
                    _add(found, line + k, piece.strip())
            line += text.count("\n", start, j)
            i = j
            continue
        if swift and c == "#":
            m = re.match(r"#+", text[i:])
            hashes = len(m.group(0))
            rest = i + hashes
            if text.startswith("/", rest):
                end = text.find("/" + "#" * hashes, rest + 1)
                if end < 0:
                    raise Unreadable(f"an open regex literal at line {line}")
                line += text.count("\n", i, end)
                i = end + 1 + hashes
                continue
            if text.startswith('"""', rest):
                stack.append(('"""', hashes, 0))
                i = rest + 3
                continue
            if text.startswith('"', rest):
                stack.append(('"', hashes, 0))
                i = rest + 1
                continue
            i = rest
            continue
        if regex and c == "/" and bare_regex_starts(text, i):
            j = i + 1
            klass = 0
            while j < n and text[j] != "\n":
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == "[":
                    klass += 1
                elif text[j] == "]" and klass:
                    klass -= 1
                elif text[j] == "/" and not klass:
                    break
                j += 1
            # A regex literal does not close after a space: then the slash
            # was a division, and what follows is code.
            if j < n and text[j] == "/" and text[j - 1] not in " \t":
                i = j + 1
                continue
        if at('"""'):
            stack.append(('"""', 0, 0))
            i += 3
            continue
        if c == '"':
            stack.append(('"', 0, 0))
            i += 1
            continue
        if single_quotes and c == "`":
            stack.append(("`", 0, 0))
            i += 1
            continue
        if single_quotes and c == "'":
            stack.append(("'", 0, 0))
            i += 1
            continue
        i += 1
    if stack:
        raise Unreadable("an open string or interpolation at the end of the file")
    return found


REGEX_BEFORE = set("=(,:[{;!&|?")


def bare_regex_starts(text, i):
    """Whether a slash in Swift code opens a bare regex literal: not a comment
    or a division, after an operator or opening that takes an expression, or
    after return, and not followed by a space."""
    if text.startswith(("//", "/*"), i) or i + 1 >= len(text) or text[i + 1] in " \t\n":
        return False
    j = i - 1
    while j >= 0 and text[j] in " \t":
        j -= 1
    if j < 0 or text[j] == "\n":
        return True
    if text[j] in REGEX_BEFORE:
        return True
    return text[max(0, j - 5):j + 1] == "return"


HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
WORD_START = set(" \t;|&()<>\n")


def shell_comments(text):
    """`#` at the start of a word, outside quotes, outside heredoc bodies."""
    found = {}
    lines = text.split("\n")
    pending = []  # heredoc words opened on the current line: (word, strip tabs)
    number = 0
    quote = None
    while number < len(lines):
        raw = lines[number]
        number += 1
        if not quote and pending:
            # The body of a heredoc: content, until its word stands alone.
            word, strip = pending[0]
            if (raw.lstrip("\t") if strip else raw) == word:
                pending.pop(0)
            continue
        i, n = 0, len(raw)
        while i < n:
            c = raw[i]
            if quote == "'":
                if c == "'":
                    quote = None
                i += 1
                continue
            if quote in ('"', "$'"):
                if c == "\\":
                    i += 2
                    continue
                if (quote == '"' and c == '"') or (quote == "$'" and c == "'"):
                    quote = None
                i += 1
                continue
            if c == "\\":
                i += 2
                continue
            if c == "'":
                quote = "'"
                i += 1
                continue
            if c == "$" and raw.startswith("$'", i):
                quote = "$'"
                i += 2
                continue
            if c == '"':
                quote = '"'
                i += 1
                continue
            if c == "#" and (i == 0 or raw[i - 1] in WORD_START):
                if not (number == 1 and raw.startswith("#!")):
                    _add(found, number, raw[i:].strip())
                break
            # A here string, and a shift inside arithmetic, open no heredoc.
            if raw.startswith("<<<", i):
                i += 3
                continue
            if raw.startswith("((", i):
                end = raw.find("))", i + 2)
                i = n if end < 0 else end + 2
                continue
            m = HEREDOC.match(raw, i)
            if m:
                pending.append((m.group(3), m.group(1) == "-"))
                i = m.end()
                continue
            i += 1
    if quote:
        raise Unreadable("an open quote at the end of the file")
    if pending:
        raise Unreadable(f"an open heredoc: {pending[0][0]}")
    return found
