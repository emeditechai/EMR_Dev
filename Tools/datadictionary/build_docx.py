"""
Builds the Word data dictionary from the schema snapshot (Docs/DataDictionary/schema_snapshot.json), the module
configuration (dd_config.py) and the revision history. Normally run through update_data_dictionary.py.

    python3 build_docx.py --snapshot <json> --history <json> --out <docx>
"""
import argparse, datetime, json, re, os, sys, collections
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
from docx.enum.section import WD_SECTION, WD_ORIENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
import tempfile
TMP = tempfile.mkdtemp(prefix="emr_dd_")   # diagram images (not kept)
sys.path.insert(0, HERE)
from dd_config import *  # noqa

ap = argparse.ArgumentParser()
ap.add_argument("--snapshot", required=True)
ap.add_argument("--history", required=True)
ap.add_argument("--out", required=True)
args = ap.parse_args()
OUT = args.out
snap = json.load(open(args.snapshot))
history = json.load(open(args.history)) if os.path.exists(args.history) else []
DATE = datetime.datetime.strptime(snap["extracted_on"][:10], "%Y-%m-%d").strftime("%-d %B %Y")
PRODUCT = "eCare360Plus+"

meta = snap
values = {"vals": snap.get("lookups", {})}

cols = collections.defaultdict(list)
for r in meta["cols"]:
    cols[r["tbl"]].append(r)
pk = collections.defaultdict(list)
for r in sorted(meta["pk"], key=lambda r: r["k"]):
    pk[r["tbl"]].append(r["col"])
uq = collections.defaultdict(list)
for r in meta["uq"]:
    uq[r["tbl"]].append(r["cols"])
declared = {(f["tbl"], f["col"]): (f["rtbl"], f["rcol"]) for f in meta["fk"]}
all_tables = set(meta.get("tables") or []) | set(cols)

tdesc = {r["tbl"]: r["d"] for r in meta.get("tdesc", []) if r.get("d")}

# configured modules (tables dropped from the database are left out) + new tables grouped by name
configured = {t for m in MODULES for t in m["tables"]}
for m in MODULES:
    m["tables"] = [t for t in m["tables"] if t in all_tables]
for part, pname, _ in PARTS:
    new = sorted(t for t in all_tables - configured
                 if any(re.match(rx, t) for rx in PART_RULES.get(part, [])) and not any(re.match(rx, t) for rx in EXCLUDE))
    if new:
        MODULES.append(dict(code=f"{part}99", part=part, name=f"Other {pname.split(' (')[0]} tables (not yet grouped)", auto=True,
                            intro="Tables added to the database after the module grouping was last updated. Move them into "
                                  "their module in Tools/datadictionary/dd_config.py and describe them there or with "
                                  "MS_Description in the SQL script.", tables=new))
MODULES[:] = [m for m in MODULES if m["tables"]]
in_scope = [t for m in MODULES for t in m["tables"]]
module_of = {t: m for m in MODULES for t in m["tables"]}


def table_desc(t):
    return tdesc.get(t) or TABLE_DESC.get(t) or "Description pending: add it to dd_config.py (TABLE_DESC) or as MS_Description on the table."

INT_TYPES = {"int", "bigint", "smallint", "tinyint"}
norm = lambda s: re.sub(r"[^a-z0-9]", "", s.lower())


def type_text(c):
    t, ln = c["type"], c["len"]
    if t in ("nvarchar", "nchar"):
        return f"{t}({'max' if ln == -1 else ln // 2})"
    if t in ("varchar", "char", "varbinary", "binary"):
        return f"{t}({'max' if ln == -1 else ln})"
    if t in ("decimal", "numeric"):
        return f"{t}({c['prec']},{c['scale']})"
    if t in ("datetime2", "time", "datetimeoffset") and c["scale"] not in (None, 7):
        return f"{t}({c['scale']})"
    return t


def default_text(d):
    if not d:
        return ""
    d = d.strip()
    while d.startswith("(") and d.endswith(")"):
        d = d[1:-1]
    return {"getdate()": "GETDATE()", "sysdatetime()": "SYSDATETIME()", "newid()": "NEWID()"}.get(d.lower(), d)


# ── references ─────────────────────────────────────────────────────────────────────────────────
def reference(tbl, c):
    """(kind, [targets], target column or None)  kind: Declared / Logical / Conditional / User / None"""
    col = c["col"]
    if (tbl, col) in declared:
        rt, rc = declared[(tbl, col)]
        return ("User" if rt in ("Users", "UserMaster") else "Declared", [rt], rc)
    if (tbl, col) in EXTRA_REF:
        rt, rc = EXTRA_REF[(tbl, col)]
        return ("Logical", [rt], rc)
    if (tbl, col) in CONDITIONAL:
        return ("Conditional", CONDITIONAL[(tbl, col)], None)
    if col in pk[tbl] and len(pk[tbl]) == 1 and (tbl, col) not in OVERRIDE:
        return (None, [], None)
    target = OVERRIDE.get((tbl, col), "__none__")
    if target == "__none__":
        target = None
        for pat, amap in CONTEXT_ALIAS:
            if re.match(pat, tbl) and norm(col) in amap:
                target = amap[norm(col)]; break
        target = target or ALIAS.get(norm(col))
        if target is None and c["type"] in INT_TYPES and re.match(USER_COL, col):
            return ("User", ["Users"], "Id")
    if not target or target == tbl and col in pk[tbl] or target not in all_tables:
        return (None, [], None)
    if c["type"] not in INT_TYPES and not (c["type"] in ("varchar", "nvarchar") and norm(col) in ("loinccode", "modulecode")):
        return (None, [], None)
    return ("Logical", [target], pk[target][0] if pk[target] else None)


