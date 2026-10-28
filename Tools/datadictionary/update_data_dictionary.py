"""
Keeps Docs/DataDictionary up to date with the database.

    python3 Tools/datadictionary/update_data_dictionary.py            # refresh if anything changed
    python3 Tools/datadictionary/update_data_dictionary.py --check    # report only; exit 1 when out of date
    python3 Tools/datadictionary/update_data_dictionary.py --offline  # rebuild from the saved snapshot (no database)
    python3 Tools/datadictionary/update_data_dictionary.py --force    # rebuild even if nothing changed

1. Reads the live schema (tables, columns, keys, foreign keys, MS_Description, lookup values).
2. Compares it with Docs/DataDictionary/schema_snapshot.json (committed) for the tables in scope.
3. When the schema or dd_config.py / build_docx.py changed: saves the new snapshot, adds a revision-history entry
   describing what changed, and rebuilds the Word document.

Connection: environment variable EMR_DD_CONNECTION, else ConnectionStrings:DefaultConnection in
EMR.Web/appsettings.json. The password is never printed.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT_DIR = os.path.join(ROOT, "Docs", "DataDictionary")
SNAPSHOT = os.path.join(OUT_DIR, "schema_snapshot.json")
HISTORY = os.path.join(OUT_DIR, "revision_history.json")
STATE = os.path.join(OUT_DIR, "build_state.json")
DOCX = os.path.join(OUT_DIR, "Data_Dictionary_OPD_LAB_Pharmacy_Accounts_Inventory.docx")

sys.path.insert(0, HERE)
import dd_config as cfg  # noqa: E402


# ── database ───────────────────────────────────────────────────────────────────────────────────
def connection_settings():
    cs = os.environ.get("EMR_DD_CONNECTION")
    if not cs:
        with open(os.path.join(ROOT, "EMR.Web", "appsettings.json"), encoding="utf-8-sig") as f:
            cs = json.load(f)["ConnectionStrings"]["DefaultConnection"]
    parts = {}
    for kv in cs.split(";"):
        if "=" in kv:
            k, v = kv.split("=", 1)
            parts[k.strip().lower()] = v.strip()
    server = parts.get("server") or parts.get("data source") or parts.get("addr") or ""
    server = server.replace("tcp:", "")
    host, _, port = server.partition(",")
    return dict(server=host, port=int(port or 1433),
                database=parts.get("database") or parts.get("initial catalog"),
                user=parts.get("user id") or parts.get("uid") or parts.get("user"),
                password=parts.get("password") or parts.get("pwd"))


def extract():
    import pymssql
    s = connection_settings()
    con = pymssql.connect(server=s["server"], port=s["port"], user=s["user"], password=s["password"],
                          database=s["database"], login_timeout=20)
    c = con.cursor(as_dict=True)

    def q(sql):
        c.execute(sql)
        rows = c.fetchall()
        for r in rows:
            for k, v in list(r.items()):
                if not isinstance(v, (str, int, float, type(None), bool)):
                    r[k] = str(v)
        return rows

    snap = {"database": s["database"], "extracted_on": datetime.datetime.now().isoformat(timespec="seconds")}
    snap["cols"] = q("""
        SELECT t.name tbl, col.column_id ord, col.name col, ty.name type, col.max_length len, col.precision prec,
               col.scale scale, col.is_nullable nullable, col.is_identity ident, dc.definition def,
               CAST(ep.value AS NVARCHAR(4000)) descr
          FROM sys.tables t JOIN sys.columns col ON col.object_id = t.object_id
          JOIN sys.types ty ON ty.user_type_id = col.user_type_id
          LEFT JOIN sys.default_constraints dc ON dc.object_id = col.default_object_id
          LEFT JOIN sys.extended_properties ep ON ep.major_id = t.object_id AND ep.minor_id = col.column_id AND ep.name = 'MS_Description'
         WHERE t.is_ms_shipped = 0
         ORDER BY t.name, col.column_id""")
    snap["pk"] = q("""
        SELECT t.name tbl, c.name col, ic.key_ordinal k FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
          JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
          JOIN sys.columns c ON c.object_id = i.object_id AND c.column_id = ic.column_id
         WHERE i.is_primary_key = 1 ORDER BY t.name, ic.key_ordinal""")
    snap["fk"] = q("""
        SELECT fk.name fk, tp.name tbl, cp.name col, tr.name rtbl, cr.name rcol FROM sys.foreign_keys fk
          JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
          JOIN sys.tables tp ON tp.object_id = fkc.parent_object_id
          JOIN sys.columns cp ON cp.object_id = fkc.parent_object_id AND cp.column_id = fkc.parent_column_id
          JOIN sys.tables tr ON tr.object_id = fkc.referenced_object_id
          JOIN sys.columns cr ON cr.object_id = fkc.referenced_object_id AND cr.column_id = fkc.referenced_column_id
         ORDER BY tp.name, cp.name, fk.name""")
    snap["uq"] = q("""
        SELECT t.name tbl, i.name idx, STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) cols
          FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
          JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
          JOIN sys.columns c ON c.object_id = i.object_id AND c.column_id = ic.column_id
         WHERE i.is_unique = 1 AND i.is_primary_key = 0 GROUP BY t.name, i.name ORDER BY t.name, i.name""")
    snap["tdesc"] = q("""
        SELECT t.name tbl, CAST(ep.value AS NVARCHAR(4000)) d FROM sys.tables t
          JOIN sys.extended_properties ep ON ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = 'MS_Description'
         ORDER BY t.name""")
    snap["lookups"] = {}
    tables = {r["tbl"] for r in snap["cols"]}
    configured = configured_tables()
    snap["tables"] = sorted(tables)                       # every table (to resolve references outside the scope)
    snap["cols"] = [r for r in snap["cols"] if in_scope(r["tbl"], configured)]
    audit = re.compile(r"(?i)^(Created|Modified|Updated|LastModified)(By|Date|On|At)$|^IsActive$|^IsDeleted$|^BadgeClass$|^DisplayOrder$|^SortOrder$|^CompanyId$")
    for t in cfg.LOOKUP_TABLES:
        if t not in tables:
            continue
        keep = [r["col"] for r in snap["cols"] if r["tbl"] == t and not audit.match(r["col"])][:6]
        cols = ", ".join(f"[{k}]" for k in keep)
        snap["lookups"][t] = q(f"SELECT TOP 60 {cols} FROM dbo.[{t}] ORDER BY 1")
    con.close()
    return snap


# ── scope and comparison ───────────────────────────────────────────────────────────────────────
def configured_tables():
    return {t for m in cfg.MODULES for t in m["tables"]}


def in_scope(t, configured):
    if any(re.match(rx, t) for rx in cfg.EXCLUDE):
        return False
    return t in configured or any(re.match(rx, t) for rules in cfg.PART_RULES.values() for rx in rules)


def schema_view(snap, configured):
    """Comparable picture of the in-scope schema."""
    tables = {}
    for r in snap["cols"]:
        if in_scope(r["tbl"], configured):
            tables.setdefault(r["tbl"], {})[r["col"]] = (r["type"], r["len"], r["prec"], r["scale"], r["nullable"], r["def"])
    fks = {(f["tbl"], f["col"], f["rtbl"], f["rcol"]) for f in snap["fk"] if f["tbl"] in tables}
    return tables, fks


def type_str(t):
    typ, ln, prec, scale = t[0], t[1], t[2], t[3]
    if typ in ("nvarchar", "nchar"):
        return f"{typ}({'max' if ln == -1 else ln // 2})"
    if typ in ("varchar", "char", "varbinary"):
        return f"{typ}({'max' if ln == -1 else ln})"
    if typ in ("decimal", "numeric"):
        return f"{typ}({prec},{scale})"
    return typ


def compare(old, new, configured):
    if old is None:
        return []
    ot, of = schema_view(old, configured)
    nt, nf = schema_view(new, configured)
    changes = []
    for t in sorted(nt.keys() - ot.keys()):
        where = "module " + next((m["code"] for m in cfg.MODULES if t in m["tables"]), "not yet grouped")
        changes.append(f"New table {t} ({len(nt[t])} columns, {where})")
    for t in sorted(ot.keys() - nt.keys()):
        changes.append(f"Table removed: {t}")
    for t in sorted(nt.keys() & ot.keys()):
        add = [c for c in nt[t] if c not in ot[t]]
        rem = [c for c in ot[t] if c not in nt[t]]
        if add:
            changes.append(f"{t}: new column(s) {', '.join(add)}")
        if rem:
            changes.append(f"{t}: column(s) removed {', '.join(rem)}")
        for c in nt[t].keys() & ot[t].keys():
            a, b = ot[t][c], nt[t][c]
            if a[:4] != b[:4]:
                changes.append(f"{t}.{c}: type {type_str(a)} -> {type_str(b)}")
            if a[4] != b[4]:
                changes.append(f"{t}.{c}: now {'nullable' if b[4] else 'NOT NULL'}")
            if (a[5] or "") != (b[5] or ""):
                changes.append(f"{t}.{c}: default {a[5] or 'none'} -> {b[5] or 'none'}")
    for f in sorted(nf - of):
        changes.append(f"New foreign key {f[0]}.{f[1]} -> {f[2]}.{f[3]}")
    for f in sorted(of - nf):
        changes.append(f"Foreign key removed {f[0]}.{f[1]} -> {f[2]}.{f[3]}")
    od = {(r["tbl"], r["col"]): r["descr"] for r in old["cols"] if r["descr"]}
    nd = {(r["tbl"], r["col"]): r["descr"] for r in new["cols"] if r["descr"]}
    otd = {r["tbl"]: r["d"] for r in old.get("tdesc", [])}
    ntd = {r["tbl"]: r["d"] for r in new.get("tdesc", [])}
    both = nt.keys() & ot.keys()
    dchanged = sorted({k[0][0] for k in set(od.items()) ^ set(nd.items()) if k[0][0] in both} |
                      {k[0] for k in set(otd.items()) ^ set(ntd.items()) if k[0] in both})
    if dchanged:
        changes.append("MS_Description changed on " + ", ".join(dchanged[:15]) + (" ..." if len(dchanged) > 15 else ""))
    for t in sorted(set(new.get("lookups", {})) | set(old.get("lookups", {}))):
        if json.dumps(new["lookups"].get(t), sort_keys=True) != json.dumps(old.get("lookups", {}).get(t), sort_keys=True):
            changes.append(f"Lookup values changed: {t}")
    return changes


def file_hash(*paths):
    h = hashlib.sha256()
    for p in paths:
        with open(p, "rb") as f:
            h.update(f.read())
    return h.hexdigest()[:16]


def schema_hash(snap, configured):
    t, f = schema_view(snap, configured)
    extra = (snap.get("lookups"), [r for r in snap.get("tdesc", []) if r["tbl"] in t],
             sorted((r["tbl"], r["col"], r["descr"]) for r in snap["cols"] if r["descr"] and r["tbl"] in t))
    return hashlib.sha256(json.dumps([sorted(t.items()), sorted(f), extra], sort_keys=True, default=str).encode()).hexdigest()[:16]


def next_version(history):
    if not history:
        return "1.0"
    major, minor = history[-1]["version"].split(".")
    return f"{major}.{int(minor) + 1}"


def load(path, default=None):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return default


def save(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")


# ── main ───────────────────────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Refresh the data dictionary from the database.")
    ap.add_argument("--check", action="store_true", help="report only; exit 1 when the document is out of date")
    ap.add_argument("--offline", action="store_true", help="use the saved snapshot instead of the database")
    ap.add_argument("--force", action="store_true", help="rebuild even when nothing changed")
    ap.add_argument("--no-revision", action="store_true", help="rebuild without a revision-history entry (layout / tooling changes)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    say = (lambda *x: None) if a.quiet else print

    configured = configured_tables()
    old = load(SNAPSHOT)
    if a.offline:
        if old is None:
            sys.exit("No saved snapshot yet: run once without --offline.")
        new = old
    else:
        try:
            new = extract()
        except Exception as e:  # database not reachable: do not block the caller
            print(f"data dictionary: could not read the database ({type(e).__name__}); nothing updated.")
            sys.exit(2)

    all_tables = set(new.get("tables") or {r["tbl"] for r in new["cols"]})
    unknown = sorted(t for t in all_tables if t not in configured and in_scope(t, configured))
    gone = sorted(t for t in configured if t not in all_tables)
    changes = compare(old, new, configured)
    cfg_hash = file_hash(os.path.join(HERE, "dd_config.py"), os.path.join(HERE, "build_docx.py"))
    state = load(STATE, {})
    sch_hash = schema_hash(new, configured)
    schema_changed = old is None or state.get("schema_hash") != sch_hash
    config_changed = state.get("config_hash") != cfg_hash
    stale = schema_changed or config_changed or not os.path.exists(DOCX)

    for c in changes:
        say("  •", c)
    if unknown:
        say(f"  ! {len(unknown)} table(s) not yet grouped into a module (listed under 'Other ... tables'): {', '.join(unknown)}")
    if gone:
        say(f"  ! configured but no longer in the database: {', '.join(gone)}")

    if a.check:
        print("data dictionary: " + ("OUT OF DATE" if stale else "up to date") + (f"; {len(unknown)} ungrouped table(s)" if unknown else ""))
        sys.exit(1 if stale or unknown else 0)
    if not stale and not a.force:
        say("data dictionary: up to date.")
        return

    history = load(HISTORY, [])
    entry = []
    if not history:
        n = len([t for t in all_tables if in_scope(t, configured)])
        entry = [f"Initial release: Common foundation, OPD, LAB, Pharmacy, Accounts and Inventory ({n} tables)"]
    else:
        entry = list(changes)
        if config_changed:
            entry.append("Descriptions / module grouping updated")
        if not entry:
            entry = ["Regenerated (no schema change)"]
    baseline = (old is None and history and not a.force) or a.no_revision   # first run with an existing history: just take a baseline
    if (schema_changed or config_changed or not history) and not baseline:
        history.append({"version": next_version(history), "date": datetime.date.today().strftime("%d %b %Y"),
                        "changes": entry, "by": os.environ.get("USER", "")})
        save(HISTORY, history)
    if not a.offline:
        save(SNAPSHOT, new)

    r = subprocess.run([sys.executable, os.path.join(HERE, "build_docx.py"), "--snapshot", SNAPSHOT,
                        "--history", HISTORY, "--out", DOCX], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-3000:])
        sys.exit("data dictionary: building the document failed.")
    save(STATE, {"schema_hash": sch_hash, "config_hash": cfg_hash, "version": history[-1]["version"],
                 "built_on": datetime.datetime.now().isoformat(timespec="seconds")})
    m = re.search(r"tables \d+ columns \d+ relations \d+", r.stdout)
    print(f"data dictionary: version {history[-1]['version']} written to {os.path.relpath(DOCX, ROOT)}"
          + (f" ({m.group(0)})" if m else ""))


if __name__ == "__main__":
    main()
