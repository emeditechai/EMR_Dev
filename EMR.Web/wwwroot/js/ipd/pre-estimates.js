/* IpdEstimation/PreAdmission.cshtml (IPD, SQLScripts/2422+): page script, moved out of the view so it is not compiled into EMR.Web.dll. Server values come in window.IpdPage. */
(function () {
const base = (window.IpdPage || {}).base, admBase = (window.IpdPage || {}).admBase, E = Ipd.esc; let t;
async function load() {
    const q = new URLSearchParams({ status: fStatus.value, search: fSearch.value.trim(), fromDate: fFrom.value, toDate: fTo.value });
    try {
        const list = await Ipd.get(base + 'PreAdmissionData?' + q) || [];
        rows.innerHTML = list.map(r => {
            const st = r.Status === 'ACTIVE' ? (r.IsExpired ? '<span class="ipd-pill warn">Expired</span>' : '<span class="ipd-pill info">Active</span>') : r.Status === 'CONVERTED' ? `<span class="ipd-pill st-ADMITTED">Admitted ${E(r.AdmissionIpNo || '')}</span>` : '<span class="ipd-pill st-CANCELLED">Cancelled</span>';
            return `<tr><td class="font-monospace fw-semibold">${E(r.EstimateNo)}</td><td>${Ipd.dt(r.EstimateDate)}</td><td><div class="fw-semibold">${E(r.PatientName)}</div><div class="small text-muted">${E(r.Phone || '')}</div></td>
            <td>${E(Ipd.payer(r.PayerType))}<div class="small text-muted">${E(r.TariffCategoryName || '')}</div></td><td class="text-end num fw-semibold">${Ipd.money(r.TotalAmount)}</td><td>${Ipd.date(r.ValidTo)}</td><td>${st}</td>
            <td class="text-nowrap"><a class="btn btn-sm btn-outline-secondary" target="_blank" href="${base}PrintPreAdmission/${r.EstimateId}" title="Print"><i class="bi bi-printer"></i></a>
            ${r.Status === 'ACTIVE' ? `<a class="btn btn-sm btn-outline-primary" href="${base}PreAdmissionForm/${r.EstimateId}" title="Edit"><i class="bi bi-pencil"></i></a>
            ${r.PatientId ? `<a class="btn btn-sm btn-success" href="${admBase}New?patientId=${r.PatientId}&estimateId=${r.EstimateId}" title="Admit with this estimate"><i class="bi bi-hospital"></i></a>` : ''}
            <button type="button" class="btn btn-sm btn-outline-danger" data-cancel="${r.EstimateId}" title="Cancel"><i class="bi bi-x-lg"></i></button>` : ''}</td></tr>`;
        }).join('') || '<tr><td colspan="8" class="text-center text-muted py-4">No estimate.</td></tr>';
    } catch (e) { rows.innerHTML = `<tr><td colspan="8" class="text-danger text-center">${E(e.message)}</td></tr>`; }
}
rows.addEventListener('click', async e => {
    const b = e.target.closest('[data-cancel]'); if (!b) return;
    if (!await Ipd.confirm('Cancel this estimate?', '', 'Cancel estimate')) return;
    const r = await Ipd.post(base + 'CancelPreAdmission?id=' + b.dataset.cancel, {});
    if (!r.success) { Ipd.error(r.error); return; } load();
});
[fStatus, fFrom, fTo].forEach(el => el.addEventListener('change', load));
fSearch.addEventListener('input', () => { clearTimeout(t); t = setTimeout(load, 300); });
load();
})();
