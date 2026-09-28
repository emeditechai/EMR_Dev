// Server-side authorization, browser side (a courtesy only - every action is checked again on the server):
//  - elements drawn by scripts carry data-permission="PAGE:CONTROL" (comma list = any of them); those the user may
//    not use are removed as soon as they appear (emrCan comes from <emr-permission-script /> in the layout);
//  - when the server refuses a call (403 FORBIDDEN / ACCOUNT_INACTIVE from the permission
// filter), say so plainly instead of the page's generic "server error". It only observes responses; every page
// keeps handling its own result as before.
(function () {
    'use strict';
    let lastShown = 0;
    function notify(body) {
        if (!body || (body.code !== 'FORBIDDEN' && body.code !== 'ACCOUNT_INACTIVE')) return;
        if (Date.now() - lastShown < 1500) return;
        lastShown = Date.now();
        const msg = body.message || 'You do not have permission to perform this action.';
        if (window.Swal) {
            Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: msg, showConfirmButton: false, timer: 5000, timerProgressBar: true });
        } else if (window.toastr) {
            toastr.warning(msg);
        }
    }

    if (window.jQuery) {
        jQuery(document).ajaxError(function (_e, xhr) {
            if (xhr && xhr.status === 403) notify(xhr.responseJSON);
        });
    }

    if (window.fetch) {
        const originalFetch = window.fetch;
        window.fetch = function () {
            return originalFetch.apply(this, arguments).then(function (res) {
                if (res.status === 403) res.clone().json().then(notify).catch(function () { });
                return res;
            });
        };
    }

    function prune(root) {
        if (typeof window.emrCan !== 'function' || !root.querySelectorAll) return;
        const list = root.matches && root.matches('[data-permission]') ? [root] : [];
        root.querySelectorAll('[data-permission]').forEach(function (el) { list.push(el); });
        list.forEach(function (el) {
            const ok = el.getAttribute('data-permission').split(',').some(function (t) {
                const p = t.trim().split(':');
                return window.emrCan(p[0], p[1] || 'VIEW');
            });
            if (ok) return;
            if (el.getAttribute('data-permission-mode') === 'disable') {   // keep showing the state, but locked
                el.disabled = true; el.setAttribute('aria-disabled', 'true'); el.title = 'You do not have permission for this action';
                el.removeAttribute('data-permission');
            } else el.remove();
        });
    }
    function startPruning() {
        prune(document.body);
        new MutationObserver(function (records) {
            records.forEach(function (r) { r.addedNodes.forEach(function (n) { if (n.nodeType === 1) prune(n); }); });
        }).observe(document.body, { childList: true, subtree: true });
    }
    if (document.body) startPruning(); else document.addEventListener('DOMContentLoaded', startPruning);
})();