refs = {}            # (tbl, col) -> (kind, targets, rcol)
for t in in_scope:
    for c in cols[t]:
        k = reference(t, c)
        if k[0]:
            refs[(t, c["col"])] = k

incoming = collections.defaultdict(list)   # parent -> [(child, col, kind)]
for (t, col), (kind, targets, rc) in refs.items():
    if kind == "User":
        continue
    for p in targets:
        incoming[p].append((t, col, kind))

# ── column descriptions ────────────────────────────────────────────────────────────────────────
SPLIT = {"samplecollection": "Sample collection ", "laborder": "Lab order ", "bookingdatetime": "Booking date time",
         "orderdate": "Order date", "lastlogin": "Last login", "passwordchanged": "Password changed",
         "testsubcategory": "Test sub category ", "testcategory": "Test category ", "collectionstatus": "Collection status ",
         "iscancelled": "Is cancelled"}


def human(name):
    s = name
    for k, v in SPLIT.items():
        s = re.sub(k, v, s, flags=re.I)
    s = re.sub(r"_", " ", s)
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", s)
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    words = []
    for w in s.split(" "):
        if w.upper() in ("ID", "OPD", "GST", "UPI", "PAN", "IFSC", "TDS", "MRP", "TAT", "NABL", "SMS", "OTP", "BMI", "QC",
                         "EQAS", "CAPA", "BOM", "UHID", "URL", "JSON", "HTML", "B2B", "B2C", "CGST", "SGST", "IGST", "ICD",
                         "OVD", "PM", "IP", "SD", "LOINC", "WHONET", "UIP", "AMC", "HO", "SPO2", "BP", "FY", "IQC", "EMR"):
            words.append(w.upper())
        else:
            words.append(w.lower())
    out = " ".join(words)
    out = re.sub(r"\bno\b", "number", out)
    out = re.sub(r"\s+", " ", out).strip()
    return out[:1].upper() + out[1:]


STD = {
    "companyid": "Company (tenant) the record belongs to.",
    "createdby": "User who created the record.", "created_by": "User who created the record.",
    "createddate": "Date and time the record was created.", "createdon": "Date and time the record was created.",
    "createdat": "Date and time the record was created.",
    "modifiedby": "User who last changed the record.", "updatedby": "User who last changed the record.",
    "lastmodifiedby": "User who last changed the record.", "updated_by": "User who last changed the record.",
    "modifieddate": "Date and time of the last change.", "modifiedon": "Date and time of the last change.",
    "updateddate": "Date and time of the last change.", "updatedon": "Date and time of the last change.",
    "lastmodifieddate": "Date and time of the last change.", "updatedat": "Date and time of the last change.",
    "isactive": "Active flag: 1 = active, 0 = inactive.",
    "isdeleted": "Soft-delete flag: 1 = deleted (hidden), 0 = live.",
    "displayorder": "Display order in lists.", "sortorder": "Display order in lists.",
    "remarks": "Free-text remarks.", "notes": "Free-text notes.", "description": "Description.",
    "effectivefrom": "Valid from (date).", "effectiveto": "Valid to (date).",
    "financialyear": "Financial year the running number belongs to.", "finyear": "Financial year the running number belongs to.",
    "lastseq": "Last number issued in this sequence.",
}


def col_desc(tbl, c, ref):
    col, n, typ = c["col"], norm(c["col"]), c["type"]
    if c.get("descr"):
        base = c["descr"]
    elif (tbl, col) in COL_DESC:
        base = COL_DESC[(tbl, col)]
    elif col in pk[tbl] and c["ident"]:
        base = "Unique record ID (auto-generated)."
    elif n in STD:
        base = STD[n]
    elif n in ("status",) and typ == "bit":
        base = "Status flag: 1 = active, 0 = inactive."
    elif n == "pincode":
        base = "PIN / postal code."
    elif ref and ref[0] in ("Declared", "Logical") and not col in pk[tbl]:
        ent = re.sub(r"\s*ID$", "", human(col)).strip()
        base = f"Reference to the {ent if ent.split()[0].isupper() else ent[0].lower() + ent[1:]}." if ent else "Reference."
    elif n in ("branchid",) or n.endswith("branchid"):
        base = human(col).replace(" ID", "") + "."
    elif typ == "bit" and re.match(r"^(is|has|can|requires|allow|show)", n):
        q = re.sub(r"^(Is|Has|Can|Requires|Allow|Show)_?", "", col)
        verb = re.match(r"^(Is|Has|Can|Requires|Allow|Show)", col, re.I).group(1).lower()
        lead = {"is": "", "has": "Has ", "can": "Can ", "requires": "Requires ", "allow": "Allow ", "show": "Show "}.get(verb, "")
        base = f"Yes/No: {lead}{human(q).lower() if lead else human(q)}."
    elif typ == "bit":
        base = f"Yes/No: {human(col)}."
    elif n.endswith("code") and typ in ("varchar", "nvarchar", "char", "nchar"):
        base = f"Short code ({human(col).lower()})."
    elif re.search(r"(amount|charges|charge|price|rate|mrp|fee|cost|total|balance|deposit|limit|payable|share)$", n) and typ in ("decimal", "numeric", "money"):
        base = f"{human(col)}." if "amount" in n else f"{human(col)} (amount)."
    elif re.search(r"(pct|percent|percentage)$", n):
        base = f"{human(col)} (%)."
    elif re.search(r"path$", n):
        base = f"Stored file path: {human(col)[:-5].lower() or 'file'}."
    elif re.search(r"json$", n):
        base = f"JSON data: {human(col)[:-5].lower()}."
    elif typ in ("date", "datetime", "datetime2", "smalldatetime") and re.search(r"(date|on|at|time)$", n):
        base = f"{human(col)}."
    else:
        base = f"{human(col)}."
    kind = ref[0] if ref else None
    if kind == "User" and "user" not in base.lower():
        base += " (user)"
    return base


