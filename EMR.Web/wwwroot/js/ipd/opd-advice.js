/* OPD > Doctor Dashboard > consultation: "Advise Admission" (IPD Phase 4, SQLScripts/2438). The consultation script keeps
   the open visit in activeOPDServiceId; this file only reads it, so the OPD flow is unchanged. */
(function () {
    'use strict';
    const btn = document.getElementById('btnAdviseAdmission');
    if (!btn || !window.Swal || !window.Ipd) return;
    const base = '/IpdAdvice/';
    const visit = () => (typeof activeOPDServiceId !== 'undefined' && activeOPDServiceId) ? activeOPDServiceId : null;

    btn.addEventListener('click', async () => {
        const id = visit();
        if (!id) { Ipd.error('Open a patient consultation first.'); return; }
        let depts = [], current = null;
        try { depts = await Ipd.get(base + 'Departments') || []; } catch { depts = []; }
        try { current = ((await Ipd.get(base + 'ForVisit?opdServiceId=' + id)) || [])[0] || null; } catch { current = null; }
        const E = Ipd.esc, v = (k, d = '') => current && current[k] != null ? current[k] : d;
        const r = await Swal.fire({
            title: current ? 'Admission advice (update)' : 'Advise admission',
            width: 640,
            html: `<div class="text-start">
                <label class="form-label small fw-semibold mt-1" for="aaReason">Reason for admission <span class="text-danger">*</span></label>
                <textarea id="aaReason" class="form-control" rows="2" maxlength="500">${E(v('Reason'))}</textarea>
                <div class="row g-2 mt-1">
                    <div class="col-8 position-relative"><label class="form-label small fw-semibold" for="aaDx">Provisional diagnosis</label><input id="aaDx" class="form-control" maxlength="500" value="${E(v('Diagnosis'))}" /></div>
                    <div class="col-4 position-relative"><label class="form-label small fw-semibold" for="aaIcd">ICD-10</label><input id="aaIcd" class="form-control text-uppercase" maxlength="20" value="${E(v('DiagnosisCode'))}" /></div>
                    <div class="col-4"><label class="form-label small fw-semibold" for="aaUrg">Urgency</label><select id="aaUrg" class="form-select">
                        ${['ROUTINE', 'URGENT', 'EMERGENCY'].map(u => `<option value="${u}" ${v('Urgency', 'ROUTINE') === u ? 'selected' : ''}>${u.charAt(0) + u.slice(1).toLowerCase()}</option>`).join('')}</select></div>
                    <div class="col-8"><label class="form-label small fw-semibold" for="aaAt">Expected admission</label><input id="aaAt" type="datetime-local" class="form-control" value="${v('ExpectedAt') ? Ipd.local(v('ExpectedAt')) : ''}" /></div>
                    <div class="col-12"><label class="form-label small fw-semibold" for="aaDept">IPD department</label><select id="aaDept" class="form-select"><option value="">-- Choose at admission --</option>
                        ${depts.map(d => `<option value="${d.DeptId}" ${Number(v('DepartmentId', 0)) === d.DeptId ? 'selected' : ''}>${E(d.DeptName)}</option>`).join('')}</select></div>
                    <div class="col-12"><label class="form-label small fw-semibold" for="aaRem">Note to the admission desk</label><input id="aaRem" class="form-control" maxlength="300" value="${E(v('Remarks'))}" placeholder="e.g. NPO from midnight, arrange ICU bed" /></div>
                </div></div>`,
            didOpen: () => Ipd.icdSuggest(document.getElementById('aaIcd'), document.getElementById('aaDx'), base + 'Icd'),
            showCancelButton: true, confirmButtonText: current ? 'Update advice' : 'Advise admission',
            preConfirm: () => {
                const reason = document.getElementById('aaReason').value.trim();
                if (!reason) { Swal.showValidationMessage('Enter the reason for admission.'); return false; }
                return {
                    opdServiceId: id, reason, diagnosis: document.getElementById('aaDx').value.trim() || null, diagnosisCode: document.getElementById('aaIcd').value.trim() || null,
                    urgency: document.getElementById('aaUrg').value, expectedAt: document.getElementById('aaAt').value || null,
                    departmentId: Number(document.getElementById('aaDept').value) || null, remarks: document.getElementById('aaRem').value.trim() || null
                };
            }
        });
        if (!r.isConfirmed) return;
        const res = await Ipd.post(base + 'Save', r.value);
        if (!res.success) { Ipd.error(res.error); return; }
        Ipd.toast('Admission advised: the IPD desk will see it on the IPD Dashboard');
    });
})();
