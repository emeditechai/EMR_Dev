/* IPD > Doctor Visit Charges (SQLScripts/2434). Doctors of IPD-type departments only. */
(function () {
    'use strict';
    const P = window.IpdPage, $ = id => document.getElementById(id);
    let L = { doctors: [], tariffCategories: [] }, rows = [];
    const opt = (v, t) => `<option value="${Ipd.esc(v)}">${Ipd.esc(t)}</option>`;
    const iso = v => v ? String(v).slice(0, 10) : '';
    const modal = () => bootstrap.Modal.getOrCreateInstance($('feeModal'));

    async function lookups() {
        L = await Ipd.get(P.base + 'Lookups');
        const docs = (L.doctors || []).map(d => opt(d.Id, d.Name + (d.Departments ? ' · ' + d.Departments : ''))).join('');
        $('fDoctor').innerHTML = '<option value="">All IPD doctors</option>' + docs;
        $('mDoctor').innerHTML = '<option value="">Choose…</option>' + docs;
    }
    async function load() {
        $('rows').innerHTML = '<tr><td colspan="7" class="text-muted small">Loading…</td></tr>';
        try {
            const q = new URLSearchParams({ doctorId: $('fDoctor').value, search: $('fSearch').value.trim(), includeInactive: $('fInactive').checked });
            rows = await Ipd.get(P.base + 'ListData?' + q) || [];
            const withFee = new Set(rows.filter(r => r.IsCurrent).map(r => r.DoctorId));
            const missing = (L.doctors || []).filter(d => !withFee.has(d.Id)).map(d => d.Name);
            $('noFee').innerHTML = missing.length ? `<i class="bi bi-exclamation-triangle text-warning me-1"></i>No current visit charge (cannot be charged for visits): ${missing.map(Ipd.esc).join(', ')}` : '';
            $('rows').innerHTML = rows.length ? rows.map(r => `<tr class="${r.IsActive ? '' : 'text-muted'}">
                <td class="fw-semibold">${Ipd.esc(r.DoctorName)}</td>
                <td class="text-end fw-semibold">${Ipd.money(r.Rate)}</td>
                <td class="small">${Ipd.date(r.EffectiveFrom)} → ${r.EffectiveTo ? Ipd.date(r.EffectiveTo) : 'open'}</td>
                <td class="small text-muted">${Ipd.esc(r.Remarks || '')}</td>
                <td>${!r.IsActive ? '<span class="ipd-pill st-CANCELLED">Removed</span>' : r.IsCurrent ? '<span class="ipd-pill st-ADMITTED">Current</span>' : '<span class="ipd-pill muted">Not in force today</span>'}</td>
                <td class="small">${Ipd.esc(r.ModifiedByName || '')}<div class="text-muted">${Ipd.dt(r.ModifiedAt)}</div></td>
                <td class="text-nowrap">${r.IsActive ? `<button type="button" class="btn btn-sm btn-light border" data-edit="${r.FeeId}" title="Edit"><i class="bi bi-pencil"></i></button>
                    <button type="button" class="btn btn-sm btn-light border text-danger" data-del="${r.FeeId}" title="Remove"><i class="bi bi-trash"></i></button>` : ''}</td></tr>`).join('')
                : '<tr><td colspan="7" class="text-muted small">No visit charges yet. Use “Add charge”.</td></tr>';
        } catch (e) { $('rows').innerHTML = `<tr><td colspan="7" class="text-danger small">${Ipd.esc(e.message)}</td></tr>`; }
    }
    function open(r) {
        $('mTitle').textContent = r ? 'Edit visit charge' : 'Add visit charge';
        $('mId').value = r ? r.FeeId : '';
        $('mDoctor').value = r ? r.DoctorId : ($('fDoctor').value || '');
        $('mRate').value = r ? r.Rate : '';
        $('mFrom').value = r ? iso(r.EffectiveFrom) : new Date().toISOString().slice(0, 10);
        $('mTo').value = r ? iso(r.EffectiveTo) : '';
        $('mRemarks').value = r ? r.Remarks || '' : '';
        modal().show();
    }
    $('btnNew').addEventListener('click', () => open(null));
    $('rows').addEventListener('click', async e => {
        const ed = e.target.closest('[data-edit]'), del = e.target.closest('[data-del]');
        if (ed) open(rows.find(r => String(r.FeeId) === ed.dataset.edit));
        if (del) {
            if (!await Ipd.confirm('Remove this visit charge?', 'Visits already charged keep their amount.', 'Remove')) return;
            const r = await Ipd.post(P.base + 'Remove?id=' + del.dataset.del, {});
            if (!r.success) return Ipd.error(r.error);
            Ipd.toast('Removed'); load();
        }
    });
    $('mSave').addEventListener('click', async () => {
        const body = {
            feeId: $('mId').value ? Number($('mId').value) : null, doctorId: Number($('mDoctor').value) || 0, visitType: 'ROUTINE', tariffCategoryId: null, rate: Number($('mRate').value) || 0,
            effectiveFrom: $('mFrom').value, effectiveTo: $('mTo').value || null, remarks: $('mRemarks').value.trim() || null
        };
        if (!body.doctorId) return Ipd.error('Choose the doctor.');
        if (body.rate <= 0) return Ipd.error('Enter the charge per visit.');
        if (!body.effectiveFrom) return Ipd.error('Enter the effective-from date.');
        const b = $('mSave'); b.disabled = true;
        try {
            const r = await Ipd.post(P.base + 'Save', body);
            if (!r.success) return Ipd.error(r.error);
            modal().hide(); Ipd.toast('Saved'); load();
        } finally { b.disabled = false; }
    });
    $('fLoad').addEventListener('click', load);
    $('fDoctor').addEventListener('change', load);
    $('fInactive').addEventListener('change', load);
    $('fSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    lookups().then(load).catch(e => Ipd.error(e.message));
})();
