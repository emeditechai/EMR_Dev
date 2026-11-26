// moved from Views/Shared/_Layout.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
// ── Submenu hover intent (menu-aim) ─────────────────────────────────────────────────────────────────────────────
// open: the row under the pointer opens its flyout, unless the pointer is on its way to the flyout already open
// (then the switch waits until the pointer stops aiming). close: a grace period, cancelled when the pointer comes back.
var SubmenuAim = (function () {
    var pts = [], active = null, closeTimer = null, switchTimer = null;
    var GRACE = 350, AIM_RECHECK = 120, TOLERANCE = 30;
    document.addEventListener('mousemove', function (e) {
        pts.push({ x: e.clientX, y: e.clientY, t: Date.now() });
        if (pts.length > 4) pts.shift();
    }, { passive: true });

    function reset(menu) {
        menu.classList.remove('show', 'open-left', 'is-fixed');
        menu.style.top = '0px'; menu.style.left = ''; menu.style.right = '';
    }
    function closeAll() {
        clearTimeout(closeTimer); clearTimeout(switchTimer);
        document.querySelectorAll('.dropdown-submenu-menu.show').forEach(reset);
        active = null;
    }
    function open(el, menu, position) {
        clearTimeout(closeTimer); clearTimeout(switchTimer);
        if (active && active.el !== el) reset(active.menu);
        menu.classList.add('show');
        if (!active || active.el !== el) position();
        active = { el: el, menu: menu };
    }
    // is the pointer moving into the triangle between where it was and the flyout's near edge?
    function aiming() {
        if (!active || pts.length < 2) return false;
        if (Date.now() - pts[pts.length - 1].t > 100) return false;   // the pointer has stopped: it is not on its way
        var r = active.menu.getBoundingClientRect();
        if (!r.width) return false;
        var cur = pts[pts.length - 1], prev = pts[0];
        var left = active.menu.classList.contains('open-left');
        var edgeX = left ? r.right : r.left;
        // already over the flyout, or past its edge: nothing to aim at
        if (left ? cur.x <= edgeX : cur.x >= edgeX) return false;
        var top = { x: edgeX, y: r.top - TOLERANCE }, bottom = { x: edgeX, y: r.bottom + TOLERANCE };
        var slope = function (a, b) { return (b.y - a.y) / (b.x - a.x || 0.0001); };
        var dTop = slope(cur, top), dBottom = slope(cur, bottom), pTop = slope(prev, top), pBottom = slope(prev, bottom);
        // moving toward the flyout: the angle to its top corner shrinks and to its bottom corner grows
        return left ? (dTop > pTop && dBottom < pBottom) : (dTop < pTop && dBottom > pBottom);
    }
    function enter(el, menu, position) {
        clearTimeout(closeTimer);
        if (active && active.el === el) return;                 // back on the open row / its flyout
        if (active && active.el.contains(el)) return open(el, menu, position);   // a flyout inside the open flyout
        if (active && aiming()) {                                // passing over this row on the way to the open flyout
            clearTimeout(switchTimer);
            var tryOpen = function () {
                if (aiming()) { switchTimer = setTimeout(tryOpen, AIM_RECHECK); return; }
                if (el.matches(':hover')) open(el, menu, position);
            };
            switchTimer = setTimeout(tryOpen, AIM_RECHECK);
            return;
        }
        open(el, menu, position);
    }
    function leave(el) {
        clearTimeout(switchTimer);
        if (!active || active.el !== el) return;
        clearTimeout(closeTimer);
        var check = function () {
            if (!active || active.el !== el) return;
            if (el.matches(':hover')) return;                    // came back
            if (aiming()) { closeTimer = setTimeout(check, AIM_RECHECK); return; }
            reset(active.menu); active = null;
        };
        closeTimer = setTimeout(check, GRACE);
    }
    return { enter: enter, leave: leave, open: open, closeAll: closeAll };
})();

        // Nested submenu: hover on desktop, click on mobile
        document.querySelectorAll('.dropdown-submenu').forEach(function (el) {
            var toggle = el.querySelector('.dropdown-submenu-toggle');
            var menu   = el.querySelector('.dropdown-submenu-menu');
            if (!toggle || !menu) return;

            var scrollParent = el.closest('.emr-menu-scroll');
            function positionSubmenu() {
                // inside a scrolling menu the flyout is placed on the page, next to its row (a scroll box would cut it off)
                if (scrollParent) {
                    var r = el.getBoundingClientRect();
                    var vw0 = window.innerWidth || document.documentElement.clientWidth;
                    var vh0 = window.innerHeight || document.documentElement.clientHeight;
                    menu.classList.add('is-fixed');
                    menu.classList.remove('open-left');
                    var w = menu.offsetWidth, h = menu.offsetHeight;
                    var left = r.right;
                    if (left + w > vw0 - 8) { left = Math.max(8, r.left - w); menu.classList.add('open-left'); }
                    var top = Math.min(r.top, Math.max(8, vh0 - h - 15));
                    menu.style.left = left + 'px'; menu.style.top = top + 'px'; menu.style.right = 'auto';
                    return;
                }
                menu.style.top = '0px';
                // open to the left when the flyout would run past the right edge (menus near the end of the bar)
                menu.classList.remove('open-left');
                var vw = window.innerWidth || document.documentElement.clientWidth;
                if (menu.getBoundingClientRect().right > vw - 8) menu.classList.add('open-left');
                var rect = menu.getBoundingClientRect();
                var vh = window.innerHeight || document.documentElement.clientHeight;
                if (rect.bottom > vh - 15) {
                    var overflow = rect.bottom - (vh - 15);
                    menu.style.top = '-' + Math.max(0, overflow) + 'px';
                }
            }

            // Desktop: hover with intent (menu-aim). A flyout stays open while the pointer heads for it - crossing the rows
            // below on the way does not close it - and closes after a short grace, so a quick diagonal move never misses it.
            el.addEventListener('mouseenter', function () { SubmenuAim.enter(el, menu, positionSubmenu); });
            el.addEventListener('mouseleave', function () { SubmenuAim.leave(el); });
            // scrolling the menu moves the row away from its flyout: close it
            if (scrollParent) scrollParent.addEventListener('scroll', function () {
                if (menu.classList.contains('show')) SubmenuAim.closeAll();
            }, { passive: true });

            // Mobile / click fallback (a click always opens it at once)
            toggle.addEventListener('click', function (e) {
                e.preventDefault();
                e.stopPropagation();
                var wasOpen = menu.classList.contains('show');
                SubmenuAim.closeAll();
                if (!wasOpen) SubmenuAim.open(el, menu, positionSubmenu);
            });
        });

        // A top menu with more than 10 entries: show the first 10 rows (dividers between them included) and scroll the rest;
        // never taller than the window below the menu bar.
        document.querySelectorAll('.emr-main-menu .dropdown-menu.emr-menu-scroll').forEach(function (ul) {
            var toggle = ul.previousElementSibling;
            if (!toggle) return;
            toggle.addEventListener('shown.bs.dropdown', function () {
                ul.style.maxHeight = '';
                var rows = Array.prototype.filter.call(ul.children, function (li) { return li.tagName === 'LI'; });
                var count = 0, height = 0;
                for (var i = 0; i < rows.length; i++) {
                    var isItem = !rows[i].querySelector('.dropdown-divider');
                    if (isItem && count === 10) break;
                    height += rows[i].getBoundingClientRect().height;
                    if (isItem) count++;
                }
                var cs = getComputedStyle(ul);
                height += parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom) + parseFloat(cs.borderTopWidth) + parseFloat(cs.borderBottomWidth);
                var room = (window.innerHeight || document.documentElement.clientHeight) - ul.getBoundingClientRect().top - 12;
                ul.style.maxHeight = Math.max(160, Math.min(height, room)) + 'px';
            });
        });

        // Close submenus when parent dropdown closes
        document.querySelectorAll('[data-bs-toggle="dropdown"]').forEach(function (btn) {
            btn.addEventListener('hidden.bs.dropdown', function () { SubmenuAim.closeAll(); });
        });
    
