"""Parity test: the nav tree in the database must render exactly like the markup in _Layout.cshtml.
Usage (from the repo root): python3 Tools/Authorization/nav_parity_check.py   -> exits 1 on any difference
"""
import json, subprocess, sys, re, os
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
# reuse the generator's parser without writing files
src = open(os.path.join(HERE, "gen_nav_seed.py")).read().split("def slug")[0]
src = src.replace("__file__", repr(os.path.join(HERE, "gen_nav_seed.py")))
ns = {}; exec(src, ns)
markup = ns["p"].top

cs = dict(kv.split("=", 1) for kv in json.load(open(os.path.join(ROOT, "EMR.Web", "appsettings.json")))["ConnectionStrings"]["DefaultConnection"].split(";") if "=" in kv)
def q(sql):
    out = subprocess.run(["sqlcmd","-S",cs["Server"],"-U",cs["User Id"],"-P",cs["Password"],"-C","-d",cs["Database"],"-h","-1","-W","-s","\t","-Q","SET NOCOUNT ON;"+sql],capture_output=True,text=True).stdout
    return [l.split("\t") for l in out.strip().splitlines() if l.strip()]
menus = q("SELECT Menu_ID, ISNULL(CAST(Parent_Menu_ID AS VARCHAR),''), Menu_Type, Title, ISNULL(Icon,''), Sort_Order FROM dbo.MenuMaster WHERE CompanyId=1 AND IsActive=1")
pages = q("SELECT Page_ID, CAST(Menu_ID AS VARCHAR), Title, Controller, Action, ISNULL(Icon,''), ISNULL(Route_Values,''), ISNULL(Link_Target,''), Sort_Order FROM dbo.PageMaster WHERE CompanyId=1 AND IsActive=1 AND Show_In_Menu=1")

def db_children(mid):
    items = [("MENU", int(m[5]), m[3], m[4], None, m[0]) for m in menus if m[1] == mid]
    items += [("PAGE", int(p[8]), p[2], p[5], (p[3], p[4], p[6], p[7]), None) for p in pages if p[1] == mid]
    items.sort(key=lambda x: x[1]); out = []; prev = None
    for it in items:
        if prev is not None and it[1] - prev > 10: out.append(("DIVIDER",))
        prev = it[1]
        if it[0] == "MENU": out.append(("GROUP", it[2], it[3], db_children(it[5])))
        else: out.append(("LINK", it[2], it[3], it[4]))
    return out
db = [("GROUP", n[3], n[4], db_children(n[0])) for n in sorted([m for m in menus if m[1]==""], key=lambda m:int(m[5]))]

def mk(n):
    if n.kind == "DIVIDER": return ("DIVIDER",)
    if n.kind == "PAGE": return ("LINK", n.title, n.icon or "", (n.controller, n.action, "&".join(f"{k}={v}" for k, v in n.route.items()), n.target or ""))
    return ("GROUP", n.title, n.icon or "", [mk(c) for c in n.children])
mark = [mk(n) for n in markup]

diffs = []
def cmp(a, b, path):
    if len(a) != len(b): diffs.append(f"{path}: {len(a)} items in markup vs {len(b)} in db"); 
    for i,(x,y) in enumerate(zip(a,b)):
        p = f"{path}/{x[1] if len(x)>1 else '---'}"
        if x[0] != y[0] or x[1:3] != y[1:3]: diffs.append(f"{p}: markup={x[:3]} db={y[:3]}"); continue
        if x[0] == "LINK" and x[3] != y[3]: diffs.append(f"{p}: target markup={x[3]} db={y[3]}")
        if x[0] == "GROUP": cmp(x[3], y[3], p)
cmp(mark, db, "")
count = lambda t: sum((1 if i[0]=="LINK" else 0) + (count(i[3]) if i[0]=="GROUP" else 0) for i in t)
print(f"markup links: {count(mark)}, db links: {count(db)}, dividers markup: {json.dumps(mark).count('DIVIDER')}, db: {json.dumps(db).count('DIVIDER')}")
print("PARITY OK" if not diffs else "DIFFERENCES:\n" + "\n".join(diffs[:30]))

sys.exit(0 if not diffs else 1)
