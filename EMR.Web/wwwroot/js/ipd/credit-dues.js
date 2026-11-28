/* IPD > Credit Dues (SQLScripts/2571): discharged patients with a balance on the final bill. Collection is on the patient's
   Billing tab (the link comes from the server, encrypted). */
(function () {
    'use strict';
    const P = window.IpdPage, $ = id => document.getElementById(id), E = v => Ipd.esc(v);
    const kpi = (lbl, val, cls) => `<div class="ipdx-kpi ${cls || ''}"><small>${lbl}</small><b class="num">${val}</b></div>`;
    function why(r) {
        const w = [];
        if (r.IsCreditDischarge) w.push(`Credit discharge${r.CreditReason ? ': ' + E(r.CreditReason) : ''}`);
        if (Number(r.TpaMovedToPatient) > 0) w.push('TPA disallowed ' + Ipd.money(r.TpaMovedToPatient));
        if (Number(r.SuppNet) > 0) w.push('Supplementary bill ' + Ipd.money(r.SuppNet));
        if (Number(r.CreditNet) > 0) w.push('Credit notes ' + Ipd.money(r.CreditNet));
        return w.join('<br>') || '—';
    }
    async function load() {
        $('rows').innerHTML = '<tr><td colspan="8" class="text-muted small">Loading…</td></tr>';
        try {
            const list = await Ipd.get(P.base + 'CreditDuesData?' + new URLSearchParams({ search: $('fSearch').value.trim() })) || [];
            const total = list.reduce((s, x) => s + (Number(x.row.BalanceDue) || 0), 0);
            const old = list.filter(x => x.row.DaysSinceDischarge > 30).length;
            $('kpis').innerHTML = kpi('Patients', list.length) + kpi('Total due', Ipd.money(total), total > 0 ? 'bad' : 'good') + kpi('Older than 30 days', old, old ? 'bad' : '');
            $('rows').innerHTML = list.length ? list.map(({ row: r, open }) => `<tr>
                <td><div class="fw-semibold">${E(r.PatientName)}</div><div class="small text-muted">${E(r.PatientCode)} · ${E(r.PhoneNumber || '')}</div></td>
                <td><div class="font-monospace">${E(r.IpNo)}</div><div class="small text-muted">${E(r.BillNo)} · ${Ipd.payer(r.PayerType)}</div></td>
                <td>${Ipd.dt(r.DischargeAt)}<div class="small text-muted">${E(r.ConsultantName || '')}</div></td>
                <td class="small">${why(r)}</td>
                <td class="text-end fw-bold text-danger">${Ipd.money(r.BalanceDue)}</td>
                <td class="text-end ${r.DaysSinceDischarge > 30 ? 'text-danger fw-semibold' : ''}">${r.DaysSinceDischarge}</td>
                <td>${r.LastPaymentAt ? Ipd.dt(r.LastPaymentAt) : '<span class="text-muted">—</span>'}</td>
                <td><a class="btn btn-sm btn-success" href="${E(open)}"><i class="bi bi-cash-coin me-1"></i>Collect</a></td></tr>`).join('')
                : '<tr><td colspan="8" class="text-center text-muted py-4">No credit dues.</td></tr>';
        } catch (e) { $('rows').innerHTML = `<tr><td colspan="8" class="text-danger">${E(e.message)}</td></tr>`; }
    }
    $('fLoad').addEventListener('click', load);
    $('fSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    load();
})();
