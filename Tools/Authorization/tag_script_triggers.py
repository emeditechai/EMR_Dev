"""Second pass of tag_views.py: buttons that reach an endpoint through script.

For each page action still without a tagged trigger it finds, in the page's views, the script that calls the endpoint
(fetch / $.ajax / $.post / location.href with the URL), then the element that starts that script:
  - a named function  (function saveX(...) / const saveX = async (...) =>)  -> elements with onclick="saveX("
  - a jQuery handler  ($('#btnSave').on('click', ...) / $(document).on('click', '.btn-x', ...)) -> that id / class
Razor markup gets asp-permission; markup built inside <script> gets data-permission (checked in the browser).

Usage: python3 Tools/Authorization/tag_script_triggers.py [--apply]
"""
import collections, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import map_endpoints as me
import page_controls as pc

def main():
    pages = pc.build()
    rows = me.q("SELECT m.Http_Method, m.Controller, m.Action, p.Page_Code, c.Control_Code FROM dbo.PageEndpointMap m "
                "JOIN dbo.PageMaster p ON p.Page_ID = m.Page_ID JOIN dbo.PageControlMaster c ON c.Control_ID = m.Control_ID "
                "WHERE m.App = 'WEB' AND m.IsActive = 1 AND p.CompanyId = 1 AND c.IsActive = 1 AND c.Control_Code <> 'VIEW'")
    # the Security screens switch editing off themselves (CAN_EDIT)
    texts = {v: open(os.path.join(me.ROOT, "EMR.Web", v), encoding="utf-8", errors="ignore").read()
             for v in me.files if v.startswith("Views/") and not v.startswith("Views/Security/")}
    blob = "\n".join(texts.values())
    todo = collections.defaultdict(set)                       # (controller, action) -> {(page, code)}
    for meth, c, a, page, code in rows:
        if not re.search(re.escape(page) + ":" + re.escape(code) + r"\b", blob):
            todo[(c, a)].add((page, code))

    edits = collections.defaultdict(dict)                     # view -> {start_pos: (start_tag, set(perms), attr)}
    unresolved = []
    for (c, a), targets in sorted(todo.items()):
        found_any = False
        for view, text in texts.items():
            vp = me.pages_for_view(view)
            perms = {f"{p}:{code}" for p, code in targets if p in vp}
            if not perms:
                continue
            own = view.startswith(f"Views/{c}/")
            pats = [rf'Url\.Action\(\s*"{a}"\s*,\s*"{c}"', rf"/{c}/{a}\b"] + ([rf'Url\.Action\(\s*"{a}"\s*\)', rf"['\"]{a}['\"]"] if own else [])
            scripts = [(x.start(), x.end()) for x in re.finditer(r"<script\b.*?</script>", text, re.S)]
            for pat in pats:
                for ref in re.finditer(pat, text):
                    if not any(s <= ref.start() < e for s, e in scripts):
                        continue
                    before = text[max(0, ref.start() - 4000):ref.start()]
                    fn = list(re.finditer(r"(?:function\s+([A-Za-z_$][\w$]*)\s*\(|(?:window\.)?([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>))", before))
                    handler = list(re.finditer(r"\$\(\s*['\"]([#.][\w-]+)['\"]\s*\)\s*\.(?:on\(\s*['\"]click['\"]|click\()|\.on\(\s*['\"]click['\"]\s*,\s*['\"]([#.][\w-]+)['\"]"
                                               r"|getElementById\(['\"]([\w-]+)['\"]\)\s*(?:\?)?\.(?:addEventListener\(\s*['\"]click['\"]|onclick)", before))
                    last_fn = fn[-1] if fn else None
                    last_h = handler[-1] if handler else None
                    selector = None
                    if last_h and (not last_fn or last_h.start() > last_fn.start()):
                        g = last_h.group(1) or last_h.group(2) or ("#" + last_h.group(3) if last_h.group(3) else None)
                        selector = g
                    elif last_fn:
                        selector = "fn:" + (last_fn.group(1) or last_fn.group(2))
                    if not selector:
                        continue
                    for m in re.finditer(r"<(a|button|li|input|span|div)\b[^>]*>", text, re.S):
                        st = m.group(0)
                        hit = (selector.startswith("fn:") and re.search(r'on(?:click|change)="[^"]*\b' + re.escape(selector[3:]) + r"\(", st)) or \
                              (selector.startswith("#") and re.search(r'\bid="' + re.escape(selector[1:]) + '"', st)) or \
                              (selector.startswith(".") and m.group(1) in ("a", "button", "li") and re.search(r'class="[^"]*\b' + re.escape(selector[1:]) + r'\b', st))
                        if not hit or "asp-permission" in st or "data-permission" in st or re.search(r'id="btnSearch"|type="number"', st):
                            continue
                        in_script = any(s <= m.start() < e for s, e in scripts)
                        cur = edits[view].setdefault(m.start(), [st, set(), "data-permission" if in_script else "asp-permission"])
                        cur[1] |= perms
                        found_any = True
        if not found_any:
            unresolved.append(f"{c}/{a} -> {sorted(targets)}")

    n = sum(len(v) for v in edits.values())
    print(f"{n} element(s) in {len(edits)} view(s)")
    for view in sorted(edits):
        for pos, (st, perms, attr) in sorted(edits[view].items()):
            print(f"  {view}: {','.join(sorted(perms)):<50} {attr[:4]} {re.sub(r'\\s+', ' ', st)[:100]}")
    print("\nNOT FOUND (wire by hand):"); [print("  ", u) for u in unresolved]

    if "--apply" in sys.argv:
        for view, items in edits.items():
            path = os.path.join(me.ROOT, "EMR.Web", view)
            raw = open(path, newline="", encoding="utf-8").read()
            for pos, (st, perms, attr) in sorted(items.items(), reverse=True):
                tag = re.match(r"<(\w+)", st).group(0)
                assert raw[pos:pos + len(st)] == st, (view, st[:60])
                raw = raw[:pos] + tag + f' {attr}="{",".join(sorted(perms))}"' + raw[pos + len(tag):]
            open(path, "w", newline="", encoding="utf-8").write(raw)
        print("applied")

if __name__ == "__main__":
    main()
