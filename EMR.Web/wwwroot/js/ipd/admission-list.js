/* IpdAdmission/Index.cshtml (IPD, SQLScripts/2422+): page script, moved out of the view so it is not compiled into EMR.Web.dll. Server values come in window.IpdPage. */
(function () {
const base = (window.IpdPage || {}).base, E = Ipd.esc; let page = 1, total = 0, t; const size = 25;
async function load() {
    const q = new URLSearchParams({ status: fStatus.value, payerType: fPayer.value, search: fSearch.value.trim(), fromDate: fFrom.value, toDate: fTo.value, page, pageSize: size });
    try {
        const d = await Ipd.get(base + 'ListData?' + q);
        total = (d.total && d.total[0] && d.total[0].Total) || 0;
        rows.innerHTML = (d.rows || []).map(r => `<tr style="cursor:pointer" data-id="${r.AdmissionId}">
            <td class="font-monospace fw-semibold">${E(r.IpNo)}</td><td class="text-nowrap">${Ipd.dt(r.AdmissionAt)}</td>
            <td><div class="fw-semibold">${E(r.PatientName)}</div><div class="small text-muted">${E(r.PatientCode)} · ${E(r.AgeText)} / ${E(r.Gender || '')} · ${E(r.PhoneNumber || '')}</div></td>
            <td>${E(r.WardName || '')}<div class="small fw-semibold">${E(r.BedNumber || '')}</div></td><td>${E(r.ConsultantDoctorName || '')}</td>
            <td>${E(Ipd.payer(r.PayerType))}<div class="small text-muted">${E(r.TariffCategoryName || '')}</div></td><td class="text-end">${r.DayCount}</td>
            <td class="text-end num">${r.BillNow == null ? '' : Ipd.money(r.BillNow)}</td><td class="text-end num">${Ipd.money(r.NetAdvance)}</td>
            <td class="text-end num ${r.BalanceDue > 0 && r.IsOpen ? 'money-due' : ''}">${r.Status === 'CANCELLED' ? '' : Ipd.money(r.BalanceDue)}</td><td>${Ipd.status(r.Status)}</td></tr>`).join('')
            || '<tr><td colspan="11" class="text-center text-muted py-4">No admission matches.</td></tr>';
        count.textContent = total ? `${(page - 1) * size + 1}–${Math.min(page * size, total)} of ${total}` : '';
        prev.disabled = page <= 1; next.disabled = page * size >= total;
    } catch (e) { rows.innerHTML = `<tr><td colspan="11" class="text-danger text-center py-4">${E(e.message)}</td></tr>`; }
}
rows.addEventListener('click', e => { const tr = e.target.closest('tr[data-id]'); if (tr) location.href = base + 'Patient/' + tr.dataset.id; });
[fStatus, fPayer, fFrom, fTo].forEach(el => el.addEventListener('change', () => { page = 1; load(); }));
fSearch.addEventListener('input', () => { clearTimeout(t); t = setTimeout(() => { page = 1; load(); }, 300); });
prev.addEventListener('click', () => { if (page > 1) { page--; load(); } }); next.addEventListener('click', () => { page++; load(); });
load();
})();
