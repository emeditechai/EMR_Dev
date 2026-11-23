/* IpdEstimation/Index.cshtml (IPD, SQLScripts/2422+): page script, moved out of the view so it is not compiled into EMR.Web.dll. Server values come in window.IpdPage. */
(function () {
const base = (window.IpdPage || {}).base, E = Ipd.esc; let all = [], t;
const tile = (l, v, s, c) => `<div class="col-6 col-lg-3"><div class="ipd-tile ${c}"><div class="lbl">${l}</div><div class="val">${v}</div><div class="sub">${s || ''}</div></div></div>`;
async function load() {
    const q = new URLSearchParams({ wardId: fWard.value, payerType: fPayer.value, search: fSearch.value.trim(), onlyAlerts: fAlert.checked });
    try {
        all = await Ipd.get(base + 'DueListData?' + q) || [];
        if (fWard.options.length === 1) [...new Map(all.map(r => [r.WardId, r.WardName])).entries()].forEach(([id, n]) => id && fWard.append(new Option(n, id)));
        const bill = all.reduce((s, r) => s + Number(r.BillNow), 0), adv = all.reduce((s, r) => s + Number(r.NetAdvance), 0), due = all.reduce((s, r) => s + Math.max(0, Number(r.BalanceDue)), 0);
        tiles.innerHTML = tile('Patients', all.length, 'admitted', 'accent') + tile('Running bills', Ipd.money(bill), 'if all discharged now', '') + tile('Advance held', Ipd.money(adv), '', 'good')
            + tile('Balance due', Ipd.money(due), all.filter(r => r.DepositAlert).length + ' deposit alert(s)', due > 0 ? 'bad' : 'good');
        rows.innerHTML = all.map(r => `<tr style="cursor:pointer" data-id="${r.AdmissionId}" class="${r.DepositAlert ? 'table-danger' : ''}">
            <td><div class="fw-semibold">${E(r.PatientName)}</div><div class="small text-muted">${E(r.PatientCode)} · ${E(r.AgeText)} / ${E(r.Gender || '')} · ${E(r.PhoneNumber || '')}</div></td>
            <td class="font-monospace small">${E(r.IpNo)}</td><td>${E(r.WardName || '')}<div class="small fw-semibold">${E(r.BedNumber || '')}</div></td>
            <td>${E(Ipd.payer(r.PayerType))}<div class="small text-muted">${E(r.PayerName || '')}</div></td><td class="text-end">${r.DayCount}</td>
            <td class="text-end num fw-semibold">${Ipd.money(r.BillNow)}${r.NoTariff ? ' <span class="ipd-pill warn" title="A bed has no rate">no rate</span>' : ''}</td>
            <td class="text-end num">${Ipd.money(r.NetAdvance)}</td><td class="text-end num ${r.BalanceDue > 0 ? 'money-due' : 'money-ok'}">${Ipd.money(r.BalanceDue)}${r.DepositAlert ? ' <i class="bi bi-bell-fill text-danger" title="Collect deposit"></i>' : ''}</td>
            <td class="text-nowrap"><a class="btn btn-sm btn-outline-secondary" href="${base}Print/${r.AdmissionId}?format=summary" target="_blank" title="Print"><i class="bi bi-printer"></i></a>
            ${r.DepositAlert ? `<a class="btn btn-sm btn-outline-danger" href="${base}Print/${r.AdmissionId}?format=deposit" target="_blank" title="Deposit request letter"><i class="bi bi-envelope-exclamation"></i></a>` : ''}</td></tr>`).join('')
            || '<tr><td colspan="9" class="text-center text-muted py-4">No admitted patient matches.</td></tr>';
        asOf.textContent = 'as of ' + new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    } catch (e) { rows.innerHTML = `<tr><td colspan="9" class="text-danger text-center py-4">${E(e.message)}</td></tr>`; }
}
rows.addEventListener('click', e => { if (e.target.closest('a')) return; const tr = e.target.closest('tr[data-id]'); if (tr) location.href = base + 'Patient/' + tr.dataset.id; });
[fWard, fPayer, fAlert].forEach(el => el.addEventListener('change', load));
fSearch.addEventListener('input', () => { clearTimeout(t); t = setTimeout(load, 300); });
refresh.addEventListener('click', load); load(); setInterval(load, 60000);
})();
