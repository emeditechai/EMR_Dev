/* IPD > IPD Bills (SQLScripts/2434). */
(function () {
    'use strict';
    const P = window.IpdPage, $ = id => document.getElementById(id);
    const d = new Date(), iso = x => x.toISOString().slice(0, 10);
    $('fTo').value = iso(d); $('fFrom').value = iso(new Date(d.getFullYear(), d.getMonth(), d.getDate() - 30));
    const kpi = (lbl, val, cls) => `<div class="ipdx-kpi ${cls || ''}"><small>${lbl}</small><b class="num">${val}</b></div>`;
    async function load() {
        $('rows').innerHTML = '<tr><td colspan="9" class="text-muted small">Loading…</td></tr>';
        try {
            const q = new URLSearchParams({ fromDate: $('fFrom').value, toDate: $('fTo').value, status: $('fStatus').value, search: $('fSearch').value.trim() });
            const rows = await Ipd.get(P.base + 'ListData?' + q) || [];
            const fin = rows.filter(r => r.Status === 'FINAL');
            const sum = (a, k) => a.reduce((s, r) => s + (Number(r[k]) || 0), 0);
            $('kpis').innerHTML = kpi('Final bills', fin.length) + kpi('Billed', Ipd.money(sum(fin, 'Net')), 'accent') +
                kpi('Balance due', Ipd.money(sum(fin, 'BalanceDue')), sum(fin, 'BalanceDue') > 0 ? 'bad' : 'good') + kpi('Refund due', Ipd.money(sum(fin, 'RefundDue')));
            $('rows').innerHTML = rows.length ? rows.map(r => `<tr>
                <td><div class="fw-semibold font-monospace">${Ipd.esc(r.BillNo)}</div><div class="small text-muted">${Ipd.dt(r.BillAt)}</div></td>
                <td><div class="fw-semibold">${Ipd.esc(r.PatientName)}</div><div class="small text-muted">${Ipd.esc(r.PatientCode)} · ${Ipd.esc(r.PhoneNumber || '')}</div></td>
                <td><a href="${P.adm}Patient/${r.AdmissionId}?tab=billing">${Ipd.esc(r.IpNo)}</a><div class="small text-muted">${Ipd.payer(r.PayerType)}</div></td>
                <td>${Ipd.esc(r.ConsultantDoctorName || '')}</td>
                <td class="text-end fw-semibold">${Ipd.money(r.Net)}</td><td class="text-end">${Ipd.money(r.AdvanceAdjusted)}</td>
                <td class="text-end">${r.RefundDue > 0 ? `<span class="text-primary">Refund ${Ipd.money(r.RefundDue)}</span>` : r.BalanceDue > 0 ? `<span class="text-danger fw-semibold">${Ipd.money(r.BalanceDue)}</span>` : '<span class="text-success">Paid</span>'}</td>
                <td>${r.Status === 'FINAL' ? '<span class="ipd-pill st-BILL_FINAL">Final</span>' : `<span class="ipd-pill st-CANCELLED" title="${Ipd.esc(r.CancelReason || '')}">Cancelled</span>`}</td>
                <td class="text-nowrap"><a class="btn btn-sm btn-light border" target="_blank" href="${P.base}PrintBill/${r.BillId}" title="Print summary"><i class="bi bi-printer"></i></a>
                    <a class="btn btn-sm btn-light border" target="_blank" href="${P.base}PrintBill/${r.BillId}?format=detail" title="Print detailed"><i class="bi bi-list-ul"></i></a></td></tr>`).join('')
                : '<tr><td colspan="9" class="text-muted small">No bills in this period.</td></tr>';
        } catch (e) { $('rows').innerHTML = `<tr><td colspan="9" class="text-danger small">${Ipd.esc(e.message)}</td></tr>`; }
    }
    $('fLoad').addEventListener('click', load);
    $('fSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    load();
})();
