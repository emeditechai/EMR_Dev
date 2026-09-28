"""Puts asp-permission="PAGE:CONTROL" on the buttons, links and forms that trigger each page action.

Uses the catalogue of page_controls.py: an element whose own markup calls an endpoint (asp-action / asp-controller,
Url.Action in href or action, "/Controller/Action" in href) gets the control that endpoint belongs to on the pages the
view serves. Buttons that only call a script function (the endpoint is fetched inside <script>) cannot be matched
this way; they are listed for hand wiring.

Usage (repo root):
  python3 Tools/Authorization/tag_views.py            -> report
  python3 Tools/Authorization/tag_views.py --apply    -> edits the views (keeps each file's line endings)
"""
import collections, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import map_endpoints as me
import page_controls as pc

TRIGGER_TAGS = ("a", "button", "form", "li")
SKIP_CODES = {"VIEW"}


def main():
    pages = pc.build()
    by_endpoint = collections.defaultdict(dict)          # (method, controller, action) -> {page_code: control}
    active = {(p["code"], c["code"]) for p in pages.values() for c in p["controls"].values() if c["active"]}
    rows = me.q("SELECT m.Http_Method, m.Controller, m.Action, p.Page_Code, c.Control_Code FROM dbo.PageEndpointMap m "
                "JOIN dbo.PageMaster p ON p.Page_ID = m.Page_ID JOIN dbo.PageControlMaster c ON c.Control_ID = m.Control_ID "
                "WHERE m.App = 'WEB' AND m.IsActive = 1 AND p.CompanyId = 1")
    for meth, c, a, page, code in rows:
        if code not in SKIP_CODES and (page, code) in active:
            by_endpoint[(meth, c, a)].setdefault(page, code)

    edits = collections.defaultdict(list)
    for view, text in me.files.items():
        if not view.startswith("Views/") or view.startswith(("Views/Security/", "Views/Shared/_Layout")):
            continue
        view_pages = me.pages_for_view(view)
        if not view_pages:
            continue
        controller = view.split("/")[1]
        view_name = os.path.basename(view).rsplit(".", 1)[0]
        scripts = [(x.start(), x.end()) for x in re.finditer(r"<script\b.*?</script>", text, re.S)]
        for m in re.finditer(r"<(a|button|form|li)\b[^>]*>", text, re.S):
            tag, start = m.group(1), m.group(0)
            if "asp-permission" in start or "data-permission" in start:
                continue
            ref = (re.search(r'asp-controller="(\w+)"', start), re.search(r'asp-action="(\w+)"', start),
                   re.search(r'Url\.Action\(\s*"(\w+)"(?:\s*,\s*"(\w+)")?', start), re.search(r'(?:href|action)="/(\w+)/(\w+)', start))
            target = None
            if ref[1]:
                target = ((ref[0].group(1) if ref[0] else controller), ref[1].group(1))
            elif ref[2]:
                target = (ref[2].group(2) or controller, ref[2].group(1))
            elif ref[3]:
                target = (ref[3].group(1), ref[3].group(2))
            if not target:
                continue
            # links open with GET; a form posts unless it says otherwise; a button is a form's submit
            method = "GET" if tag in ("a", "li") or "location.href" in start or (tag == "form" and re.search(r'method="get"', start, re.I)) else "POST"
            target = (method,) + target
            if target not in by_endpoint:
                continue
            # a Create / Edit screen's own post-back form: reaching the screen already needed the control
            if tag == "form" and target[1:] == (controller, view_name):
                continue
            perms = sorted({f"{p}:{code}" for p, code in by_endpoint[target].items() if p in view_pages})
            if not perms:
                continue
            in_script = any(a <= m.start() < b for a, b in scripts)   # markup built by script: checked in the browser
            edits[view].append((m.start(), m.end(), start, ",".join(perms), "data-permission" if in_script else "asp-permission"))

    total = sum(len(v) for v in edits.values())
    print(f"{total} element(s) in {len(edits)} view(s)")
    for view in sorted(edits):
        for _, _, start, perm, attr in edits[view]:
            print(f"  {view}: {perm:<55} {attr[:4]} {re.sub(r'\\s+', ' ', start)[:90]}")

    if "--apply" in sys.argv:
        for view, items in edits.items():
            path = os.path.join(me.ROOT, "EMR.Web", view)
            raw = open(path, newline="", encoding="utf-8").read()
            for s, e, start, perm, attr in sorted(items, reverse=True):
                tag = re.match(r"<(\w+)", start).group(0)
                assert raw[s:e] == start, (view, start[:60])
                raw = raw[:s] + tag + f' {attr}="{perm}"' + raw[s + len(tag):]
            open(path, "w", newline="", encoding="utf-8").write(raw)
        print("applied")


if __name__ == "__main__":
    main()
