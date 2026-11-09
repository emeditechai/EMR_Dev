/* IPD Dashboard: admission advice from OPD (SQLScripts/2438) - admit from it or cancel it. */
(function () {
    'use strict';
    const E = Ipd.esc, box = document.getElementById('adviceBox'); if (!box) return;
    const pill = u => u === 'EMERGENCY' ? '<span class="ipd-pill alert">Emergency</span>' : u === 'URGENT' ? '<span class="ipd-pill warn">Urgent</span>' : '<span class="ipd-pill muted">Routine</span>';
    async function load() {
        let rows = [];
        try { rows = await Ipd.get('/IpdAdvice/List?status=PENDING') || []; } catch { box.classList.add('d-none'); return; }
        box.classList.toggle('d-none', !rows.length);
        document.getElementById('adviceCount').textContent = rows.length || '';
        document.getElementById('adviceRows').innerHTML = rows.map(r => `<tr>
            <td>${pill(r.Urgency)}</td>
            <td><div class="fw-semibold">${E(r.PatientName)}</div><div class="small text-muted">${E(r.PatientCode)} · ${E(r.AgeText || '')} ${E(r.Gender || '')} · ${E(r.PhoneNumber || '')}</div></td>
            <td class="small">${E(r.DoctorName || '')}<div class="text-muted">${Ipd.dt(r.CreatedDate)}${r.OpdBillNo ? ' · ' + E(r.OpdBillNo) : ''}</div></td>
            <td class="small"><div>${E(r.Reason)}</div><div class="text-muted">${E(r.Diagnosis || '')}${r.DiagnosisCode ? ' (' + E(r.DiagnosisCode) + ')' : ''}${r.Remarks ? ' · ' + E(r.Remarks) : ''}</div></td>
            <td class="small">${E(r.DepartmentName || '—')}</td>
            <td class="small">${r.ExpectedAt ? Ipd.dt(r.ExpectedAt) : 'As soon as possible'}</td>
            <td class="text-nowrap text-end"><a class="btn btn-sm btn-success" href="/IpdAdmission/New?adviceId=${r.AdviceId}"><i class="bi bi-person-plus-fill me-1"></i>Admit</a>
                <button type="button" class="btn btn-sm btn-light border text-danger a-cancel" data-id="${r.AdviceId}" title="Cancel advice"><i class="bi bi-x-lg"></i></button></td></tr>`).join('');
    }
    document.addEventListener('click', async e => {
        const b = e.target.closest('.a-cancel'); if (!b) return;
        const reason = await Ipd.reason('Cancel this admission advice?', 'Reason (e.g. patient refused, admitted elsewhere)'); if (!reason) return;
        const r = await Ipd.post('/IpdAdvice/Cancel?id=' + b.dataset.id, { reason });
        if (!r.success) return Ipd.error(r.error);
        Ipd.toast('Advice cancelled'); load();
    });
    document.getElementById('refresh')?.addEventListener('click', load);
    load();
})();
