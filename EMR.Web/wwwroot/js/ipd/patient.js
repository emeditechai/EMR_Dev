/* IpdAdmission/Patient.cshtml (IPD, SQLScripts/2422+): page script, moved out of the view so it is not compiled into EMR.Web.dll. Server values come in window.IpdPage. */
(function () {
    const C = window.IpdPage || {};
    const id = C.id, base = C.base, estBase = C.estBase, E = Ipd.esc, $ = window.jQuery;
    const reloadTab = tab => { window.location.href = base + 'Patient/' + id + '?tab=' + tab; };
    let L = null;
    async function lookups() { if (!L) L = await Ipd.get(base + 'PatientLookups'); return L; }
    document.querySelectorAll('.ipd-tabs [data-tab]').forEach(b => b.addEventListener('shown.bs.tab', () => history.replaceState(null, '', base + 'Patient/' + id + '?tab=' + b.dataset.tab)));
    const opt = (rows, val, text, first) => (first !== undefined ? `<option value="">${E(first)}</option>` : '') + (rows || []).map(r => `<option value="${E(r[val])}">${E(typeof text === 'function' ? text(r) : r[text])}</option>`).join('');

    // ── bed days (live) ──
    (async () => {
        const box = document.getElementById('bedDays');
        try {
            const lines = await Ipd.get(estBase + 'LinesData?id=' + id);
            const byDay = {};
            (lines || []).filter(l => l.Head === 'BED' || l.Head === 'ICU').forEach(l => { const k = l.DayNo; (byDay[k] = byDay[k] || { day: k, at: l.ChargeAt, detail: l.Detail, items: [], net: 0, notariff: l.NoTariff }); byDay[k].items.push(l.ItemName + ' ' + Ipd.money(l.Gross)); byDay[k].net += Number(l.Net) || 0; });
            const rows = Object.values(byDay);
            box.className = 'p-0';
            box.innerHTML = rows.length ? `<table class="table ipd-table mb-0"><thead><tr><th>Day</th><th>Date</th><th>Bed</th><th>Components</th><th class="text-end">Amount</th></tr></thead><tbody>${rows.map(r =>
                `<tr class="${r.notariff ? 'table-warning' : ''}"><td>${r.day}</td><td>${Ipd.date(r.at)}</td><td>${E((r.detail || '').replace(/^Day \d+ · /, ''))}</td><td class="small">${E(r.items.join(' · '))}</td><td class="text-end num">${Ipd.money(r.net)}</td></tr>`).join('')}</tbody></table>`
                : '<div class="p-3 small text-muted">No bed day yet.</div>';
        } catch (e) { box.textContent = e.message; }
    })();

    // ── advance ──
    function advRow() {
        const modes = (L.paymentModes || []).map(m => `<option value="${E(m.MethodCode)}">${E(m.MethodName)}</option>`).join('');
        const d = document.createElement('div'); d.className = 'row g-2 mb-2 adv-row align-items-end';
        d.innerHTML = `<div class="col-4"><label class="form-label small">Mode</label><select class="form-select pm">${modes}</select></div><div class="col-3"><label class="form-label small">Amount (₹)</label><input type="number" min="0" step="0.01" class="form-control pa" /></div>
            <div class="col-4"><label class="form-label small">Reference</label><input class="form-control pr" maxlength="100" /></div><div class="col-1"><button type="button" class="btn btn-outline-danger w-100 pdel"><i class="bi bi-trash"></i></button></div>`;
        document.getElementById('advRows').appendChild(d);
        d.querySelector('.pa').addEventListener('input', advTotal);
        d.querySelector('.pdel').addEventListener('click', () => { if (document.querySelectorAll('.adv-row').length > 1) d.remove(); advTotal(); });
    }
    const advPays = () => [...document.querySelectorAll('.adv-row')].map(r => ({ Method: r.querySelector('.pm').value, Amount: Number(r.querySelector('.pa').value) || 0, Ref: r.querySelector('.pr').value.trim() })).filter(p => p.Amount > 0);
    function advTotal() { document.getElementById('advTotal').textContent = Ipd.money(advPays().reduce((s, p) => s + p.Amount, 0)); }
    document.getElementById('advanceModal')?.addEventListener('show.bs.modal', async () => { await lookups(); if (!document.querySelector('.adv-row')) advRow(); });
    document.getElementById('btnAdvRow')?.addEventListener('click', advRow);
    document.getElementById('btnAdvSave')?.addEventListener('click', async e => {
        const pays = advPays(); if (!pays.length) { Ipd.error('Enter the amount.'); return; }
        e.target.disabled = true;
        const r = await Ipd.post(base + 'AddAdvance?id=' + id, { Payments: JSON.stringify(pays), Remarks: document.getElementById('advRemarks').value });
        e.target.disabled = false;
        if (!r.success) { Ipd.error(r.error); return; }
        window.open(base + 'PrintReceipt/' + r.data.AdvanceId, '_blank');
        reloadTab('advance');
    });

    // ── refund ──
    document.getElementById('refundModal')?.addEventListener('show.bs.modal', async () => {
        await lookups();
        document.getElementById('refMethod').innerHTML = opt((L.paymentModes || []).filter(m => !/WALLET|POINTS/.test(m.MethodCode)), 'MethodCode', 'MethodName');
    });
    document.getElementById('btnRefSave')?.addEventListener('click', async e => {
        const amount = Number(document.getElementById('refAmount').value) || 0, reason = document.getElementById('refReason').value.trim();
        if (amount <= 0) { Ipd.error('Enter the refund amount.'); return; }
        if (!reason) { Ipd.error('Enter the reason for the refund.'); return; }
        if (!await Ipd.confirm('Refund ' + Ipd.money(amount) + '?', 'The refund voucher is printed next.', 'Refund')) return;
        e.target.disabled = true;
        const r = await Ipd.post(base + 'RefundAdvance?id=' + id, { Amount: amount, Method: document.getElementById('refMethod').value, RefNo: document.getElementById('refRef').value, Reason: reason });
        e.target.disabled = false;
        if (!r.success) { Ipd.error(r.error); return; }
        window.open(base + 'PrintReceipt/' + r.data.AdvanceId, '_blank');
        reloadTab('advance');
    });

    // ── consent ──
    let cnSig, cnWSig;
    document.getElementById('consentModal')?.addEventListener('shown.bs.modal', async () => {
        await lookups();
        const sel = document.getElementById('cnId');
        if (!sel.options.length) { sel.innerHTML = opt(L.consents, 'Id', r => r.ConsentType + ' (' + r.Language + ')', '-- Select --'); }
        cnSig = cnSig || Ipd.signaturePad(document.getElementById('cnSig')); cnWSig = cnWSig || Ipd.signaturePad(document.getElementById('cnWSig'));
        cnSig.fit(); cnWSig.fit();
    });
    document.getElementById('cnClear1')?.addEventListener('click', () => cnSig?.clear());
    document.getElementById('cnClear2')?.addEventListener('click', () => cnWSig?.clear());
    document.getElementById('cnId')?.addEventListener('change', async e => {
        const box = document.getElementById('cnPreview');
        if (!e.target.value) { box.textContent = 'Choose a consent form to read it.'; return; }
        try {
            const c = await Ipd.get(base + 'PatientConsentPreview?consentId=' + e.target.value);
            const map = { PatientName: C.patientName, UHID: C.uhid, IPDNo: C.ipNo, Age: C.age, Gender: C.gender,
                          DoctorName: C.doctor, DepartmentName: C.department,
                          HospitalName: c.HospitalName || '', OPDNo: C.opdNo, Date: Ipd.date(new Date()), Time: new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' }),
                          Relationship: document.getElementById('cnRel').value, WitnessName: document.getElementById('cnWit').value, ProcedureName: '' };
            box.innerHTML = String(c.ContentHtml || '').replace(/\{\{(\w+)\}\}/g, (m, k) => k in map ? E(map[k]) : m);
            box.classList.remove('text-muted');
        } catch (err) { box.textContent = err.message; }
    });
    document.getElementById('btnCnSave')?.addEventListener('click', async e => {
        const fd = new FormData();
        fd.append('consentId', document.getElementById('cnId').value);
        fd.append('signedByName', document.getElementById('cnBy').value); fd.append('signedByRelation', document.getElementById('cnRel').value);
        fd.append('witnessName', document.getElementById('cnWit').value);
        fd.append('signature', cnSig?.dataUrl() || ''); fd.append('witnessSignature', cnWSig?.dataUrl() || '');
        if (!document.getElementById('cnId').value) { Ipd.error('Choose the consent form.'); return; }
        e.target.disabled = true;
        const r = await Ipd.postForm(base + 'SaveConsent?id=' + id, fd);
        e.target.disabled = false;
        if (!r.success) { Ipd.error(r.error); return; }
        window.open(base + 'PrintConsent/' + r.data.AdmissionConsentId, '_blank');
        reloadTab('documents');
    });

    // ── documents ──
    document.getElementById('btnDocSave')?.addEventListener('click', async e => {
        const f = document.getElementById('docFile').files[0]; if (!f) { Ipd.error('Choose the file.'); return; }
        const fd = new FormData(); fd.append('file', f); fd.append('docType', document.getElementById('docType').value);
        fd.append('title', document.getElementById('docTitle').value); fd.append('remarks', document.getElementById('docRemarks').value);
        e.target.disabled = true;
        const r = await Ipd.postForm(base + 'UploadDocument?id=' + id, fd);
        e.target.disabled = false;
        if (!r.success) { Ipd.error(r.error); return; }
        reloadTab('documents');
    });
    document.querySelectorAll('.btn-doc-del').forEach(b => b.addEventListener('click', async () => {
        if (!await Ipd.confirm('Remove this document?', 'It stays in the audit trail.', 'Remove')) return;
        const r = await Ipd.post(base + 'RemoveDocument?documentId=' + b.dataset.id, {});
        if (!r.success) { Ipd.error(r.error); return; }
        reloadTab('documents');
    }));

    // ── transfer bed / ICU shift (shared dialog, js/ipd/transfer.js) ──
document.querySelectorAll('.btn-transfer').forEach(b => b.addEventListener('click', () =>
    Ipd.transferDialog({ admissionId: id, who: (C.patientName || '') + ' (' + (C.bedLabel || '') + ')', transferUrl: C.bedsBase + 'Transfer', bedsUrl: C.bedsBase + 'TransferBeds', onDone: () => reloadTab('bed') })));

// ── cancel ──
document.getElementById('btnCancelAdm')?.addEventListener('click', async () => {
    const held = Number(C.netAdvance) || 0;
    let refundMethod = null, refundRef = null;
    if (held > 0) {
        if (!C.canRefund) { Ipd.error('An advance of ' + Ipd.money(held) + ' is held. A user with the Refund permission must cancel this admission.'); return; }
        await lookups();
        const modes = {}; (L.paymentModes || []).filter(m => !/WALLET|POINTS/.test(m.MethodCode)).forEach(m => { modes[m.MethodCode] = m.MethodName; });
        const r = await Swal.fire({ title: 'Refund the advance', html: 'The advance of <b>' + Ipd.money(held) + '</b> is paid back when the admission is cancelled.',
            input: 'select', inputOptions: modes, inputValue: 'CASH', showCancelButton: true, confirmButtonText: 'Continue' });
        if (!r.isConfirmed) return;
        refundMethod = r.value;
        if (refundMethod !== 'CASH') {
            const rr = await Swal.fire({ title: 'Refund reference', input: 'text', inputLabel: 'UPI / NEFT / cheque reference (optional)', showCancelButton: true });
            if (!rr.isConfirmed) return; refundRef = rr.value || null;
        }
    }
    const reason = await Ipd.reason('Cancel this admission?', 'Reason (the bed is freed' + (held > 0 ? ' and the advance refunded' : '') + ')');
    if (!reason) return;
    const r = await Ipd.post(base + 'Cancel?id=' + id, { Reason: reason, RefundMethod: refundMethod, RefundRefNo: refundRef });
    if (!r.success) { Ipd.error(r.error); return; }
    if (r.data && r.data.RefundAdvanceId) window.open(base + 'PrintReceipt/' + r.data.RefundAdvanceId, '_blank');
    reloadTab('overview');
});

// ── edit admission ──
    const H = C.h || {};
    const P = C.payers || [];
    const A = C.attendants || [];
    const M = C.mlc || null;
    function eAtt(a, primary) {
        const d = document.createElement('div'); d.className = 'row g-2 mb-2 e-att';
        d.innerHTML = `<div class="col-3"><input class="form-control form-control-sm an" placeholder="Name" maxlength="150" value="${E(a?.Name)}" /></div><div class="col-2"><input class="form-control form-control-sm ar" placeholder="Relation" maxlength="50" value="${E(a?.Relation)}" /></div>
            <div class="col-2"><input class="form-control form-control-sm ap" placeholder="Mobile" maxlength="15" value="${E(a?.Phone)}" /></div><div class="col-2"><select class="form-select form-select-sm ait">${opt(L.idTypes, 'Id', 'Name', 'ID type')}</select></div>
            <div class="col-2"><input class="form-control form-control-sm ain" placeholder="ID no." maxlength="60" value="${E(a?.IdNumber)}" /></div><div class="col-1"><button type="button" class="btn btn-sm btn-outline-danger w-100"><i class="bi bi-trash"></i></button></div>`;
        d.querySelector('.ait').value = a?.IdTypeId || ''; d.dataset.primary = primary ? '1' : '0';
        d.querySelector('button').addEventListener('click', () => d.remove());
        document.getElementById('eAtts').appendChild(d);
    }
    function ePayerUi() { const p = document.getElementById('ePayer').value; document.querySelectorAll('.e-pf').forEach(el => el.classList.toggle('d-none', !el.classList.contains('e-' + p))); }
    document.getElementById('btnEdit')?.addEventListener('click', async () => {
        await lookups();
        const doc = r => r.DoctorName + (r.SpecialityName ? ' · ' + r.SpecialityName : '');
        document.getElementById('eAdm').innerHTML = opt((L.doctors || []).filter(r => r.IsIpd || r.DoctorId === H.AdmittingDoctorId), 'DoctorId', r => r.DoctorName + (r.IpdDeptNames ? ' · ' + r.IpdDeptNames : ''), '-- Select --');
        document.getElementById('eCon').innerHTML = opt((L.doctors || []).filter(r => r.IsIpd || r.DoctorId === H.ConsultantDoctorId), 'DoctorId', r => r.DoctorName + (r.IpdDeptNames ? ' · ' + r.IpdDeptNames : ''), '-- Select --');
        document.getElementById('eDept').innerHTML = opt(L.departments, 'DeptId', 'DeptName', '-- Select --');
        document.getElementById('eRef').innerHTML = opt(L.referralDoctors, 'DoctorId', r => r.DoctorName + (r.IsReferralDoctor ? ' (referral)' : ''), '-- None --');
        document.getElementById('ePkg').innerHTML = opt(L.packages, 'Id', r => r.Name + ' · ' + Ipd.money(r.Amount), '-- No package --');
        document.getElementById('eTariff').innerHTML = opt(L.tariffCategories, 'TariffCategoryId', r => r.Name + ' (' + r.PatientCategory + ')');
        document.getElementById('eIns').innerHTML = opt(L.insurances, 'Id', 'Name', '-- Select --');
        document.getElementById('eCorp').innerHTML = opt(L.corporates, 'Id', 'Name', '-- Select --');
        document.getElementById('eSch').innerHTML = opt(L.schemes, 'Id', 'Name', '-- Select --');
        const set = (k, val) => { document.getElementById(k).value = val ?? ''; };
        set('eType', H.AdmissionType); set('eSource', H.AdmissionSource); set('eAdm', H.AdmittingDoctorId); set('eCon', H.ConsultantDoctorId); set('eDept', H.DepartmentId);
        set('eRef', H.ReferralDoctorId); set('eExp', H.ExpectedDischargeAt ? Ipd.local(H.ExpectedDischargeAt) : ''); set('ePkg', H.PackageId); set('eDx', H.ProvisionalDiagnosis);
        set('eIcd', H.DiagnosisCode); set('eReason', H.ReasonForAdmission); set('ePayer', H.PayerType); set('eTariff', H.TariffCategoryId); set('eRemarks', H.Remarks);
        const p = P[0] || {};
        set('eIns', p.InsuranceTpaId); set('eCorp', p.CorporateId); set('eSch', p.SchemeId); set('ePol', p.PolicyNo); set('eMem', p.MemberId); set('eEmp', p.EmployeeId);
        set('eHolder', p.CardHolderName); set('eHolderRel', p.RelationToHolder); set('eValid', p.PolicyValidTo ? String(p.PolicyValidTo).substring(0, 10) : '');
        document.getElementById('eAtts').innerHTML = ''; (A.length ? A : [null]).forEach((a, i) => eAtt(a, i === 0));
        document.getElementById('eMlc').checked = !!H.IsMlc; document.getElementById('eMlcBlock').classList.toggle('d-none', !H.IsMlc);
        if (M) { set('emNo', M.MlcNo); set('emNature', M.Nature); set('emAt', M.IncidentAt ? Ipd.local(M.IncidentAt) : ''); set('emPlace', M.IncidentPlace); set('emBy', M.BroughtBy);
                 set('emByPh', M.BroughtByPhone); set('emPs', M.PoliceStation); set('emInf', M.InformedAt ? Ipd.local(M.InformedAt) : ''); set('emOff', M.OfficerName); set('emRem', M.Remarks); }
        ePayerUi();
        const modal = document.getElementById('editModal');
        $('.e-s2').each(function () { if ($(this).data('select2')) $(this).select2('destroy'); $(this).select2({ theme: 'bootstrap-5', width: '100%', dropdownParent: $(modal) }); });
        bootstrap.Modal.getOrCreateInstance(modal).show();
    });
    Ipd.icdSuggest(document.getElementById('eIcd'), document.getElementById('eDx'), base + 'IcdSearch');
document.getElementById('ePayer')?.addEventListener('change', ePayerUi);
    document.getElementById('eMlc')?.addEventListener('change', e => document.getElementById('eMlcBlock').classList.toggle('d-none', !e.target.checked));
    document.getElementById('eAddAtt')?.addEventListener('click', () => eAtt(null, false));
    document.getElementById('btnEditSave')?.addEventListener('click', async e => {
        const g = k => document.getElementById(k).value?.trim() || null, n = k => Number(document.getElementById(k).value) || null;
        const payer = g('ePayer');
        const payers = payer === 'CASH' ? [] : [{ PayerType: payer, InsuranceTpaId: payer === 'INSURANCE' ? n('eIns') : null, CorporateId: payer === 'CORPORATE' ? n('eCorp') : null,
            SchemeId: payer === 'SCHEME' ? n('eSch') : null, PolicyNo: g('ePol'), MemberId: g('eMem'), EmployeeId: g('eEmp'), CardHolderName: g('eHolder'), RelationToHolder: g('eHolderRel'),
            PolicyValidTo: g('eValid'), CardFilePath: (P[0] || {}).CardFilePath || null }];
        const atts = [...document.querySelectorAll('.e-att')].map(r => ({ Name: r.querySelector('.an').value.trim(), Relation: r.querySelector('.ar').value.trim(), Phone: r.querySelector('.ap').value.trim(),
            IdTypeId: Number(r.querySelector('.ait').value) || null, IdNumber: r.querySelector('.ain').value.trim(), IsPrimary: r.dataset.primary === '1' })).filter(a => a.Name);
        const mlc = { MlcNo: g('emNo'), Nature: g('emNature'), IncidentAt: g('emAt'), IncidentPlace: g('emPlace'), BroughtBy: g('emBy'), BroughtByPhone: g('emByPh'),
                      PoliceStation: g('emPs'), InformedAt: g('emInf'), OfficerName: g('emOff'), Remarks: g('emRem') };
        const body = { AdmissionType: g('eType'), AdmissionSource: g('eSource'), AdmittingDoctorId: n('eAdm') || 0, ConsultantDoctorId: n('eCon') || 0, DepartmentId: n('eDept'),
            ReferralDoctorId: n('eRef'), ExpectedDischargeAt: g('eExp'), PackageId: n('ePkg'), ProvisionalDiagnosis: g('eDx'), DiagnosisCode: g('eIcd'), ReasonForAdmission: g('eReason'),
            PayerType: payer, TariffCategoryId: n('eTariff') || 0, Remarks: g('eRemarks'), Payers: JSON.stringify(payers), Attendants: JSON.stringify(atts),
            IsMlc: document.getElementById('eMlc').checked, Mlc: JSON.stringify(mlc) };
        e.target.disabled = true;
        const r = await Ipd.post(base + 'Update?id=' + id, body);
        e.target.disabled = false;
        if (!r.success) { Ipd.error(r.error); return; }
        reloadTab('overview');
    });
})();
