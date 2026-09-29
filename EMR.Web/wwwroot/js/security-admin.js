/* Settings > Security screens - shared helpers.
   The browser only stages and explains; every rule is enforced again by the server and the database. */
(function (w) {
    'use strict';

    const Sec = {};

    Sec.esc = function (v) {
        return String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    };

    Sec.token = function () {
        const el = document.querySelector('#secAntiForgery input[name="__RequestVerificationToken"]');
        return el ? el.value : '';
    };

    Sec.get = async function (url, params) {
        const qs = params ? '?' + new URLSearchParams(Object.entries(params).filter(([, v]) => v !== null && v !== undefined && v !== '')).toString() : '';
        const res = await fetch(url + qs, { headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } });
        return Sec._read(res);
    };

    /** POST: an object/array body goes as JSON; `form` params go as form fields. */
    Sec.post = async function (url, body, form) {
        const headers = { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest', 'RequestVerificationToken': Sec.token() };
        let payload;
        if (form) {
            payload = new URLSearchParams(Object.entries(form).filter(([, v]) => v !== null && v !== undefined).map(([k, v]) => [k, String(v)]));
        } else {
            headers['Content-Type'] = 'application/json';
            payload = JSON.stringify(body ?? {});
        }
        const res = await fetch(url, { method: 'POST', headers, body: payload });
        return Sec._read(res);
    };

    Sec._read = async function (res) {
        if (res.status === 403) {
            let j = null; try { j = await res.json(); } catch { /* not json */ }
            return { success: false, code: 'FORBIDDEN', message: (j && j.message) || 'You do not have permission to perform this action.' };
        }
        if (!res.ok) return { success: false, message: 'The server could not complete the request (' + res.status + ').' };
        try { return await res.json(); } catch { return { success: false, message: 'Unexpected response from the server.' }; }
    };

    const toast = w.Swal ? Swal.mixin({ toast: true, position: 'top-end', showConfirmButton: false, timer: 3200, timerProgressBar: true }) : null;
    Sec.ok = msg => toast ? toast.fire({ icon: 'success', title: msg }) : alert(msg);
    Sec.warn = msg => toast ? toast.fire({ icon: 'warning', title: msg, timer: 4500 }) : alert(msg);
    Sec.fail = msg => w.Swal ? Swal.fire({ icon: 'error', title: 'Not saved', text: msg, confirmButtonColor: '#dc3545' }) : alert(msg);
    Sec.confirm = async function (title, html, confirmText, icon) {
        if (!w.Swal) return confirm(title);
        const r = await Swal.fire({ icon: icon || 'question', title, html, showCancelButton: true, confirmButtonText: confirmText || 'Continue',
            confirmButtonColor: '#0d6efd', cancelButtonText: 'Cancel', reverseButtons: true, focusCancel: true });
        return r.isConfirmed;
    };
    Sec.ask = async function (title, label, value, minLength) {
        if (!w.Swal) return prompt(title, value || '');
        const r = await Swal.fire({
            title, input: 'textarea', inputLabel: label, inputValue: value || '', showCancelButton: true, confirmButtonText: 'OK', reverseButtons: true,
            inputValidator: v => (minLength && (v || '').trim().length < minLength) ? ('At least ' + minLength + ' characters, please.') : undefined
        });
        return r.isConfirmed ? (r.value || '').trim() : null;
    };

    Sec.scopeName = function (s) {
        return ({ 5: 'Control', 4: 'Page', 3: 'Sub-menu', 2: 'Menu item', 1: 'Nav bar item', 99: 'Super admin', 0: 'No row at any scope' })[s] || '—';
    };

    /**
     * Builds the navigation tree from the admin payload: nav bar item > menu item > sub-menu item, with pages
     * attached where they sit. Returns lookups used by all screens.
     */
    Sec.buildTree = function (tree, includeInactive) {
        const menus = (tree.menus || []).filter(m => includeInactive || m.isActive);
        const pages = (tree.pages || []).filter(p => includeInactive || p.isActive);
        const controls = (tree.controls || []).filter(c => includeInactive || c.isActive);
        const menuById = new Map(menus.map(m => [m.menu_ID, { ...m, kind: m.menu_Type, children: [] }]));
        const pageById = new Map(pages.map(p => [p.page_ID, { ...p, kind: 'PAGE', controls: [] }]));
        controls.forEach(c => { const p = pageById.get(c.page_ID); if (p) p.controls.push(c); });
        pageById.forEach(p => p.controls.sort((a, b) => a.sort_Order - b.sort_Order || a.control_ID - b.control_ID));

        const roots = [];
        menuById.forEach(m => {
            const parent = m.parent_Menu_ID ? menuById.get(m.parent_Menu_ID) : null;
            (parent ? parent.children : roots).push(m);
        });
        const orphanPages = [];
        pageById.forEach(p => {
            const parent = p.menu_ID ? menuById.get(p.menu_ID) : null;
            (parent ? parent.children : orphanPages).push(p);
        });
        const sortKids = n => { n.children && n.children.sort((a, b) => a.sort_Order - b.sort_Order); (n.children || []).forEach(sortKids); };
        roots.sort((a, b) => a.sort_Order - b.sort_Order); roots.forEach(sortKids);

        /** submenu / menu / nav ids above a page or a menu node */
        function chain(node) {
            const out = { sub: null, menu: null, nav: null };
            let m = node.kind === 'PAGE' ? (node.menu_ID ? menuById.get(node.menu_ID) : null) : node;
            while (m) {
                if (m.menu_Type === 'SUBMENU' && !out.sub) out.sub = m.menu_ID;
                if (m.menu_Type === 'MENU' && !out.menu) out.menu = m.menu_ID;
                if (m.menu_Type === 'NAV' && !out.nav) out.nav = m.menu_ID;
                m = m.parent_Menu_ID ? menuById.get(m.parent_Menu_ID) : null;
            }
            return out;
        }
        function pagesBeneath(node) {
            if (node.kind === 'PAGE') return [node];
            return (node.children || []).flatMap(pagesBeneath);
        }
        function menusBeneath(node) {
            return (node.children || []).filter(c => c.kind !== 'PAGE').flatMap(c => [c, ...menusBeneath(c)]);
        }
        return { roots, orphanPages, menuById, pageById, chain, pagesBeneath, menusBeneath, vocabulary: tree.vocabulary || [] };
    };

    Sec.kindLabel = k => ({ NAV: 'Nav bar item', MENU: 'Menu item', SUBMENU: 'Sub-menu item', PAGE: 'Page' })[k] || k;

    Sec.icon = cls => cls ? '<i class="' + Sec.esc(cls.replace(/\bme-\d\b/g, '').trim()) + ' me-1"></i>' : '';

    /** Warn before leaving with staged, unsaved changes. */
    Sec.guardUnsaved = function (hasPending) {
        w.addEventListener('beforeunload', e => { if (hasPending()) { e.preventDefault(); e.returnValue = ''; } });
    };

    /** Keyboard support for grids of .sec-cell buttons: arrows move, space/enter toggle (native button). */
    Sec.gridKeys = function (container) {
        container.addEventListener('keydown', e => {
            const cell = e.target.closest('.sec-cell');
            if (!cell || !['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(e.key)) return;
            const row = cell.closest('tr'); const cells = [...row.querySelectorAll('.sec-cell')]; const i = cells.indexOf(cell);
            let target = null;
            if (e.key === 'ArrowLeft') target = cells[i - 1];
            if (e.key === 'ArrowRight') target = cells[i + 1];
            if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
                let r = e.key === 'ArrowUp' ? row.previousElementSibling : row.nextElementSibling;
                while (r && (r.style.display === 'none' || !r.querySelector('.sec-cell'))) r = e.key === 'ArrowUp' ? r.previousElementSibling : r.nextElementSibling;
                if (r) { const rc = [...r.querySelectorAll('.sec-cell')]; target = rc[Math.min(i, rc.length - 1)]; }
            }
            if (target) { e.preventDefault(); target.focus(); }
        });
    };

    w.Sec = Sec;
})(window);