def key_text(tbl, c, ref):
    k = []
    if c["col"] in pk[tbl]:
        k.append("PK")
    if any(re.split(r",\s*", u) == [c["col"]] for u in uq.get(tbl, [])):
        k.append("UQ")
    if ref:
        k.append({"Declared": "FK", "Logical": "LFK", "Conditional": "CFK", "User": "FK" if (tbl, c["col"]) in declared else "LFK"}[ref[0]])
    return ", ".join(k)


# ── Word helpers ───────────────────────────────────────────────────────────────────────────────
NAVY = RGBColor(0x1B, 0x2A, 0x4A)
TEAL = RGBColor(0x0F, 0x6E, 0x6E)
GREY = RGBColor(0x55, 0x5F, 0x6D)
LINK = "1F5FAF"
HDR_FILL = "1B2A4A"
ALT_FILL = "F3F6FA"
_bm = [100]


def anchor(t):
    return "t_" + re.sub(r"[^A-Za-z0-9_]", "_", t)[:36]


def add_bookmark(par, name):
    _bm[0] += 1
    s = OxmlElement("w:bookmarkStart"); s.set(qn("w:id"), str(_bm[0])); s.set(qn("w:name"), name)
    e = OxmlElement("w:bookmarkEnd"); e.set(qn("w:id"), str(_bm[0]))
    ppr = par._p.find(qn("w:pPr"))
    par._p.insert(1 if ppr is not None else 0, s); par._p.append(e)


def add_link(par, text, target, size=None, bold=False):
    h = OxmlElement("w:hyperlink"); h.set(qn("w:anchor"), target); h.set(qn("w:history"), "1")
    r = OxmlElement("w:r"); rpr = OxmlElement("w:rPr")
    col = OxmlElement("w:color"); col.set(qn("w:val"), LINK); rpr.append(col)
    if bold:
        rpr.append(OxmlElement("w:b"))
    if size:
        sz = OxmlElement("w:sz"); sz.set(qn("w:val"), str(int(size * 2))); rpr.append(sz)
    r.append(rpr)
    t = OxmlElement("w:t"); t.text = text; t.set(qn("xml:space"), "preserve"); r.append(t)
    h.append(r); par._p.append(h)


def run(par, text, size=None, bold=False, italic=False, color=None, font=None):
    r = par.add_run(text)
    if size: r.font.size = Pt(size)
    r.bold = bold; r.italic = italic
    if color: r.font.color.rgb = color
    if font:
        r.font.name = font
        r.element.rPr.rFonts.set(qn("w:eastAsia"), font)
    return r


def shade(cell, fill):
    tcPr = cell._tc.get_or_add_tcPr()
    s = OxmlElement("w:shd"); s.set(qn("w:val"), "clear"); s.set(qn("w:color"), "auto"); s.set(qn("w:fill"), fill)
    tcPr.append(s)


def cell_margins(table, top=40, bottom=40, left=70, right=70):
    tblPr = table._tbl.tblPr
    m = OxmlElement("w:tblCellMar")
    for side, v in (("top", top), ("left", left), ("bottom", bottom), ("right", right)):
        e = OxmlElement(f"w:{side}"); e.set(qn("w:w"), str(v)); e.set(qn("w:type"), "dxa"); m.append(e)
    tblPr.append(m)


def borders(table, color="C9D2DE"):
    tblPr = table._tbl.tblPr
    b = OxmlElement("w:tblBorders")
    for side in ("top", "left", "bottom", "right", "insideH", "insideV"):
        e = OxmlElement(f"w:{side}"); e.set(qn("w:val"), "single"); e.set(qn("w:sz"), "4"); e.set(qn("w:color"), color)
        b.append(e)
    tblPr.append(b)


def repeat_header(row):
    trPr = row._tr.get_or_add_trPr()
    h = OxmlElement("w:tblHeader"); h.set(qn("w:val"), "true"); trPr.append(h)


def no_split(row):
    trPr = row._tr.get_or_add_trPr()
    trPr.append(OxmlElement("w:cantSplit"))


def make_table(doc, headers, widths_cm, rows, size=7.5, link_cols=(), first_bold=False):
    tbl = doc.add_table(rows=1, cols=len(headers))
    tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    tbl.autofit = False
    borders(tbl); cell_margins(tbl)
    order = ["tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblStyleRowBandSize", "tblStyleColBandSize", "tblW", "jc",
             "tblCellSpacing", "tblInd", "tblBorders", "shd", "tblLayout", "tblCellMar", "tblLook", "tblCaption", "tblDescription"]
    tp = tbl._tbl.tblPr
    kids = sorted(list(tp), key=lambda e: order.index(e.tag.split("}")[1]) if e.tag.split("}")[1] in order else 99)
    for k in kids: tp.remove(k)
    for k in kids: tp.append(k)
    hdr = tbl.rows[0]
    repeat_header(hdr)
    for i, h in enumerate(headers):
        c = hdr.cells[i]; c.width = Cm(widths_cm[i]); shade(c, HDR_FILL)
        p = c.paragraphs[0]; p.paragraph_format.space_after = Pt(0)
        run(p, h, size=size, bold=True, color=RGBColor(0xFF, 0xFF, 0xFF))
    for ri, row in enumerate(rows):
        r = tbl.add_row(); no_split(r)
        for i, v in enumerate(row):
            c = r.cells[i]; c.width = Cm(widths_cm[i])
            if ri % 2 == 1: shade(c, ALT_FILL)
            c.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.TOP
            p = c.paragraphs[0]; p.paragraph_format.space_after = Pt(0); p.paragraph_format.line_spacing = 1.0
            if callable(v):
                v(p)
            else:
                run(p, "" if v is None else str(v), size=size, bold=(first_bold and i == 0))
    return tbl


