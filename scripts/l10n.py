#!/usr/bin/env python3
# The app's texts in one Excel workbook for translation and review, and the
# way back into the string catalogs.
#
# `export <workbook.xlsx>` writes two sheets. "Terms" comes first: the words
# every translation keeps the same (docs/l10n/terms.csv), with a proposal for
# how Siri hears the app's name in each language. "Texts" holds every
# translatable text of the three catalogs as one row: Localizable (a plural
# form is a row of its own), AppShortcuts (one Siri phrase per row) and
# InfoPlist. Its columns are the id, the catalog's comment, English, German,
# the new languages and one "checked" column per new language.
#
# `import <workbook.xlsx>` reads the sheet "Texts" of a returned workbook and
# writes back only what changed in the new languages. A row whose checked
# cell says yes (also `ja` or `x`) becomes `translated`, every other written
# cell `needs_review`. It refuses a cell whose placeholders do not match the
# English text, an id it does not know, and any change to English or German:
# English is the key itself, and German is kept in Xcode. An empty cell
# changes nothing. A catalog is written only when something in it changed,
# in the form Xcode writes.
#
# The workbook is written and read with the standard library alone: a zip of
# XML parts. Cells are written as inline strings; a workbook saved by Excel
# keeps its strings in a shared table, and the reader takes both.
#
# Usage: l10n.py export <workbook.xlsx>
#        l10n.py import <workbook.xlsx>
#        l10n.py --self-check     export, import, nothing changes, in both cell forms
import csv
import json
import os
import re
import sys
import tempfile
import zipfile
from xml.etree import ElementTree
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGS = ["Localizable", "AppShortcuts", "InfoPlist"]
NEW = ["es", "fr", "it"]
COLUMNS = ["id", "note", "en", "de"] + NEW + ["checked_" + l for l in NEW]
TERMS = os.path.join(ROOT, "docs", "l10n", "terms.csv")
CHECKED = {"yes", "ja", "x"}
# The plural forms of a row, in the order a reader expects them.
FORMS = ["zero", "one", "two", "few", "many", "other"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|q|z|t|j)?[@dDuUxXoOfeEgGcCsSaAp]|\$\{\w+\}")
MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
RELS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS = {"m": MAIN}


def path(name):
    return os.path.join(ROOT, "Sources", name + ".xcstrings")


def load(name):
    with open(path(name), encoding="utf-8") as f:
        return json.load(f)


def dump(catalog):
    return json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : "))


def placeholders(text):
    """The placeholders of a text by kind, position numbers left out."""
    kinds = [re.sub(r"^%\d+\$", "%", p) for p in PLACEHOLDER.findall(text)]
    return sorted(kinds)


def unit(localization):
    return (localization or {}).get("stringUnit") or {}


def rows():
    """Every translatable text as (id, comment, {language: (value, state)})."""
    out = []
    for name in CATALOGS:
        for key, entry in load(name)["strings"].items():
            if entry.get("shouldTranslate") is False:
                continue
            comment = entry.get("comment", "")
            locs = entry.get("localizations", {})
            plurals = {l: loc["variations"]["plural"] for l, loc in locs.items()
                       if "plural" in loc.get("variations", {})}
            sets = {l: loc["stringSet"] for l, loc in locs.items() if "stringSet" in loc}
            if plurals:
                forms = sorted({f for p in plurals.values() for f in p}, key=FORMS.index)
                for form in forms:
                    cells = {l: (unit(p.get(form)).get("value", ""), unit(p.get(form)).get("state", ""))
                             for l, p in plurals.items()}
                    cells.setdefault("en", (key, ""))
                    out.append((f"{name}/{key}#{form}", comment, cells))
            elif sets:
                longest = max(len(s.get("values", [])) for s in sets.values())
                for index in range(longest):
                    cells = {l: ((s.get("values") or [])[index] if index < len(s.get("values") or []) else "",
                                 s.get("state", "")) for l, s in sets.items()}
                    out.append((f"{name}/{key}#{index + 1}", comment, cells))
            else:
                cells = {l: (unit(loc).get("value", ""), unit(loc).get("state", "")) for l, loc in locs.items()}
                cells.setdefault("en", (key, ""))
                out.append((f"{name}/{key}", comment, cells))
    return out


