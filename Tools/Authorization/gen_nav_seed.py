"""Generates SQLScripts/2163_authorization_seed_nav_tree.sql from the nav bar in _Layout.cshtml.
Usage (from the repo root): python3 Tools/Authorization/gen_nav_seed.py
"""
import re, html, json
from html.parser import HTMLParser

import os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "EMR.Web", "Views", "Shared", "_Layout.cshtml")
OUT = os.path.join(ROOT, "SQLScripts", "2163_authorization_seed_nav_tree.sql")

content = open(SRC, encoding="utf-8").read()
frag = content[content.index('<ul class="navbar-nav me-auto mb-2 mb-xl-0 emr-main-menu">'):
               content.index('<div class="d-flex align-items-center gap-1.5 ms-auto emr-top-actions">')]

class Node:
    def __init__(s, kind, **kw):
        s.kind = kind; s.children = []
        s.title = kw.get('title'); s.icon = kw.get('icon'); s.controller = kw.get('controller')
        s.action = kw.get('action'); s.route = kw.get('route') or {}; s.target = kw.get('target')

class P(HTMLParser):
    def __init__(s):
        super().__init__(convert_charrefs=True)
        s.stack = []; s.top = []; s.li = []; s.a = None; s.text = ""; s.icon = None; s.active = False; s.depth = 0
    def handle_starttag(s, tag, attrs):
        a = dict(attrs); cls = a.get('class', '') or ''
        if tag == 'ul':
            if not s.active and 'navbar-nav' in cls: s.active = True; s.depth = 1; return
            if s.active: s.depth += 1
            return
        if not s.active: return
        if tag == 'li':
            s.li.append('nav' if 'nav-item' in cls else 'sub' if 'dropdown-submenu' in cls else 'plain')
        elif tag == 'a':
            s.a = a; s.text = ""; s.icon = None
        elif tag == 'i' and s.a is not None and s.icon is None:
            if 'submenu-arrow' not in cls: s.icon = cls.strip()
        elif tag == 'hr' and 'dropdown-divider' in cls and s.stack:
            s.stack[-1].children.append(Node('DIVIDER'))
    def handle_data(s, d):
        if s.a is not None: s.text += d
    def handle_endtag(s, tag):
        if not s.active: return
        if tag == 'a' and s.a is not None:
            a = s.a; cls = a.get('class', '') or ''
            title = re.sub(r'\s+', ' ', s.text).strip()
            ctl, act = a.get('asp-controller'), a.get('asp-action')
            route = {ROUTE_CASE.get(k[10:], k[10:]): v for k, v in a.items() if k.startswith('asp-route-')}
            if 'dropdown-toggle' in cls and 'dropdown-submenu-toggle' not in cls and a.get('id'):
                n = Node('NAV', title=title, icon=s.icon); s.top.append(n); s.stack.append(n)
            elif 'dropdown-submenu-toggle' in cls:
                n = Node('MENU' if len(s.stack) == 1 else 'SUBMENU', title=title, icon=s.icon)
                s.stack[-1].children.append(n); s.stack.append(n)
            elif ctl and act:
                n = Node('PAGE', title=title, icon=s.icon, controller=ctl, action=act, route=route, target=a.get('target'))
                if s.stack: s.stack[-1].children.append(n)
                else:
                    nav = Node('NAV', title=title, icon=s.icon); nav.children.append(n); s.top.append(nav)
            s.a = None
        elif tag == 'li' and s.li:
            k = s.li.pop()
            if s.stack and ((k == 'nav' and s.stack[-1].kind == 'NAV') or (k == 'sub' and s.stack[-1].kind in ('MENU', 'SUBMENU'))):
                s.stack.pop()
        elif tag == 'ul':
            if s.depth > 1: s.depth -= 1
            else: s.active = False

ROUTE_CASE = {m.lower(): m for m in re.findall(r'asp-route-([A-Za-z0-9_]+)', frag)}
p = P(); p.feed(frag)

def slug(t): return re.sub(r'_+', '_', re.sub(r'[^A-Za-z0-9]', '_', t.upper())).strip('_')
def q(v): return "NULL" if v is None else "N'" + v.replace("'", "''") + "'"

lines = []; used_codes = set(); counter = [0]
stats = {'NAV': 0, 'MENU': 0, 'SUBMENU': 0, 'PAGE': 0}

