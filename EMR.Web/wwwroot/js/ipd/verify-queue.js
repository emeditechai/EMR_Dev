/* IPD > Medicine Verification (SQLScripts/2573): the pharmacist verifies or queries running medicine orders. The workspace link
   comes from the server, encrypted. */
(function () {
    'use strict';
    const P = window.IpdPage, $ = id => document.getElementById(id), E = v => Ipd.esc(v);
    const PRI = { STAT: 'bg-danger', URGENT: 'bg-warning text-dark', ROUTINE: 'bg-light text-dark border' };
    async function act(orderId, action) {
        let note = null;
        if (action === 'QUERY') { note = await Ipd.reason('Query to the doctor', 'What should the doctor check (dose, route, interaction, allergy...)?'); if (note == null) return; }
        const r = await Ipd.post(P.base + 'QueueVerify?orderId=' + orderId, { action, note });
        if (r.success) { Ipd.toast(action === 'VERIFY' ? 'Order verified' : 'Query sent to the doctor'); load(); } else Ipd.error(r.error);
    }
    async function load() {
        $('rows').innerHTML = '<tr><td colspan="7" class="text-muted small">Loading…</td></tr>';
        try {
            const list = await Ipd.get(P.base + 'VerifyQueueData') || [];
            $('rows').innerHTML = list.length ? list.map(({ row: r, open }) => `<tr>
                <td><div class="fw-semibold">${E(r.PatientName)}</div><div class="small text-muted"><a href="${E(open)}">${E(r.IpNo)}</a> · ${E(r.BedNumber || '')} ${E(r.WardName || '')}</div>
                    <div class="small ${r.KnownAllergies ? 'text-danger' : 'text-muted'}">Allergies: ${E(r.KnownAllergies || 'not recorded')}</div></td>
                <td><div class="fw-semibold">${E(r.DrugName)}${r.IsHighAlert ? ' <span class="badge bg-danger">High alert</span>' : ''}</div>
                    <span class="badge ${PRI[r.Priority] || ''}">${E(r.Priority)}</span> <span class="small text-muted">${E(r.Source)}</span></td>
                <td>${E(r.Dose)} · ${E(r.Route)} · ${E(r.FrequencyCode)}<div class="small text-muted">from ${Ipd.dt(r.StartAt)}${r.EndAt ? ' to ' + Ipd.dt(r.EndAt) : ''}</div></td>
                <td>${Ipd.dt(r.OrderedAt)}<div class="small text-muted">Dr ${E(r.DoctorName || '')}</div></td>
                <td class="small">${r.Alert ? `<span class="text-danger"><i class="bi bi-exclamation-triangle-fill me-1"></i>${E(r.Alert)}</span>` : ''}
                    ${r.AllergyOverride ? `<div class="text-muted">Allergy reason: ${E(r.AllergyOverride)}</div>` : ''}${r.InteractionOverride ? `<div class="text-muted">Interaction reason: ${E(r.InteractionOverride)}</div>` : ''}</td>
                <td>${r.VerifyStatus === 'QUERY' ? `<span class="badge bg-warning text-dark">Query</span><div class="small">${E(r.VerifyNote || '')}</div>` : '<span class="badge bg-secondary">To verify</span>'}</td>
                <td class="text-nowrap">${P.canVerify ? `<button type="button" class="btn btn-sm btn-success" data-v="${r.OrderId}"><i class="bi bi-check2 me-1"></i>Verify</button>
                    <button type="button" class="btn btn-sm btn-light border" data-q="${r.OrderId}">Query</button>` : ''}</td></tr>`).join('')
                : '<tr><td colspan="7" class="text-center text-muted py-4">Every running medicine order is verified.</td></tr>';
        } catch (e) { $('rows').innerHTML = `<tr><td colspan="7" class="text-danger">${E(e.message)}</td></tr>`; }
    }
    $('rows').addEventListener('click', e => {
        const v = e.target.closest('[data-v]'), q = e.target.closest('[data-q]');
        if (v) act(v.dataset.v, 'VERIFY'); else if (q) act(q.dataset.q, 'QUERY');
    });
    $('fLoad').addEventListener('click', load);
    load();
})();
