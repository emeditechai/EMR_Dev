/* IPD Phase 3 (SQLScripts/2562-2565): helpers shared by the Clinical tab, the Nursing tab and the Nursing Station. */
(function () {
    'use strict';
    const E = v => Ipd.esc(v);
    const $ = id => document.getElementById(id);

    const U = {
        E, $,
        /** A Bootstrap modal built on the fly; footer = extra buttons HTML. Returns the modal element. */
        modal(id, title, body, footer, size = 'modal-lg') {
            let m = $(id);
            if (!m) { m = document.createElement('div'); m.className = 'modal fade'; m.id = id; m.tabIndex = -1; document.body.appendChild(m); }
            m.innerHTML = `<div class="modal-dialog ${size} modal-dialog-scrollable"><div class="modal-content"><div class="modal-header"><h6 class="modal-title fw-bold">${title}</h6>
                <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button></div><div class="modal-body">${body}</div>
                <div class="modal-footer"><button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Close</button>${footer || ''}</div></div></div>`;
            bootstrap.Modal.getOrCreateInstance(m).show();
            return m;
        },
        hide(id) { bootstrap.Modal.getInstance($(id))?.hide(); },
        v(id) { const el = $(id); return el ? el.value.trim() : ''; },
        n(id) { const x = U.v(id); return x === '' ? null : Number(x); },
        chk(id) { return !!$(id)?.checked; },
        field(id, label, input, col = 'col-12 col-md-6', req = false) {
            return `<div class="${col}"><label class="form-label small fw-semibold mb-1" for="${id}">${label}${req ? ' <span class="text-danger">*</span>' : ''}</label>${input}</div>`;
        },
        text(id, val = '', attrs = '') { return `<input id="${id}" type="text" class="form-control form-control-sm" value="${E(val)}" ${attrs} />`; },
        num(id, min, max, step = 1, val = '') { return `<input id="${id}" type="number" class="form-control form-control-sm" min="${min}" max="${max}" step="${step}" value="${val}" />`; },
        area(id, val = '', rows = 2, max = 2000) { return `<textarea id="${id}" class="form-control form-control-sm" rows="${rows}" maxlength="${max}">${E(val)}</textarea>`; },
        sel(id, opts, val = '', blank = null) {
            return `<select id="${id}" class="form-select form-select-sm">${blank != null ? `<option value="">${E(blank)}</option>` : ''}${opts.map(o => {
                const [k, t] = Array.isArray(o) ? o : [o, o];
                return `<option value="${E(k)}" ${String(k) === String(val) ? 'selected' : ''}>${E(t)}</option>`;
            }).join('')}</select>`;
        },
        when(id, val) { return `<input id="${id}" type="datetime-local" class="form-control form-control-sm" value="${Ipd.local(val)}" />`; },
        /** Posts; shows the error, or a toast and returns the data row. */
        async save(url, body, okMsg) {
            const r = await Ipd.post(url, body);
            if (!r || !r.success) { Ipd.error(r?.error); return null; }
            if (okMsg) Ipd.toast(okMsg);
            return r.data || {};
        },
        /** Strike-out of a wrong entry (kept, shown struck through). */
        async strike(base, kind, id, after) {
            const reason = await Ipd.reason('Strike out this entry?', 'Why is it wrong?');
            if (!reason) return;
            if (await U.save(base + 'Strike', { kind, id, reason }, 'Struck out')) after?.();
        },
        ago(d) {
            if (!d) return '';
            const m = Math.round((Date.now() - new Date(d)) / 60000);
            if (m < 1) return 'just now';
            if (m < 60) return m + ' min ago';
            if (m < 1440) return Math.floor(m / 60) + ' h ' + (m % 60) + ' min ago';
            return Math.floor(m / 1440) + ' d ago';
        },
        /** "in 3 h 10 min" / "overdue by 2 h" */
        dueText(d) {
            if (!d) return '';
            const m = Math.round((new Date(d) - Date.now()) / 60000), a = Math.abs(m);
            const t = a < 60 ? a + ' min' : Math.floor(a / 60) + ' h' + (a % 60 ? ' ' + (a % 60) + ' min' : '');
            return m >= 0 ? 'due in ' + t : 'overdue by ' + t;
        },
        time(d) { return d ? new Date(d).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false }) : ''; },
        news2Badge(score, risk) {
            if (score == null) return '<span class="clin-news n-na" title="Not all seven NEWS2 readings recorded">NEWS2 —</span>';
            const cls = { HIGH: 'n-high', MEDIUM: 'n-med', LOW_MEDIUM: 'n-lowmed' }[risk] || 'n-low';
            const t = { HIGH: 'high', MEDIUM: 'medium', LOW_MEDIUM: 'low-medium (single red)', LOW: 'low' }[risk] || '';
            return `<span class="clin-news ${cls}" title="NEWS2 risk ${t}">NEWS2 ${score}</span>`;
        },
        news2Advice(score, risk) {
            if (score == null) return 'Record all seven readings (RR, SpO2, oxygen, BP, pulse, consciousness, temperature) for a NEWS2 score.';
            if (risk === 'HIGH') return 'High risk: inform the doctor at once (emergency response); vitals continuously / hourly.';
            if (risk === 'MEDIUM') return 'Medium risk: urgent review by the doctor; vitals hourly.';
            if (risk === 'LOW_MEDIUM') return 'A single red parameter: inform the doctor; vitals hourly.';
            return score === 0 ? 'Low risk: vitals 12-hourly.' : 'Low risk: inform the nurse in charge; vitals 4-hourly.';
        },
        riskBadge(kind, level) {
            if (!level) return '<span class="text-muted small">not assessed</span>';
            const bad = { HIGH: 1, VERY_HIGH: 1 }[level], mid = { MODERATE: 1 }[level];
            return `<span class="badge ${bad ? 'text-bg-danger' : mid ? 'text-bg-warning' : 'text-bg-success'}">${E(level.replace('_', ' ').toLowerCase())}</span>`;
        }
    };
    window.IpdClinUi = U;
})();
