/*
 * AutoRefresh - reusable "auto refresh" control for list dashboards (Lab Reporting Entry, Pathologist Dashboard).
 *
 *   AutoRefresh.init({
 *       mount:   '#arMount',                 // where the control is rendered (next to the manual refresh button)
 *       key:     'lab-reporting',            // remembers the chosen interval per page (this browser only)
 *       refresh: () => promise,              // silent reload; may resolve to the number of new rows
 *       defaultSeconds: 60,
 *       isBusy:  () => false                 // optional: return true to skip a tick (e.g. user is working)
 *   });
 *
 * A tick is skipped (and retried a few seconds later) while the browser tab is hidden, a modal is open,
 * a dropdown is open or the previous refresh is still running. Returning to the tab refreshes at once if overdue.
 */
(function (global) {
    'use strict';

    const OPTIONS = [[0, 'Off'], [30, '30 sec'], [60, '1 min'], [120, '2 min'], [300, '5 min']];
    const RETRY_MS = 5000;

    function injectStyles() {
        if (document.getElementById('arStyles')) return;
        const css = `
            .ar-ctl { display:inline-flex; align-items:center; gap:.35rem; }
            .ar-ctl .ar-btn { display:inline-flex; align-items:center; gap:.35rem; font-size:.74rem; font-weight:600; border-radius:999px;
                              padding:.2rem .65rem; border:1px solid #cbd5e1; background:#fff; color:#475569; white-space:nowrap; }
            .ar-ctl .ar-btn:hover { border-color:#94a3b8; }
            .ar-ctl.is-on .ar-btn { border-color:#86efac; background:#f0fdf4; color:#15803d; }
            .ar-ctl.is-paused .ar-btn { border-color:#fde68a; background:#fffbeb; color:#b45309; }
            .ar-ctl .ar-dot { width:7px; height:7px; border-radius:50%; background:#94a3b8; }
            .ar-ctl.is-on .ar-dot { background:#22c55e; box-shadow:0 0 0 0 rgba(34,197,94,.6); animation:arPulse 2s infinite; }
            .ar-ctl.is-paused .ar-dot { background:#f59e0b; animation:none; }
            .ar-ctl .ar-spin { animation:arSpin .8s linear infinite; display:inline-block; }
            .ar-ctl .ar-meta { font-size:.68rem; color:#64748b; white-space:nowrap; }
            .ar-ctl .ar-new { font-size:.66rem; font-weight:700; color:#fff; background:#2563eb; border-radius:999px; padding:.05rem .45rem; }
            .ar-ctl .dropdown-item.active { background:#eff6ff; color:#1d4ed8; font-weight:600; }
            tr.ar-new-row > td { animation:arNewRow 3.5s ease-out; }
            @keyframes arPulse { 0% { box-shadow:0 0 0 0 rgba(34,197,94,.55); } 70% { box-shadow:0 0 0 6px rgba(34,197,94,0); } 100% { box-shadow:0 0 0 0 rgba(34,197,94,0); } }
            @keyframes arSpin { to { transform:rotate(360deg); } }
            @keyframes arNewRow { 0%,35% { background:#fef9c3; } 100% { background:transparent; } }
            @media (max-width: 575.98px) { .ar-ctl .ar-meta { display:none; } }`;
        const style = document.createElement('style');
        style.id = 'arStyles';
        style.textContent = css;
        document.head.appendChild(style);
    }

    function readPref(key, fallback) {
        try {
            const v = localStorage.getItem('autoRefresh:' + key);
            if (v !== null && OPTIONS.some(o => String(o[0]) === v)) return parseInt(v, 10);
        } catch (e) { /* storage unavailable */ }
        return fallback;
    }
    function writePref(key, seconds) {
        try { localStorage.setItem('autoRefresh:' + key, String(seconds)); } catch (e) { /* ignore */ }
    }

    const fmtTime = d => d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    const fmtLeft = s => s >= 60 ? Math.floor(s / 60) + 'm ' + String(s % 60).padStart(2, '0') + 's' : s + 's';

    function init(opts) {
        const mount = typeof opts.mount === 'string' ? document.querySelector(opts.mount) : opts.mount;
        if (!mount || typeof opts.refresh !== 'function') return null;
        injectStyles();

        const key = opts.key || location.pathname;
        let seconds = readPref(key, opts.defaultSeconds ?? 60);
        let nextAt = 0, running = false, lastAt = null, pausedReason = '', newTimer = null;

        mount.innerHTML = `
            <div class="ar-ctl dropdown" title="Auto refresh">
                <button type="button" class="ar-btn dropdown-toggle" data-bs-toggle="dropdown" aria-expanded="false" aria-label="Auto refresh interval">
                    <span class="ar-dot"></span><i class="bi bi-arrow-repeat ar-icon"></i><span class="ar-label"></span>
                </button>
                <ul class="dropdown-menu dropdown-menu-end shadow-sm" style="min-width:11rem;">
                    <li><h6 class="dropdown-header">Auto refresh every</h6></li>
                    ${OPTIONS.map(o => `<li><button type="button" class="dropdown-item small" data-sec="${o[0]}">${o[1]}</button></li>`).join('')}
                </ul>
                <span class="ar-new d-none"></span>
                <span class="ar-meta"></span>
            </div>`;
        const ctl = mount.querySelector('.ar-ctl');
        const label = ctl.querySelector('.ar-label'), meta = ctl.querySelector('.ar-meta');
        const icon = ctl.querySelector('.ar-icon'), newBadge = ctl.querySelector('.ar-new');

        function busyReason() {
            if (document.hidden) return 'tab hidden';
            if (document.querySelector('.modal.show')) return 'window open';
            if (document.querySelector('.dropdown-menu.show:not(.ar-ctl .dropdown-menu)')) return 'menu open';
            if (typeof opts.isBusy === 'function' && opts.isBusy()) return 'busy';
            return '';
        }

        function paint() {
            ctl.classList.toggle('is-on', seconds > 0 && !pausedReason);
            ctl.classList.toggle('is-paused', seconds > 0 && !!pausedReason);
            ctl.querySelectorAll('.dropdown-item').forEach(b => b.classList.toggle('active', parseInt(b.dataset.sec, 10) === seconds));
            const opt = OPTIONS.find(o => o[0] === seconds);
            if (seconds === 0) {
                label.textContent = 'Auto: Off';
            } else if (running) {
                label.textContent = 'Refreshing…';
            } else if (pausedReason) {
                label.textContent = 'Paused';
            } else {
                label.textContent = 'Auto ' + opt[1] + ' · ' + fmtLeft(Math.max(0, Math.ceil((nextAt - Date.now()) / 1000)));
            }
            icon.classList.toggle('ar-spin', running);
            meta.textContent = lastAt ? 'Updated ' + fmtTime(lastAt) : '';
            ctl.title = seconds === 0 ? 'Auto refresh is off'
                : pausedReason ? 'Auto refresh paused (' + pausedReason + ')' : 'Auto refresh every ' + opt[1];
        }

        function schedule(ms) { nextAt = Date.now() + ms; }

        function showNew(count) {
            if (!count || count <= 0) return;
            newBadge.textContent = '+' + count + ' new';
            newBadge.classList.remove('d-none');
            clearTimeout(newTimer);
            newTimer = setTimeout(() => newBadge.classList.add('d-none'), 8000);
        }

        function run() {
            if (running) return;
            running = true; paint();
            Promise.resolve()
                .then(() => opts.refresh())
                .then(n => { lastAt = new Date(); showNew(n); })
                .catch(() => { /* silent: the next tick retries */ })
                .finally(() => { running = false; schedule(seconds * 1000); paint(); });
        }

        // one 1-second heartbeat drives the countdown and the refresh
        setInterval(() => {
            if (seconds === 0) { pausedReason = ''; paint(); return; }
            pausedReason = busyReason();
            if (!running && Date.now() >= nextAt) {
                if (pausedReason) schedule(RETRY_MS); else run();
            }
            paint();
        }, 1000);

        document.addEventListener('visibilitychange', () => {
            if (!document.hidden && seconds > 0 && Date.now() >= nextAt - 1000) run();
        });

        ctl.querySelectorAll('.dropdown-item').forEach(b => b.addEventListener('click', () => {
            seconds = parseInt(b.dataset.sec, 10);
            writePref(key, seconds);
            schedule(seconds * 1000);
            paint();
        }));

        schedule(seconds * 1000);
        paint();

        return {
            /** call after a manual reload so the countdown restarts and "Updated" is current */
            touch() { lastAt = new Date(); schedule(seconds * 1000); paint(); },
            get seconds() { return seconds; }
        };
    }

    /** Highlights rows whose id was not in the previous list; returns how many are new. */
    function markNewRows(prevIds, rows, idOf, rowSelector) {
        if (!prevIds) return 0;
        let n = 0;
        rows.forEach(r => {
            const id = idOf(r);
            if (!prevIds.has(id)) {
                n++;
                const tr = document.querySelector(rowSelector(id));
                if (tr) tr.classList.add('ar-new-row');
            }
        });
        return n;
    }

    global.AutoRefresh = { init, markNewRows };
})(window);