def terms():
    """The term list: a header and its rows, as the repo keeps them."""
    with open(TERMS, encoding="utf-8", newline="") as f:
        return list(csv.reader(f, delimiter=";"))


# Workbook writing.

def column(index):
    """The letters of a zero-based column index (0 is A, 26 is AA)."""
    letters = ""
    index += 1
    while index:
        index, rest = divmod(index - 1, 26)
        letters = chr(65 + rest) + letters
    return letters


def sheet_xml(table):
    out = [f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet xmlns="{MAIN}">',
           '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" '
           'state="frozen"/></sheetView></sheetViews><sheetData>']
    for r, values in enumerate(table, start=1):
        out.append(f'<row r="{r}">')
        for c, value in enumerate(values):
            if value == "":
                continue
            style = ' s="1"' if r == 1 else ""
            out.append(f'<c r="{column(c)}{r}" t="inlineStr"{style}><is><t xml:space="preserve">'
                       f'{escape(value)}</t></is></c>')
        out.append("</row>")
    out.append("</sheetData></worksheet>")
    return "".join(out)


def write_workbook(target, sheets):
    """Writes `sheets` [(name, rows)] as an .xlsx file; the first row of each is bold and stays in view."""
    names = [name for name, _ in sheets]
    parts = {
        "[Content_Types].xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            '<Override PartName="/xl/styles.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
            + "".join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" '
                      'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
                      for i in range(1, len(sheets) + 1))
            + "</Types>"),
        "_rels/.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
            'officeDocument" Target="xl/workbook.xml"/></Relationships>'),
        "xl/workbook.xml": (
            f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<workbook xmlns="{MAIN}" xmlns:r="{RELS}">'
            "<sheets>" + "".join(f'<sheet name="{escape(n)}" sheetId="{i}" r:id="rId{i}"/>'
                                 for i, n in enumerate(names, start=1))
            + "</sheets></workbook>"),
        "xl/_rels/workbook.xml.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + "".join(f'<Relationship Id="rId{i}" Type="{RELS}/worksheet" Target="worksheets/sheet{i}.xml"/>'
                      for i in range(1, len(sheets) + 1))
            + f'<Relationship Id="rId{len(sheets) + 1}" Type="{RELS}/styles" Target="styles.xml"/>'
            "</Relationships>"),
        "xl/styles.xml": (
            f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<styleSheet xmlns="{MAIN}">'
            '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
            '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
            '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
            '<borders count="1"><border/></borders>'
            '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
            '<cellXfs count="2"><xf fontId="0"/><xf fontId="1" applyFont="1"/></cellXfs>'
            "</styleSheet>"),
    }
    for i, (_, table) in enumerate(sheets, start=1):
        parts[f"xl/worksheets/sheet{i}.xml"] = sheet_xml(table)
    os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as book:
        for name, text in parts.items():
            book.writestr(name, text)
    return target


# Workbook reading.

def cell_text(cell, shared):
    kind = cell.get("t")
    if kind == "inlineStr":
        return "".join(t.text or "" for t in cell.iter(f"{{{MAIN}}}t"))
    value = cell.find("m:v", NS)
    if value is None or value.text is None:
        return ""
    if kind == "s":
        return shared[int(value.text)]
    return value.text


def column_index(reference):
    letters = re.match(r"[A-Z]+", reference).group(0)
    index = 0
    for letter in letters:
        index = index * 26 + ord(letter) - 64
    return index - 1