def emit(node, parent_var, nav_code, menu_codes, sort):
    counter[0] += 1
    var = f"@m{counter[0]}"
    if node.kind in ('NAV', 'MENU', 'SUBMENU'):
        stats[node.kind] += 1
        code = slug(node.title) if node.kind == 'NAV' else nav_code + '.' + '.'.join(menu_codes + [slug(node.title)])
        lines.append(f"    DECLARE {var} INT;")
        lines.append(f"    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId=@CompanyId, @Parent_Menu_ID={parent_var or 'NULL'}, "
                     f"@Menu_Type='{node.kind}', @Menu_Code={q(code)}, @Title={q(node.title)}, @Icon={q(node.icon)}, "
                     f"@Sort_Order={sort}, @UserId=NULL, @Menu_ID={var} OUTPUT;")
        ncode = slug(node.title) if node.kind == 'NAV' else nav_code
        mcodes = [] if node.kind == 'NAV' else menu_codes + [slug(node.title)]
        s = 0
        for c in node.children:
            if c.kind == 'DIVIDER': s += 10; continue
            s += 10
            emit(c, var, ncode, mcodes, s)
    else:
        stats['PAGE'] += 1
        parts = [nav_code]
        if node.controller.upper() != nav_code: parts.append(node.controller.upper())
        if node.action != 'Index': parts.append(node.action.upper())
        parts += [v.upper() for v in node.route.values()]
        if len(parts) == 1: parts.append('INDEX')
        code = '.'.join(parts)
        if code in used_codes:
            code = '.'.join([nav_code] + menu_codes + parts[1:])
        used_codes.add(code)
        rv = '&'.join(f"{k}={v}" for k, v in node.route.items()) or None
        lines.append(f"    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId=@CompanyId, @Menu_ID={parent_var}, @Page_Code={q(code)}, "
                     f"@Title={q(node.title)}, @Controller={q(node.controller)}, @Action={q(node.action)}, @Show_In_Menu=1, "
                     f"@Sort_Order={sort}, @Icon={q(node.icon)}, @Route_Values={q(rv)}, @Link_Target={q(node.target)}, "
                     f"@UserId=NULL, @Page_ID=@page OUTPUT;")
        lines.append("    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';")
        lines.append(f"    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID=@page, @Control_ID=@view, @App='WEB', @Http_Method='GET', "
                     f"@Controller={q(node.controller)}, @Action={q(node.action)}, @Source='SEED';")

for i, n in enumerate(p.top):
    emit(n, None, None, [], (i + 1) * 10)

header = """-- ============================================================================
-- Migration: 2163_authorization_seed_nav_tree.sql
-- Description:
--   Server-Side Authorization - Phase 1: the navigation bar hard-coded in
--   _Layout.cshtml, converted once into MenuMaster / PageMaster with the same
--   titles, icons, nesting and order, plus each page's VIEW endpoint mapping.
--   GENERATED from _Layout.cshtml by a parser - re-generate rather than hand-edit.
--
--   Conversion rules (blueprint "Moving the nav bar into the database"):
--     top-level entry           -> NAV (Home and IPD hold their single page)
--     dropdown-submenu toggle   -> MENU (SUBMENU if nested one level further)
--     item with controller/action -> PageMaster row, Show_In_Menu = 1, GET mapped to VIEW
--     divider                   -> a gap in Sort_Order (step 20 instead of 10)
--     disabled "#" placeholders -> skipped (they lead nowhere)
--   Counts: %(NAV)d nav items, %(MENU)d menus, %(SUBMENU)d sub-menus, %(PAGE)d menu pages.
--   Idempotent: every row is upserted by its code.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_SeedNavTree
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @page INT, @view INT;
    BEGIN TRANSACTION;
""" % stats
footer = """
    COMMIT TRANSACTION;
END;
GO

DECLARE @co INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN c; FETCH NEXT FROM c INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_SeedNavTree @CompanyId = @co;
    FETCH NEXT FROM c INTO @co;
END
CLOSE c; DEALLOCATE c;
GO

PRINT 'Script 2163 applied: navigation tree seeded from _Layout.cshtml.';
GO
"""
open(OUT, 'w').write(header + "\n".join(lines) + "\n" + footer)
print(stats, "codes:", len(used_codes))