def links_inline(p, items, size):
    """items: list of (text, anchor or None, suffix)"""
    for i, (text, anc, suffix) in enumerate(items):
        if i: run(p, ", ", size=size)
        if anc: add_link(p, text, anc, size=size)
        else: run(p, text, size=size)
        if suffix: run(p, suffix, size=size, color=GREY)


def field(par, instr, placeholder=""):
    r1 = OxmlElement("w:r"); f1 = OxmlElement("w:fldChar"); f1.set(qn("w:fldCharType"), "begin"); r1.append(f1)
    r2 = OxmlElement("w:r"); it = OxmlElement("w:instrText"); it.set(qn("xml:space"), "preserve"); it.text = instr; r2.append(it)
    r3 = OxmlElement("w:r"); f3 = OxmlElement("w:fldChar"); f3.set(qn("w:fldCharType"), "separate"); r3.append(f3)
    r4 = OxmlElement("w:r"); t = OxmlElement("w:t"); t.text = placeholder; r4.append(t)
    r5 = OxmlElement("w:r"); f5 = OxmlElement("w:fldChar"); f5.set(qn("w:fldCharType"), "end"); r5.append(f5)
    for r in (r1, r2, r3, r4, r5): par._p.append(r)


# ── diagrams ───────────────────────────────────────────────────────────────────────────────────
def _font(*names):
    for n in names:
        if os.path.exists(n):
            return n
    return None


FONT_B = _font("/System/Library/Fonts/Supplemental/Arial Bold.ttf", "C:/Windows/Fonts/arialbd.ttf",
               "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")
