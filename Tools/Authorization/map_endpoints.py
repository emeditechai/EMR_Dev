"""Endpoint mapper: proposes and (with --apply) writes a page + control for every unmapped WEB endpoint.

How a page is found for an endpoint
  1. its own screen: the page whose Controller/Action is the endpoint (or the only screen that controller serves);
  2. every view / script that calls it (Url.Action, "/Controller/Action", asp-controller/asp-action), each resolved
     to the page that view belongs to - shared partials and scripts resolve to the pages that host them.
  An endpoint used by several screens is mapped to all of them (allowed if the user can use any one).

How a control is chosen
  Ordinary work (open, look up, create, edit, save, print, export) belongs to the page itself (VIEW), so anyone
  given the page can use it. Only money and report-integrity actions get their own control, which must be ticked
  explicitly: APPROVE, UNAUTHORIZE, CANCEL, REFUND, DISCOUNT, SETTLE, DELETE.

After mapping, run page_controls.py: it gives every endpoint the page action (control) it belongs to.

Usage (from the repo root):
  python3 Tools/Authorization/map_endpoints.py            -> report only
  python3 Tools/Authorization/map_endpoints.py --apply    -> writes the mappings (usp_Auth_Admin_MapEndpoints)
"""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
cs = dict(kv.split("=", 1) for kv in json.load(open(os.path.join(ROOT, "EMR.Web", "appsettings.json")))["ConnectionStrings"]["DefaultConnection"].split(";") if "=" in kv)
SQLCMD = ["sqlcmd", "-S", cs["Server"], "-U", cs["User Id"], "-P", cs["Password"], "-C", "-d", cs["Database"], "-b"]

def q(sql):
    out = subprocess.run(SQLCMD + ["-h", "-1", "-W", "-s", "\t", "-Q", "SET NOCOUNT ON;" + sql], capture_output=True, text=True).stdout
    return [l.split("\t") for l in out.strip().splitlines() if l.strip()]

pages = [dict(id=int(r[0]), code=r[1], controller=r[2], action=r[3]) for r in
         q("SELECT Page_ID, Page_Code, Controller, Action FROM dbo.PageMaster WHERE IsActive = 1 AND CompanyId = 1")]
by_code = {p["code"]: p for p in pages}
endpoints = [dict(id=int(r[0]), method=r[1], controller=r[2], action=r[3]) for r in
             q("SELECT Endpoint_ID, Http_Method, Controller, Action FROM dbo.PageEndpointMap "
               "WHERE App = 'WEB' AND IsActive = 1 AND Page_ID IS NULL AND Is_Public = 0 AND Is_Orphaned = 0")]

# Screens not reachable from the menu, and sub-views of a screen: which page they belong to.
VIEW_PAGE_OVERRIDES = {
    "Views/OPD/Index.cshtml": ["MASTER.OPD"], "Views/OPD/Details.cshtml": ["MASTER.OPD"],
    "Views/OPD/NewServiceBooking.cshtml": ["OPD.SERVICEBOOKING"], "Views/OPD/MonitorDisplay.cshtml": ["OPD.TOKENMANAGEMENT"],
    "Views/Vitals/RecordVital.cshtml": ["OPD.VITALS"], "Views/Vitals/History.cshtml": ["OPD.VITALS"],
    "Views/DoctorSchedules/Configure.cshtml": ["MASTER.DOCTORS"],
    "Views/Access/Index.cshtml": ["SETTINGS.ACCESS"], "Views/Access/Assign.cshtml": ["SETTINGS.ACCESS"],
    "Views/Users/_Form.cshtml": ["SETTINGS.USERS"],
    "wwwroot/js/lab-compliance-docs.js": ["LAB.LABORDERBOOKING.B2CBOOKING", "LAB.LABORDERBOOKING.B2BBOOKING"],
    "wwwroot/js/lab-compliance-docs-viewer.js": ["LAB.LABORDERBOOKING.B2BREGISTRATION", "LAB.LABORDERBOOKING.B2CORDERLIST"],
}
# Controllers whose screens are not in the menu: the page they belong to.
CONTROLLER_PAGE = {"Access": ["SETTINGS.ACCESS"], "LabSampleRejections": ["MASTER.LAB_MASTER.LABSAMPLEREJECTIONS"],
                   "DoctorSchedules": ["MASTER.DOCTORS"]}
SKIP_VIEW_PREFIX = ("Views/PatientPortal/",)
# Endpoints no view references directly (URL built at runtime): the screens that use them.
ENDPOINT_PAGE = {("LabOrderBooking", "FranchiseWalletStatement"): ["LAB.LABORDERBOOKING.B2BBOOKING", "REPORTS.LABFRANCHISEWALLET"],
                 ("OPD", "SearchBookingSuggestions"): ["OPD.DASHBOARD", "OPD.SERVICEBOOKING"]}   # the patient portal is not a staff screen

files = {}
for base in ("Views", os.path.join("wwwroot", "js")):
    for root, _, fs in os.walk(os.path.join(ROOT, "EMR.Web", base)):
        for f in fs:
            if f.endswith((".cshtml", ".js")):
                p = os.path.join(root, f)
                files[os.path.relpath(p, os.path.join(ROOT, "EMR.Web"))] = open(p, encoding="utf-8", errors="ignore").read()