def read_sheet(source, wanted):
    """The rows of the sheet named `wanted` as lists of text; empty cells are empty text."""
    with zipfile.ZipFile(source) as book:
        workbook = ElementTree.fromstring(book.read("xl/workbook.xml"))
        relations = ElementTree.fromstring(book.read("xl/_rels/workbook.xml.rels"))
        targets = {r.get("Id"): r.get("Target") for r in relations}
        sheet = next((s for s in workbook.iter(f"{{{MAIN}}}sheet") if s.get("name") == wanted), None)
        if sheet is None:
            raise ValueError(f"the workbook has no sheet named {wanted}")
        target = targets[sheet.get(f"{{{RELS}}}id")].lstrip("/")
        part = target if target.startswith("xl/") else "xl/" + target
        shared = []
        if "xl/sharedStrings.xml" in book.namelist():
            table = ElementTree.fromstring(book.read("xl/sharedStrings.xml"))
            shared = ["".join(t.text or "" for t in item.iter(f"{{{MAIN}}}t"))
                      for item in table.findall("m:si", NS)]
        data = ElementTree.fromstring(book.read(part))
    out = []
    for row in data.iter(f"{{{MAIN}}}row"):
        values = {}
        for position, cell in enumerate(row.findall("m:c", NS)):
            reference = cell.get("r")
            index = column_index(reference) if reference else position
            values[index] = cell_text(cell, shared)
        out.append([values.get(i, "") for i in range(max(values) + 1)] if values else [])
    return out


# The two directions.

def export(target):
    table = [COLUMNS]
    for ident, comment, cells in rows():
        values = [cells.get(l, ("", ""))[0] for l in ["en", "de"] + NEW]
        checked = ["yes" if cells.get(l, ("", ""))[1] == "translated" else "" for l in NEW]
        table.append([ident, comment] + values + checked)
    return write_workbook(target, [("Terms", terms()), ("Texts", table)])


def split_id(ident):
    name, _, rest = ident.partition("/")
    key, mark, part = rest.rpartition("#") if "#" in rest else (rest, "", "")
    return name, (key if mark else rest), (part if mark else "")


def import_workbook(source):
    sheet = read_sheet(source, "Texts")
    header = sheet[0] if sheet else []
    missing = [c for c in COLUMNS if c not in header]
    if missing:
        return [], [f"the sheet Texts lacks the columns {missing}"]
    table = [{name: (row[i] if i < len(row) else "") for i, name in enumerate(header)} for row in sheet[1:]]
    known = {ident: (comment, cells) for ident, comment, cells in rows()}
    catalogs = {name: load(name) for name in CATALOGS}
    written, refused = [], []
    phrases = {}  # (catalog, key, language) -> {index: (text, checked)}
    for row in table:
        ident = row.get("id", "")
        if not ident:
            continue
        if ident not in known:
            refused.append(f"{ident}: unknown id")
            continue
        _, cells = known[ident]
        changed_source = [l for l in ["en", "de"] if (row.get(l) or "") != cells.get(l, ("", ""))[0]]
        if changed_source:
            refused.append(f"{ident}: {', '.join(changed_source)} changed, that is not an import")
            continue
        name, key, part = split_id(ident)
        entry = catalogs[name]["strings"][key]
        for language in NEW:
            text = row.get(language) or ""
            checked = (row.get("checked_" + language) or "").strip().lower() in CHECKED
            state = "translated" if checked else "needs_review"
            if name == "AppShortcuts":
                phrases.setdefault((name, key, language), {})[int(part)] = (text, checked)
                continue
            if not text:
                continue
            english = cells.get("en", ("", ""))[0]
            if placeholders(text) != placeholders(english):
                refused.append(f"{ident} [{language}]: placeholders {placeholders(text)} against {placeholders(english)}")
                continue
            locs = entry.setdefault("localizations", {})
            if part:
                forms = locs.setdefault(language, {}).setdefault("variations", {}).setdefault("plural", {})
                target = forms.setdefault(part, {})
            else:
                target = locs.setdefault(language, {})
            new = {"state": state, "value": text}
            if target.get("stringUnit") != new:
                target["stringUnit"] = new
                written.append(f"{ident} [{language}] {state}")
            if part:
                locs[language]["variations"]["plural"] = dict(sorted(forms.items()))
            entry["localizations"] = dict(sorted(locs.items()))
    for (name, key, language), byIndex in phrases.items():
        values = [text for _, (text, _) in sorted(byIndex.items()) if text]
        if not values:
            continue
        missing = [v for v in values if "${applicationName}" not in v]
        if missing:
            refused.append(f"{name}/{key} [{language}]: phrases without the app's name: {missing}")
            continue
        state = "translated" if all(c for t, c in byIndex.values() if t) else "needs_review"
        entry = catalogs[name]["strings"][key]
        locs = entry.setdefault("localizations", {})
        new = {"stringSet": {"state": state, "values": values}}
        if locs.get(language) != new:
            locs[language] = new
            entry["localizations"] = dict(sorted(locs.items()))
            written.append(f"{name}/{key} [{language}] {len(values)} phrases {state}")
    for name, catalog in catalogs.items():
        text = dump(catalog)
        with open(path(name), encoding="utf-8") as f:
            before = f.read()
        if text != before:
            with open(path(name), "w", encoding="utf-8") as f:
                f.write(text)
    return written, refused