FONT_R = _font("/System/Library/Fonts/Supplemental/Arial.ttf", "C:/Windows/Fonts/arial.ttf",
               "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
SKIP_IN_DIAGRAM = {"CompanyMaster", "Branchmaster", "Users"}


def diagram(mod, path):
    nodes = list(mod["tables"])
    edges = set()
    for t in mod["tables"]:
        for c in cols[t]:
            ref = refs.get((t, c["col"]))
            if not ref or ref[0] == "User":
                continue
            for p in ref[1]:
                if p == t or p in SKIP_IN_DIAGRAM:
                    continue
                if p not in nodes:
                    nodes.append(p)
                edges.add((t, p, ref[0]))
    external = [n for n in nodes if n not in mod["tables"]]
    parents = collections.defaultdict(set)
    for ch, p, _ in edges:
        parents[ch].add(p)
    layer = {n: 0 for n in nodes}
    for _ in range(len(nodes) + 2):
        changed = False
        for n in nodes:
            v = max([layer[p] + 1 for p in parents[n]] or [0])
            if v != layer[n] and v < len(nodes):
                layer[n] = v; changed = True
        if not changed:
            break
    linked = {x for e in edges for x in e[:2]}
    isolated = [n for n in nodes if n not in linked]
    if isolated:
        bottom = max([layer[n] for n in linked] or [0]) + 1
        for n in isolated: layer[n] = bottom
    S = 2
    tf = lambda f, sz: ImageFont.truetype(f, sz) if f else ImageFont.load_default(sz)
    fb, fr = tf(FONT_B, 19 * S), tf(FONT_R, 13 * S)
    padx, gapx, gapy, bh = 30 * S, 24 * S, 100 * S, 56 * S

    def bw(n):
        return max(int(fb.getlength(n)) + 28 * S, 120 * S)

    widest = max(sum(bw(n) + gapx for n in nodes if layer[n] == L) for L in set(layer.values())) + 2 * padx
    W = max(1700 * S, min(widest, 2600 * S))
    rows, order = [], {}
    for L in sorted(set(layer.values())):
        ln = [n for n in nodes if layer[n] == L]
        ln.sort(key=lambda n: (sum(order.get(p, 0) for p in parents[n]) / max(len(parents[n]), 1), n not in mod["tables"]))
        cur, cw = [], padx
        for n in ln:
            if cur and cw + bw(n) > W - padx:
                rows.append(cur); cur, cw = [], padx
            cur.append(n); cw += bw(n) + gapx
        if cur: rows.append(cur)
        for i, n in enumerate(ln): order[n] = i
    H = padx * 2 + len(rows) * bh + (len(rows) - 1) * gapy + 40 * S
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    pos = {}
    y = padx
    for row in rows:
        total = sum(bw(n) for n in row) + gapx * (len(row) - 1)
        x = (W - total) // 2
        for n in row:
            pos[n] = (x, y, x + bw(n), y + bh); x += bw(n) + gapx
        y += bh + gapy
    # anchor points spread along the box edges, ordered by the other end's x
    outs, ins = collections.defaultdict(list), collections.defaultdict(list)
    for e in sorted(edges):
        outs[e[0]].append(e); ins[e[1]].append(e)
    cx = lambda n: (pos[n][0] + pos[n][2]) / 2

    def spread(n, lst, other):
        lst = sorted(lst, key=lambda e: cx(e[other]))
        x1, _, x2, _ = pos[n]; w = x2 - x1
        return {e: x1 + w * (i + 1) / (len(lst) + 1) for i, e in enumerate(lst)}
    sx_of, ex_of = {}, {}
    for n, l in outs.items(): sx_of.update(spread(n, l, 1))
    for n, l in ins.items(): ex_of.update(spread(n, l, 0))
    import math
    detour = collections.Counter()
    for e in sorted(edges):
        ch, p, kind = e
        x1, y1, x2, y2 = pos[ch]; px1, py1, px2, py2 = pos[p]
        color = {"Declared": (31, 95, 175), "Logical": (15, 110, 110), "Conditional": (190, 120, 20)}[kind]
        if py2 <= y1:
            sx, sy, ex, ey = sx_of[e], y1, ex_of[e], py2
        else:                      # parent not above: connect the facing sides
            sx, sy = (x2, (y1 + y2) / 2) if px1 > x2 else (x1, (y1 + y2) / 2)
            ex, ey = (px1, (py1 + py2) / 2) if px1 > x2 else (px2, (py1 + py2) / 2)
        pts = [(sx, sy)]
        if py2 <= y1:
            # step up row by row; where the straight line would cross a box, pass beside it
            for (bx1, by1, bx2, by2) in sorted({pos[n] for n in pos if n not in (ch, p)}, key=lambda b: -b[1]):
                if not (ey < by1 and by2 < sy):
                    continue
                lx, ly = pts[-1]
                ymid = (by1 + by2) / 2
                xm = lx + (ex - lx) * (ly - ymid) / (ly - ey) if ly != ey else lx
                if bx1 - 6 * S <= xm <= bx2 + 6 * S:
                    left = (xm - bx1) < (bx2 - xm)
                    k = detour[(bx1, by1, left)]; detour[(bx1, by1, left)] += 1
                    side = bx1 - (12 + 9 * k) * S if left else bx2 + (12 + 9 * k) * S
                    pts += [(side, by2 + 10 * S), (side, by1 - 10 * S)]
        pts.append((ex, ey))
        d.line(pts, fill=color, width=2 * S, joint="curve")
        d.ellipse((sx - 4 * S, sy - 4 * S, sx + 4 * S, sy + 4 * S), fill=color)
        px_, py_ = pts[-2]
        ang = math.atan2(ey - py_, ex - px_); L = 12 * S
        tip = (ex, ey)
        a1 = (ex - L * math.cos(ang - 0.4), ey - L * math.sin(ang - 0.4))
        a2 = (ex - L * math.cos(ang + 0.4), ey - L * math.sin(ang + 0.4))
        d.polygon([tip, a1, a2], fill=color)
    for n, (x1, y1, x2, y2) in pos.items():
        ext = n not in mod["tables"]
        d.rounded_rectangle((x1, y1, x2, y2), radius=8 * S, fill=(236, 239, 243) if ext else (232, 241, 252),
                            outline=(150, 160, 175) if ext else (27, 42, 74), width=2 * S)
        tw = fb.getlength(n)
        d.text(((x1 + x2 - tw) / 2, y1 + 9 * S), n, font=fb, fill=(85, 95, 109) if ext else (27, 42, 74))
        sub = ("other module" if ext else (pk[n][0] if pk[n] else ""))
        sw = fr.getlength(sub)
        d.text(((x1 + x2 - sw) / 2, y1 + 33 * S), sub, font=fr, fill=(110, 118, 130))
    # legend
    lx, ly = padx, H - 30 * S
    for label, color in (("Declared FK", (31, 95, 175)), ("Logical reference", (15, 110, 110)), ("Conditional reference", (190, 120, 20))):
        d.line([(lx, ly + 8 * S), (lx + 30 * S, ly + 8 * S)], fill=color, width=3 * S)
        d.text((lx + 36 * S, ly), label, font=fr, fill=(60, 60, 60)); lx += int(fr.getlength(label)) + 80 * S
    d.text((lx, ly), "Arrow points to the parent (one); the dot marks the child (many). Grey boxes belong to another module.", font=fr, fill=(110, 118, 130))
    img.save(path)
    return len(edges)


# ── document ───────────────────────────────────────────────────────────────────────────────────
doc = Document()
st = doc.styles["Normal"]; st.font.name = "Calibri"; st.font.size = Pt(9.5)
st.element.rPr.rFonts.set(qn("w:eastAsia"), "Calibri")
for name, size, color in (("Heading 1", 18, NAVY), ("Heading 2", 14, NAVY), ("Heading 3", 11.5, TEAL)):
    h = doc.styles[name]; h.font.name = "Calibri"; h.font.size = Pt(size); h.font.color.rgb = color; h.font.bold = True
    h.element.rPr.rFonts.set(qn("w:asciiTheme"), "minorHAnsi") if False else None
    rf = h.element.rPr.rFonts; rf.set(qn("w:ascii"), "Calibri"); rf.set(qn("w:hAnsi"), "Calibri")
    for a in ("w:asciiTheme", "w:hAnsiTheme"):
        if rf.get(qn(a)) is not None: del rf.attrib[qn(a)]
    h.paragraph_format.space_before = Pt(14 if name != "Heading 3" else 10); h.paragraph_format.space_after = Pt(4)
    h.paragraph_format.keep_with_next = True

sec = doc.sections[0]
sec.page_width, sec.page_height = Cm(21), Cm(29.7)
for side in ("left_margin", "right_margin"): setattr(sec, side, Cm(1.5))
sec.top_margin, sec.bottom_margin = Cm(1.6), Cm(1.5)
USABLE = 18.0

# title page
for _ in range(6): doc.add_paragraph()
p = doc.add_paragraph(); run(p, PRODUCT, size=16, bold=True, color=TEAL)
p = doc.add_paragraph(); run(p, "Data Dictionary", size=34, bold=True, color=NAVY)
p = doc.add_paragraph(); run(p, "OPD · LAB · Pharmacy · Accounts · Inventory — module-wise tables, columns and relations", size=13, color=GREY)
p = doc.add_paragraph(); p.paragraph_format.space_before = Pt(30)
pPr = p._p.get_or_add_pPr(); bd = OxmlElement("w:pBdr"); b = OxmlElement("w:top")
b.set(qn("w:val"), "single"); b.set(qn("w:sz"), "12"); b.set(qn("w:color"), "0F6E6E"); bd.append(b); pPr.insert(0, bd)
n_tables = len(in_scope)
n_cols = sum(len(cols[t]) for t in in_scope)
n_rel = sum(1 for k, v in refs.items() if v[0] != "User")
facts = [("Database", "SQL Server — Dev_EMR (schema dbo)"), ("Scope", "Common foundation, OPD, LAB, Pharmacy, Accounts and Inventory"),
         ("Modules", str(len(MODULES))), ("Tables", str(n_tables)), ("Columns", f"{n_cols:,}"),
         ("Relations documented", f"{n_rel:,} (declared, logical and conditional)"), ("Generated", DATE + " from the live schema"),
         ("Prepared by", "EMEDITECHPLUS LLP")]
for k, v in facts:
    p = doc.add_paragraph(); p.paragraph_format.space_after = Pt(2)
    run(p, f"{k}:  ", size=10.5, bold=True, color=NAVY); run(p, v, size=10.5)
# revision history
latest = history[-1]["version"] if history else "1.0"
p = doc.add_paragraph(); p.paragraph_format.space_after = Pt(2)
run(p, "Version:  ", size=10.5, bold=True, color=NAVY); run(p, latest, size=10.5)
p = doc.add_paragraph(); p.add_run().add_break(WD_BREAK.PAGE)
doc.add_heading("Revision history", level=1)
doc.add_paragraph("Updated automatically by Tools/datadictionary/update_data_dictionary.py whenever the database "
                  "schema or the module configuration changes.")
make_table(doc, ["Version", "Date", "Changes"], [1.6, 2.6, USABLE - 4.2],
           [(h["version"], h["date"], "; ".join(h["changes"])[:1500]) for h in reversed(history[-40:])], size=8, first_bold=True)
p = doc.add_paragraph(); p.add_run().add_break(WD_BREAK.PAGE)

# header / footer
hp = sec.header.paragraphs[0]; run(hp, f"{PRODUCT}  ·  Data Dictionary — OPD, LAB, Pharmacy, Accounts, Inventory", size=8, color=GREY)
fp = sec.footer.paragraphs[0]; fp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
run(fp, "Page ", size=8, color=GREY); field(fp, "PAGE", "1")

# contents
doc.add_heading("Contents", level=1)
toc = [("1. About this document", "s_1", 0), ("2. Module overview", "s_2", 0)]
for i, (part, pname, _) in enumerate(PARTS):
    toc.append((f"{3 + i}. Part {part} — {pname}", "p_" + part, 0))
    for m in [m for m in MODULES if m["part"] == part]:
        toc.append((f"{m['code']}  {m['name']}  ({len(m['tables'])} tables)", "m_" + m["code"], 1))
toc += [("Appendix A. Status and lookup values", "s_A", 0), ("Appendix B. Index of tables", "s_B", 0)]
for text, anc, lvl in toc:
    p = doc.add_paragraph(); p.paragraph_format.space_after = Pt(1 if lvl else 3)
    p.paragraph_format.left_indent = Cm(0.8 * lvl)
    add_link(p, text, anc, size=9.5 if lvl else 11, bold=not lvl)
p = doc.add_paragraph(); p.add_run().add_break(WD_BREAK.PAGE)

# 1 introduction
add_bookmark(doc.add_heading("1. About this document", level=1), "s_1")
for t in [
    f"This data dictionary describes every database table used by the OPD, LAB, Pharmacy, Accounts and Inventory "
    f"modules of {PRODUCT}, grouped by "
    "business module. For each table it gives the purpose, the primary and unique keys, every column with its data "
    "type, nullability, default and meaning, and the relations to other tables in both directions.",
    "It was generated from the live database schema (Dev_EMR) on " + DATE + ", so names, data types and defaults "
    "match the database exactly. Descriptions are written from the application's behaviour.",
    "Part A covers the foundation both modules share (organisation, users, patients, billing, cancellation, cash "
    "closing, membership, approvals). Part B covers OPD, Part C LAB, Part D Pharmacy, Part E Accounts and Part F "
    "Inventory. Appendix A lists the code values of "
    "the status and lookup tables; Appendix B is an alphabetical index of tables.",
]:
    doc.add_paragraph(t)

doc.add_heading("1.1 How to read a table entry", level=2)
make_table(doc, ["Key", "Meaning"], [3.0, USABLE - 3.0], [
    ("PK", "Primary key."), ("UQ", "Unique key (on its own; multi-column unique keys are listed under the table)."),
    ("FK", "Declared foreign key: the database enforces the relation."),
    ("LFK", "Logical foreign key: the relation is maintained by the application and stored procedures, not by a "
            "database constraint. Joins in the procedures use it exactly like an FK."),
    ("CFK", "Conditional reference: the column points at different tables depending on a type column (for example "
            "LabOrder.B2BAgentID is a franchise when AgentType = 'F' and a corporate when 'C')."),
    ("Null", "Yes = the column may be empty."),
], size=8.5, first_bold=True)
doc.add_paragraph()
doc.add_heading("1.2 Conventions used across all tables", level=2)
make_table(doc, ["Column", "Meaning"], [4.0, USABLE - 4.0], [
    ("CompanyId", "The company (tenant). Every master and transaction belongs to one company; all queries filter by it. Links to CompanyMaster.CompanyId (not repeated in the relation lists)."),
    ("BranchId / Branch_ID", "The branch the record belongs to (Branchmaster.BranchID). Masters without a branch are shared by all branches of the company."),
    ("CreatedBy, CreatedDate", "Who created the record (Users.Id) and when."),
    ("ModifiedBy, ModifiedDate", "Who last changed the record (Users.Id) and when."),
    ("IsActive / Status (bit)", "1 = active and offered in lists and billing; 0 = inactive."),
    ("IsDeleted", "Soft delete: deleted records stay in the table with IsDeleted = 1 and are hidden everywhere."),
    ("Running numbers", "Bill, receipt, token, barcode, patient code and certificate numbers come from *Sequence / *Counter tables keyed by branch and financial year (or day for tokens)."),
    ("Approvals", "Franchise, corporate and profile / package records under the Master Approval Workflow (A9) are saved inactive until approved; changes wait in ApprovalRequest."),
], size=8.5, first_bold=True)
doc.add_paragraph()
p = doc.add_paragraph(); run(p, "User references ", bold=True)
run(p, "(CreatedBy, ApprovedBy, PhlebotomistId and similar) point at Users.Id. They are marked FK / LFK in the column "
       "lists but left out of the relation diagrams to keep them readable.")

# 2 overview
add_bookmark(doc.add_heading("2. Module overview", level=1), "s_2")
rows = []
for part, pname, _ in PARTS:
    for m in [m for m in MODULES if m["part"] == part]:
        rows.append((lambda p, m=m: add_link(p, f"{m['code']}  {m['name']}", "m_" + m["code"], size=8.5, bold=True),
                     pname.split(" (")[0], str(len(m["tables"])), m["intro"].split(". ")[0] + "."))
make_table(doc, ["Module", "Part", "Tables", "Purpose"], [4.6, 2.6, 1.3, USABLE - 8.5], rows, size=8)

doc.add_heading("2.1 How the modules connect", level=2)
for t in [
    "PatientMaster is shared: an OPD visit (PatientOPDService) and a lab order (LabOrder) both point at the patient.",
    "Billing is shared: an OPD visit and a lab order each have one PaymentHeader (ModuleCode OPD / LAB, ModuleRefId = "
    "the visit or order) with PaymentLineItem lines and PaymentDetail payments. Cancellations, refunds, cash closing "
    "and membership discounts work the same way for both.",
    "LAB order flow: LabOrder > LabOrderItem (test or profile) > SampleCollection (one per test sample, barcode) > "
    "labentrydetails (result) > LabReportApproval (pathologist sign-off) > report e-mail / WhatsApp log.",
    "OPD visit flow: PatientOPDService (token, doctor, slot) > PatientOPDServiceItem > EmrPatientConsultation / "
    "PatientVitals > certificates and vaccinations > doctor share in DoctorDisbursal > DoctorSettlement.",
    "Doctors: DoctorMaster serves both: consulting doctors for OPD and referring doctors (LabOrder.RefDoctorId) whose "
    "lab business earns commission under the Doctor Incentive Programme (C10). External referrers are in ReferralDoctorMaster.",
    "Pharmacy: a sale (PhSale) is billed through PaymentHeader with ModuleCode = 'PHR'; stock moves batch-wise "
    "(PhGrn creates PhBatch / PhStock, every movement is a PhStockLedger row).",
    "Accounts: LAB bills, receipts, refunds, discounts, B2B billing and settlement, franchise wallet, membership "
    "cards, cash closing and pharmacy GRN / sales post automatically to the general ledger "
    "(Acc_LedgerTransaction.ReferenceType / ReferenceId); each payment method posts to the ledger set in "
    "Acc_PaymentModeLedger.",
    "Inventory: reagents and consumables in InvItem are consumed through the LAB bill of materials (BomTest, "
    "BomSampleKit) when samples are processed (QcConsumption).",
]:
    p = doc.add_paragraph(t, style="List Bullet")

# parts and modules
section_no = 3
for part, pname, pintro in PARTS:
    doc.add_page_break()
    add_bookmark(doc.add_heading(f"{section_no}. Part {part} — {pname}", level=1), "p_" + part)
    doc.add_paragraph(pintro)
    for m in [m for m in MODULES if m["part"] == part]:
        h = doc.add_heading(f"{m['code']}  {m['name']}", level=2); add_bookmark(h, "m_" + m["code"])
        doc.add_paragraph(m["intro"])
        img = os.path.join(TMP, f"er_{m['code']}.png")
        ne = diagram(m, img)
        if ne:
            land = doc.add_section(WD_SECTION.NEW_PAGE)
            land.orientation = WD_ORIENT.LANDSCAPE; land.page_width, land.page_height = Cm(29.7), Cm(21)
            p = doc.add_paragraph(); run(p, f"{m['code']}  {m['name']} — relation diagram", size=12, bold=True, color=NAVY)
            p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            w, hgt = Image.open(img).size
            width = min(26.5, 16.0 * w / hgt)
            p.add_run().add_picture(img, width=Cm(width))
            cap = doc.add_paragraph(); cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
            run(cap, f"Figure {m['code']}: relations — {m['name']}", size=8, italic=True, color=GREY)
            port = doc.add_section(WD_SECTION.NEW_PAGE)
            port.orientation = WD_ORIENT.PORTRAIT; port.page_width, port.page_height = Cm(21), Cm(29.7)
        # relation list of the module
        rel_rows = []
        for t in m["tables"]:
            for c in cols[t]:
                ref = refs.get((t, c["col"]))
                if not ref or ref[0] == "User" or ref[1] == ["CompanyMaster"]:
                    continue
                for p_t in ref[1]:
                    rc = ref[2] or (pk[p_t][0] if pk[p_t] else "")
                    cond = CONDITION_TEXT.get((t, c["col"]), "")
                    rel_rows.append((
                        (lambda pp, t=t, col=c["col"]: (add_link(pp, t, anchor(t), size=7.5), run(pp, "." + col, size=7.5))),
                        (lambda pp, p_t=p_t, rc=rc: (add_link(pp, p_t, anchor(p_t), size=7.5) if p_t in module_of else run(pp, p_t, size=7.5), run(pp, "." + rc, size=7.5))),
                        "Many-to-one", ref[0] + (f" ({cond})" if cond else "")))
        if rel_rows:
            p = doc.add_paragraph(); run(p, f"Relations of {m['code']} ({len(rel_rows)})", bold=True, color=TEAL)
            p.paragraph_format.keep_with_next = True
            make_table(doc, ["Child table.column", "Parent table.column", "Cardinality", "Type"], [6.2, 6.2, 2.1, USABLE - 14.5], rel_rows, size=7.5)

        for t in m["tables"]:
            h = doc.add_heading(t, level=3); add_bookmark(h, anchor(t))
            p = doc.add_paragraph(table_desc(t)); p.paragraph_format.space_after = Pt(3)
            p = doc.add_paragraph(); p.paragraph_format.space_after = Pt(3)
            run(p, "Primary key: ", size=8.5, bold=True); run(p, ", ".join(pk[t]) or "—", size=8.5)
            multi = [u for u in uq.get(t, []) if "," in u]
            if multi:
                run(p, "    Unique: ", size=8.5, bold=True); run(p, "; ".join(f"({u})" for u in multi), size=8.5)
            rows = []
            for i, c in enumerate(cols[t], 1):
                ref = refs.get((t, c["col"]))
                desc = col_desc(t, c, ref)
                def cell(pp, desc=desc, ref=ref, t=t, col=c["col"]):
                    run(pp, desc, size=7.5)
                    if ref and ref[0] != "User" and ref[1] != ["CompanyMaster"]:
                        run(pp, "  → ", size=7.5, color=GREY)
                        for j, p_t in enumerate(ref[1]):
                            if j: run(pp, " / ", size=7.5, color=GREY)
                            if p_t in module_of: add_link(pp, p_t, anchor(p_t), size=7.5)
                            else: run(pp, p_t, size=7.5)
                rows.append((str(i), c["col"], type_text(c), "Yes" if c["nullable"] else "No", key_text(t, c, ref),
                             default_text(c["def"]) + (" (identity)" if c["ident"] else ""), cell))
            make_table(doc, ["#", "Column", "Data type", "Null", "Key", "Default", "Description"],
                       [0.6, 3.6, 2.3, 0.9, 1.1, 1.9, USABLE - 10.4], rows, size=7.5)
            # references in / out
            out_items, in_items = [], []
            for c in cols[t]:
                ref = refs.get((t, c["col"]))
                if ref and ref[0] != "User" and ref[1] != ["CompanyMaster"]:
                    for p_t in ref[1]:
                        out_items.append((p_t, anchor(p_t) if p_t in module_of else None, f" (via {c['col']})"))
            for ch, col, kind in sorted(incoming.get(t, [])):
                if ch == t and col in pk[t]:
                    continue
                in_items.append((ch, anchor(ch) if ch in module_of else None, f".{col}"))
            if out_items:
                p = doc.add_paragraph(); p.paragraph_format.space_before = Pt(3); p.paragraph_format.space_after = Pt(0)
                run(p, "References: ", size=8, bold=True, color=NAVY); links_inline(p, out_items, 8)
            if in_items:
                p = doc.add_paragraph(); p.paragraph_format.space_after = Pt(2)
                run(p, "Referenced by: ", size=8, bold=True, color=NAVY); links_inline(p, in_items, 8)
    section_no += 1

# Appendix A — code values
doc.add_page_break()
add_bookmark(doc.add_heading("Appendix A. Status and lookup values", level=1), "s_A")
doc.add_paragraph("Rows of the small lookup tables, as held in the database on " + DATE + ".")
for t, rws in values["vals"].items():
    doc.add_heading(t, level=3)
    keys = list(rws[0].keys()) if rws else []
    make_table(doc, keys, [USABLE / len(keys)] * len(keys), [tuple("" if r[k] is None else {True: "Yes", False: "No"}.get(r[k], r[k]) if isinstance(r[k], bool) else r[k] for k in keys) for r in rws], size=8)
doc.add_heading("Coded columns", level=2)
doc.add_paragraph("Single-letter and text codes stored in transaction tables, with their meaning.")
coded = [(f"{t}.{c}", v) for (t, c), v in COL_DESC.items()
         if re.search(r"\b[A-Z][A-Za-z0-9_]{0,15}( =|,| or )\s?[A-Z(]", v) and not re.search(r"(ID|Id) of |Reference to", v)]
make_table(doc, ["Table.column", "Values"], [6.0, USABLE - 6.0], coded, size=8, first_bold=True)

# Appendix B — index
doc.add_page_break()
add_bookmark(doc.add_heading("Appendix B. Index of tables", level=1), "s_B")
rows = []
for t in sorted(in_scope, key=str.lower):
    m = module_of[t]
    rows.append(((lambda p, t=t: add_link(p, t, anchor(t), size=8)), f"{m['code']}  {m['name']}", str(len(cols[t])),
                 table_desc(t).split(":")[0].split(". ")[0][:110]))
make_table(doc, ["Table", "Module", "Columns", "Purpose"], [5.2, 4.6, 1.5, USABLE - 11.3], rows, size=8)

# open with fields updated (table of contents, page numbers)

z = doc.settings.element.find(qn("w:zoom"))
if z is not None: z.set(qn("w:percent"), "100")
doc.core_properties.title = f"{PRODUCT} Data Dictionary — OPD, LAB, Pharmacy, Accounts, Inventory"
doc.core_properties.author = "EMEDITECHPLUS LLP"
doc.core_properties.subject = "Database data dictionary"
os.makedirs(os.path.dirname(OUT), exist_ok=True)
doc.save(OUT)
print("saved", OUT, "tables", n_tables, "columns", n_cols, "relations", n_rel)
