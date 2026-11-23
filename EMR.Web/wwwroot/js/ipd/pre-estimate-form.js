/* IpdEstimation/PreAdmissionForm.cshtml (IPD, SQLScripts/2422+): page script, moved out of the view so it is not compiled into EMR.Web.dll. Server values come in window.IpdPage. */
(function () {
const C = window.IpdPage || {};
const base = C.base, adm = C.adm, E = Ipd.esc;
const existing = C.existing || null;
let L = null, estimateId = existing ? existing.header.EstimateId : null;
const heads = [['BED', 'Bed & Nursing'], ['ICU', 'ICU'], ['DOCTOR', 'Doctor Visits'], ['LAB', 'Laboratory'], ['RADIOLOGY', 'Radiology / Imaging'], ['PHARMACY', 'Pharmacy'], ['CONSUMABLE', 'Consumables'], ['PROCEDURE', 'Procedures'], ['OT', 'Operation Theatre'], ['SERVICE', 'Other Services'], ['PACKAGE', 'Package']];
const opt = (rows, v, t, first) => (first !== undefined ? `<option value="">${E(first)}</option>` : '') + (rows || []).map(r => `<option value="${E(r[v])}">${E(typeof t === 'function' ? t(r) : r[t])}</option>`).join('');
function addLine(l) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td><select class="form-select form-select-sm lh">${heads.map(([k, n]) => `<option value="${k}">${n}</option>`).join('')}</select></td><td><input class="form-control form-control-sm li" maxlength="250" /></td>
        <td><input type="number" min="0" step="0.5" class="form-control form-control-sm text-end lq" value="1" /></td><td><input type="number" min="0" step="0.01" class="form-control form-control-sm text-end lr" value="0" /></td>
        <td class="text-end num la"></td><td><input class="form-control form-control-sm lm" maxlength="300" /></td><td><button type="button" class="btn btn-sm btn-outline-danger"><i class="bi bi-trash"></i></button></td>`;
    if (l) { tr.querySelector('.lh').value = l.Head || 'SERVICE'; tr.querySelector('.li').value = l.ItemName || ''; tr.querySelector('.lq').value = Number(l.Qty) || 1; tr.querySelector('.lr').value = Number(l.Rate) || 0; tr.querySelector('.lm').value = l.Remarks || ''; }
    tr.querySelectorAll('.lq, .lr').forEach(i => i.addEventListener('input', sum));
    tr.querySelector('button').addEventListener('click', () => { tr.remove(); sum(); });
    document.getElementById('lines').appendChild(tr); sum();
}
function lines() { return [...document.querySelectorAll('#lines tr')].map(tr => ({ Head: tr.querySelector('.lh').value, ItemName: tr.querySelector('.li').value.trim(), Qty: Number(tr.querySelector('.lq').value) || 0, Rate: Number(tr.querySelector('.lr').value) || 0, Remarks: tr.querySelector('.lm').value.trim() })).filter(l => l.ItemName); }
function sum() {
    let t = 0; document.querySelectorAll('#lines tr').forEach(tr => { const a = (Number(tr.querySelector('.lq').value) || 0) * (Number(tr.querySelector('.lr').value) || 0); t += a; tr.querySelector('.la').textContent = Ipd.num(a); });
    document.getElementById('total').textContent = Ipd.money(t);
}
const payerCat = { CASH: /cash|self/i, CORPORATE: /corporate/i, INSURANCE: /insurance|tpa/i, SCHEME: /government|scheme/i };
PayerType.addEventListener('change', () => { const t = (L.tariffCategories || []).filter(x => payerCat[PayerType.value].test(x.PatientCategory)).sort((a, b) => (b.BedRates || 0) - (a.BedRates || 0) || a.Name.localeCompare(b.Name))[0]; if (t) TariffCategoryId.value = t.TariffCategoryId; });
btnAdd.addEventListener('click', () => addLine(null));
btnCalc.addEventListener('click', async () => {
    const q = new URLSearchParams({ tariffCategoryId: TariffCategoryId.value || 0, bedCategoryId: BedCategoryId.value, wardDays: WardDays.value || 0, icuBedCategoryId: IcuBedCategoryId.value, icuDays: IcuDays.value || 0, packageId: PackageId.value });
    try {
        const d = await Ipd.get(base + 'PreAdmissionCalc?' + q);
        document.querySelectorAll('#lines tr').forEach(tr => { if (['BED', 'ICU', 'PACKAGE'].includes(tr.querySelector('.lh').value)) tr.remove(); });
        (d.lines || []).forEach(addLine);
        calcWarn.innerHTML = (d.missing || []).length ? `<div class="alert alert-warning py-2 small">No rate for ${(d.missing || []).map(m => E(m.CategoryName)).join(', ')} in this tariff category (Master &gt; IPD &gt; Bed/Room Tariff).</div>` : '';
    } catch (e) { Ipd.error(e.message); }
});
// patient search (Patient Master, as admission)
let t;
pSearch.addEventListener('input', () => {
    clearTimeout(t); const v = pSearch.value.trim(); if (v.length < 3) { pSug.style.display = 'none'; return; }
    t = setTimeout(async () => {
        const url = /^\d+$/.test(v) ? adm + 'SearchPatientByPhone?phone=' + encodeURIComponent(v) : /^[A-Za-z]{2,}\d/.test(v) ? adm + 'SearchPatientByCode?code=' + encodeURIComponent(v) : adm + 'SearchPatientByName?name=' + encodeURIComponent(v);
        const list = await Ipd.getRaw(url) || [];
        pSug.innerHTML = list.map(p => `<button type="button" class="list-group-item list-group-item-action sug py-2 px-3" data-p='${E(JSON.stringify(p))}'><span class="fw-semibold">${E(p.fullName)}</span> <span class="badge text-bg-info text-dark">${E(p.patientCode)}</span><div class="small text-muted">${E(p.phoneNumber || '')} · ${E(p.gender || '')} ${E(p.formattedAge || '')}</div></button>`).join('')
            || '<div class="list-group-item small text-muted">No patient found: type the details for a new patient.</div>';
        pSug.style.display = 'block';
    }, 260);
});
pSug.addEventListener('click', e => {
    const b = e.target.closest('[data-p]'); if (!b) return; const p = JSON.parse(b.dataset.p);
    PatientId.value = p.patientId; PatientName.value = p.fullName; Phone.value = p.phoneNumber || ''; Gender.value = p.gender || ''; AgeText.value = p.formattedAge || '';
    pSearch.value = p.fullName + ' (' + p.patientCode + ')'; pSug.style.display = 'none';
});
document.addEventListener('click', e => { if (!pSug.contains(e.target) && e.target !== pSearch) pSug.style.display = 'none'; });
btnSave.addEventListener('click', async () => {
    const ls = lines();
    if (!PatientName.value.trim()) { Ipd.error('Enter the patient name.'); return; }
    if (!TariffCategoryId.value) { Ipd.error('Choose the tariff category.'); return; }
    if (!ls.length) { Ipd.error('Add at least one line.'); return; }
    const n = id => Number(document.getElementById(id).value) || null;
    const body = { EstimateId: estimateId, PatientId: n('PatientId'), PatientName: PatientName.value.trim(), Phone: Phone.value.trim(), AgeText: AgeText.value.trim(), Gender: Gender.value,
        PayerType: PayerType.value, TariffCategoryId: n('TariffCategoryId') || 0, BedCategoryId: n('BedCategoryId'), WardDays: n('WardDays') || 0, IcuBedCategoryId: n('IcuBedCategoryId'), IcuDays: n('IcuDays') || 0,
        PackageId: n('PackageId'), DoctorId: n('DoctorId'), ProcedureNote: ProcedureNote.value.trim(), Remarks: Remarks.value.trim(), Lines: JSON.stringify(ls) };
    btnSave.disabled = true;
    const r = await Ipd.post(base + 'SavePreAdmission', body);
    btnSave.disabled = false;
    if (!r.success) { Ipd.error(r.error); return; }
    estimateId = r.data.EstimateId; estNo.textContent = r.data.EstimateNo;
    window.open(base + 'PrintPreAdmission/' + estimateId, '_blank');
    Ipd.toast('Estimate ' + r.data.EstimateNo + ' saved');
    history.replaceState(null, '', base + 'PreAdmissionForm/' + estimateId);
});
(async () => {
    try {
        L = await Ipd.get(base + 'PreAdmissionLookups');
        TariffCategoryId.innerHTML = opt(L.tariffCategories, 'TariffCategoryId', r => r.Name + ' (' + r.PatientCategory + ') · ' + (r.BedRates ? r.BedRates + ' bed rate' + (r.BedRates > 1 ? 's' : '') : 'no bed rates'), '-- Select --');
        DoctorId.innerHTML = opt(L.doctors, 'DoctorId', 'DoctorName', '-- Any --');
        PackageId.innerHTML = opt(L.packages, 'Id', r => r.Name + ' · ' + Ipd.money(r.Amount), '-- No package --');
        BedCategoryId.innerHTML = opt(L.bedCategories, 'BedCategoryId', 'CategoryName', '-- None --');
        IcuBedCategoryId.innerHTML = opt(L.bedCategories, 'BedCategoryId', 'CategoryName', '-- None --');
        const icu = (L.bedCategories || []).find(c => /^icu$/i.test(c.CategoryName)); if (icu) IcuBedCategoryId.value = icu.BedCategoryId;
        const gen = (L.bedCategories || []).find(c => /^general$/i.test(c.CategoryName)); if (gen) BedCategoryId.value = gen.BedCategoryId;
        PayerType.dispatchEvent(new Event('change'));
        if (existing) {
            const h = existing.header, set = (k, v) => { const el = document.getElementById(k); if (el) el.value = v ?? ''; };
            ['PatientId', 'PatientName', 'Phone', 'AgeText', 'Gender', 'PayerType', 'TariffCategoryId', 'BedCategoryId', 'WardDays', 'IcuBedCategoryId', 'IcuDays', 'PackageId', 'DoctorId', 'ProcedureNote', 'Remarks'].forEach(k => set(k, h[k]));
            estNo.textContent = h.EstimateNo; (existing.lines || []).forEach(addLine);
        }
    } catch (e) { Ipd.error(e.message); }
})();
})();