def hosts_of(partial_name):
    return [v for v, t in files.items() if v.startswith("Views/") and re.search(r'["/]' + re.escape(partial_name) + r'(\.cshtml)?"', t)]

def pages_for_view(view, seen=None):
    seen = seen or set()
    if view in seen or view.startswith(SKIP_VIEW_PREFIX): return set()
    seen.add(view)
    if view in VIEW_PAGE_OVERRIDES: return {c for c in VIEW_PAGE_OVERRIDES[view] if c in by_code}
    name = os.path.basename(view).rsplit(".", 1)[0]
    if view.endswith(".js"):
        return {c for h in files if h.startswith("Views/") and os.path.basename(view) in files[h] for c in pages_for_view(h, seen)}
    if name.startswith("_"):   # shared partial -> the pages hosting it
        return {c for h in hosts_of(name) for c in pages_for_view(h, seen)}
    parts = view.split("/")
    if len(parts) < 3 or parts[1] == "Shared": return set()
    controller = parts[1]
    exact = [p["code"] for p in pages if p["controller"] == controller and p["action"] == name]
    if exact: return set(exact)
    screens = {p["action"] for p in pages if p["controller"] == controller}
    if len(screens) == 1: return {p["code"] for p in pages if p["controller"] == controller}
    return set(CONTROLLER_PAGE.get(controller, []))

def callers(c, a):
    pats = [rf'Url\.Action\(\s*"{a}"\s*,\s*"{c}"', rf'/{c}/{a}\b', rf'asp-controller="{c}"[^>]*asp-action="{a}"', rf'asp-action="{a}"[^>]*asp-controller="{c}"']
    own = [rf'Url\.Action\(\s*"{a}"\s*[,)]', rf'asp-action="{a}"(?![^>]*asp-controller)', rf"['\"]{a}['\"?]"]
    hits = set()
    for v, t in files.items():
        if any(re.search(x, t) for x in pats): hits.add(v)
        elif v.startswith(f"Views/{c}/") and any(re.search(x, t) for x in own): hits.add(v)
    return hits

def own_pages(c, a):
    exact = [p["code"] for p in pages if p["controller"] == c and p["action"] == a]
    if exact: return set(exact)
    screens = {p["action"] for p in pages if p["controller"] == c}
    if len(screens) == 1: return {p["code"] for p in pages if p["controller"] == c}
    return set(CONTROLLER_PAGE.get(c, []))

SENSITIVE = [("UNAUTHORIZE", ("unapprove", "unauthori")), ("APPROVE", ("approve",)), ("REFUND", ("refund",)),
             ("CANCEL", ("cancel",)), ("SETTLE", ("settle", "wallettopup")), ("DISCOUNT", ("discount",))]

def control_for(method, action):
    a = action.lower()
    if method == "GET" and (a.startswith("get") or a.startswith("search") or a.startswith("print") or "report" in a):
        return "VIEW"                    # reading about an action is not performing it
    for code, words in SENSITIVE:
        if any(w in a for w in words): return code
    if method != "GET" and (a.startswith("delete") or a.startswith("remove")): return "DELETE"
    return "VIEW"

def main():
    plan, unresolved = [], []
    for e in endpoints:
        c, a = e["controller"], e["action"]
        targets = own_pages(c, a) | {x for x in ENDPOINT_PAGE.get((c, a), []) if x in by_code}
        is_postback = e["method"] != "GET" and any(p["controller"] == c and p["action"] == a for p in pages)
        if not is_postback:              # a screen's own post-back belongs to that screen, not to the screens linking to it
            for v in callers(c, a):
                targets |= pages_for_view(v)
        ctl = control_for(e["method"], a)
        if not targets: unresolved.append(e); continue
        for code in sorted(targets):
            plan.append(dict(e=e["id"], p=by_code[code]["id"], c=ctl, _ep=f'{e["method"]} {c}/{a}', _page=code))

    eps = {x["e"] for x in plan}
    print(f"{len(endpoints)} unmapped endpoints -> {len(eps)} resolved into {len(plan)} placement(s); {len(unresolved)} unresolved")
    from collections import Counter
    print("controls:", dict(Counter(x["c"] for x in {x['e']: x for x in plan}.values())))
    multi = Counter(x["e"] for x in plan)
    print("\nShared by several screens (sample):")
    for eid, n in multi.most_common(12):
        rows = [x for x in plan if x["e"] == eid]
        print(f"  {rows[0]['_ep']:<48} -> {', '.join(r['_page'] for r in rows)}")
    print("\nSensitive controls:")
    for x in {x['e']: x for x in plan}.values():
        if x["c"] != "VIEW": print(f"  {x['c']:<12} {x['_ep']}")
    if unresolved:
        print("\nUNRESOLVED:"); [print("  ", u["method"], u["controller"] + "/" + u["action"]) for u in unresolved]

    if "--apply" in sys.argv and plan:
        payload = json.dumps([{"e": x["e"], "p": x["p"], "c": x["c"]} for x in plan]).replace("'", "''")
        with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
            f.write("SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;\nEXEC dbo.usp_Auth_Admin_MapEndpoints @CompanyId = 1, @UserId = NULL, @Json = N'" + payload + "';\n")
        r = subprocess.run(SQLCMD + ["-i", f.name], capture_output=True, text=True)
        print("\nAPPLIED:", (r.stdout + r.stderr).strip()[-300:])


if __name__ == "__main__":
    main()
