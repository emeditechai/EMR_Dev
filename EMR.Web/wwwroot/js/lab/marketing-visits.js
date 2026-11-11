/* LAB > Doctor Visit Log (SQLScripts/2447). An executive login sees and logs its own visits only (enforced in the procedures). */
(function () {
    'use strict';
    const P = window.MvPage, $ = id => document.getElementById(id), E = Ipd.esc;
    const PURPOSE = { INTRODUCTION: 'Introduction', FOLLOW_UP: 'Follow-up', RELATIONSHIP: 'Relationship', COLLECTION: 'Collection / dues', COMPLAINT: 'Complaint', OTHER: 'Other',
                      INTERESTED: 'Interested', NOT_AVAILABLE: 'Not available', NOT_INTERESTED: 'Not interested' };
    const iso = d => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    const modal = () => bootstrap.Modal.getOrCreateInstance($('vModal'));
    let execs = [], rows = [], execLoaded = false;

    async function load() {
        const q = new URLSearchParams({ fromDate: $('vFrom').value, toDate: $('vTo').value, executiveId: $('vExec').value, search: $('vSearch').value.trim() });
        try {
            const d = await Ipd.get(P.base + 'VisitData?' + q);
            rows = d.visits || []; execs = d.executives || [];
            if (!execLoaded) {
                execs.forEach(e => $('vExec').add(new Option(`${e.ExecutiveName} (${e.ExecutiveCode})${e.IsActive ? '' : ' · inactive'}`, e.ExecutiveId)));
                if (execs.length === 1) { $('vExec').value = execs[0].ExecutiveId; $('vExec').disabled = true; }
                execLoaded = true;
            }
            render();
        } catch (e) { $('vRows').innerHTML = `<tr><td colspan="7" class="text-center text-danger py-4">${E(e.message)}</td></tr>`; }
    }

    function render() {
        const docs = new Set(rows.map(r => r.DoctorName)).size, ex = new Set(rows.map(r => r.ExecutiveId)).size, app = rows.filter(r => r.Source === 'APP').length;
        const k = (c, l, v, s) => `<div class="col-6 col-lg-3"><div class="border rounded-3 bg-white p-2 px-3 h-100" style="border-left:4px solid ${c} !important"><div class="small text-uppercase fw-bold text-muted" style="font-size:.68rem">${l}</div><div class="fs-5 fw-bold">${v}</div><div class="small text-muted">${s}</div></div></div>`;
        $('vKpis').innerHTML = k('#2563eb', 'Visits', rows.length, 'in the period') + k('#16a34a', 'Doctors visited', docs, 'distinct') + k('#c2410c', 'Executives', ex, 'with visits') + k('#7c3aed', 'From the app', app, 'Marketing Executive App');
        $('vRows').innerHTML = rows.length ? rows.map(r => `<tr>
            <td class="text-nowrap">${Ipd.dt(r.VisitDate)}</td>
            <td><div class="fw-semibold">${E(r.ExecutiveName)}</div><small class="text-muted">${E(r.ExecutiveCode)}</small></td>
            <td>${E(r.DoctorName)}</td><td>${E(PURPOSE[r.Purpose] || r.Purpose)}</td><td class="small">${E(r.Remarks || '')}</td>
            <td>${r.Source === 'APP' ? `<span class="badge text-bg-info">App</span> <small class="text-muted">${E(r.VisitStatus || '')}</small>` : `<span class="badge text-bg-light border">Logged</span> <small class="text-muted">${E(r.CreatedByName || '')}</small>`}</td>
            <td class="text-end">${r.Source === 'LOG' && P.canDelete && r.CanDelete ? `<button type="button" class="btn btn-sm btn-outline-danger" data-id="${r.VisitId}" title="Delete"><i class="bi bi-trash"></i></button>` : ''}</td></tr>`).join('')
            : '<tr><td colspan="7" class="text-center text-muted py-4"><i class="bi bi-inbox me-1"></i>No visits in this period.</td></tr>';
    }

    async function loadDoctors() {
        const id = $('vfExec').value;
        $('vfDoc').innerHTML = '<option value="">Loading…</option>';
        try {
            const docs = await Ipd.get(P.base + 'VisitDoctors?' + new URLSearchParams({ executiveId: id }));
            $('vfDoc').innerHTML = '<option value="">-- Select doctor --</option>' + docs.map(d => `<option value="${d.DoctorId}">${d.IsTagged ? '★ ' : ''}${E(d.DoctorName)}${d.PhoneNumber ? ' · ' + E(d.PhoneNumber) : ''}</option>`).join('');
        } catch (e) { $('vfDoc').innerHTML = '<option value="">Could not load doctors</option>'; }
    }

    $('vAdd')?.addEventListener('click', () => {
        $('vForm').reset(); $('vForm').querySelectorAll('.is-invalid').forEach(x => x.classList.remove('is-invalid'));
        const active = execs.filter(e => e.IsActive);
        $('vfExec').innerHTML = (active.length > 1 ? '<option value="">-- Select --</option>' : '') + active.map(e => `<option value="${e.ExecutiveId}">${E(e.ExecutiveName)} (${E(e.ExecutiveCode)})</option>`).join('');
        if ($('vExec').value && active.some(e => String(e.ExecutiveId) === $('vExec').value)) $('vfExec').value = $('vExec').value;
        $('vExecBox').classList.toggle('d-none', active.length === 1);
        $('vfDate').value = Ipd.local(); $('vfDate').max = Ipd.local();
        $('vfRemReq').classList.add('d-none');
        loadDoctors(); modal().show();
    });
    $('vfExec').addEventListener('change', loadDoctors);
    $('vfPurpose').addEventListener('change', () => $('vfRemReq').classList.toggle('d-none', $('vfPurpose').value !== 'OTHER'));
    $('vForm').addEventListener('input', e => e.target.classList.remove('is-invalid'));
    $('vForm').addEventListener('submit', async e => {
        e.preventDefault();
        const bad = [];
        if (!$('vfExec').value) bad.push('vfExec');
        if (!$('vfDoc').value) bad.push('vfDoc');
        const dt = $('vfDate').value ? new Date($('vfDate').value) : null;
        if (!dt || isNaN(dt) || dt > new Date(Date.now() + 600000)) bad.push('vfDate');
        if (!$('vfPurpose').value) bad.push('vfPurpose');
        if ($('vfPurpose').value === 'OTHER' && !$('vfRemarks').value.trim()) bad.push('vfRemarks');
        bad.forEach(id => $(id).classList.add('is-invalid'));
        if (bad.length) { $(bad[0]).focus(); return; }
        const btn = $('vSave'); btn.disabled = true;
        try {
            const r = await Ipd.post(P.base + 'VisitSave', { executiveId: +$('vfExec').value, doctorId: +$('vfDoc').value, visitDate: $('vfDate').value,
                purpose: $('vfPurpose').value, remarks: $('vfRemarks').value.trim() || null });
            if (!r.success) return Ipd.error(r.error);
            modal().hide(); Ipd.toast('Visit logged'); load();
        } finally { btn.disabled = false; }
    });
    $('vRows').addEventListener('click', async e => {
        const b = e.target.closest('button[data-id]'); if (!b) return;
        if (!await Ipd.confirm('Delete this visit?', 'It no longer counts against the doctor-visit target.', 'Delete')) return;
        const r = await Ipd.post(P.base + 'VisitDelete?id=' + b.dataset.id, {});
        if (!r.success) return Ipd.error(r.error);
        Ipd.toast('Deleted'); load();
    });
    ['vExec'].forEach(id => $(id).addEventListener('change', load));
    $('vSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    $('vShow').addEventListener('click', load);
    const t = new Date(); $('vFrom').value = iso(new Date(t.getFullYear(), t.getMonth(), 1)); $('vTo').value = iso(t);
    load();
})();