def with_shared_strings(source, target):
    """The same workbook with its strings in a shared table, the form Excel saves."""
    with zipfile.ZipFile(source) as book:
        parts = {name: book.read(name) for name in book.namelist()}
    shared = []
    for name in [n for n in parts if n.startswith("xl/worksheets/")]:
        text = parts[name].decode("utf-8")
        parts[name] = re.sub(r'<c r="([A-Z]+\d+)" t="inlineStr"( s="1")?><is><t xml:space="preserve">(.*?)</t></is></c>',
                             lambda m: to_shared_cell(m, shared), text, flags=re.S).encode("utf-8")
    parts["xl/sharedStrings.xml"] = (
        f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<sst xmlns="{MAIN}" count="{len(shared)}">'
        + "".join(f'<si><t xml:space="preserve">{s}</t></si>' for s in shared) + "</sst>").encode("utf-8")
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as book:
        for name, data in parts.items():
            book.writestr(name, data)
    return target


def to_shared_cell(match, shared):
    """One inline cell as a reference into the shared table (its text stays escaped)."""
    shared.append(match.group(3))
    style = match.group(2) or ""
    return f'<c r="{match.group(1)}" t="s"{style}><v>{len(shared) - 1}</v></c>'


def self_check():
    """Export, then import the same workbook, inline and in the shared form: no catalog may change."""
    before = {name: open(path(name), "rb").read() for name in CATALOGS}
    results = []
    with tempfile.TemporaryDirectory() as folder:
        inline = export(os.path.join(folder, "probe.xlsx"))
        shared = with_shared_strings(inline, os.path.join(folder, "probe-shared.xlsx"))
        for form, book in [("inline", inline), ("shared", shared)]:
            written, refused = import_workbook(book)
            after = {name: open(path(name), "rb").read() for name in CATALOGS}
            same = all(before[n] == after[n] for n in CATALOGS)
            results.append(same and not written and not refused)
            print(f"{form}: rows {len(rows())}, written {len(written)}, refused {len(refused)}, "
                  f"catalogs unchanged: {same}")
            for line in refused[:5]:
                print("  REFUSED", line)
    return 0 if all(results) else 1


def main(argv):
    if argv[1:2] == ["export"] and len(argv) == 3:
        print(export(argv[2]))
        return 0
    if argv[1:2] == ["import"] and len(argv) == 3:
        written, refused = import_workbook(argv[2])
        for line in written:
            print("written", line)
        for line in refused:
            print("REFUSED", line)
        print(f"written {len(written)}, refused {len(refused)}")
        return 1 if refused else 0
    if argv[1:2] == ["--self-check"]:
        return self_check()
    print("usage: l10n.py export <workbook.xlsx> | import <workbook.xlsx> | --self-check")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
