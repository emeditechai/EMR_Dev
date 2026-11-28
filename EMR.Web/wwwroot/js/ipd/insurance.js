/* IPD Patient > Insurance / TPA (Phase 6, SQLScripts/2539-2542): pre-authorisation with the IRDAI clock, the patient's share
   (co-pay / deductible / non-payables), the pre-auth document checklist, timeline and claims. Config: window.IpdTpa. */
(function () {
    'use strict';
    const C = window.IpdTpa; if (!C || !document.getElementById('tpaBody')) return;
    const $ = id => document.getElementById(id), esc = v => Ipd.esc(v), money = v => Ipd.money(v);
    const url = C.base;
    let data = null, loaded = false;

    async function load() {
        try { data = await Ipd.get(url + 'TabData?id=' + C.id); render(); }
        catch (e) { $('tpaBody').innerHTML = `<div class="alert alert-danger small">${esc(e.message)}</div>`; }
    }
    const refresh = () => { load(); window.IpdBillRefresh && window.IpdBillRefresh(); };

    function section(icon, color, title, sub, body, tools = '') {
        return `<div class="reg-section"><div class="reg-section-header"><div class="sec-icon ${color}"><i class="bi ${icon}"></i></div>
            <div class="flex-grow-1"><h6 class="fw-bold mb-0">${title}</h6>${sub ? `<small class="text-muted">${sub}</small>` : ''}</div>${tools}</div>
            <div class="reg-section-body">${body}</div></div>`;
    }

    function render() {
        const a = data.admission || {}, pas = data.preAuths || [], live = pas.find(p => p.IsLive), closed = pas.filter(p => !p.IsLive);
        let h = '';
        if (a.PayerType !== 'INSURANCE') {
            h += section('bi-info-circle', 'blue', 'Pre-authorisation', '', `<div class="small text-muted">Pre-authorisation and TPA claims are for insurance / TPA patients. This admission's payer is
                <b>${esc(Ipd.payer(a.PayerType))}</b>. To bill an insurer, change the payer with <b>Edit admission</b> (Change tariff permission).</div>`);
            if (pas.length) h += history(pas);
            $('tpaBody').innerHTML = h; return;
        }
        if (!live) {
            const btn = C.can.preauth && a.CanStartPreAuth ? `<button type="button" class="btn btn-sm btn-primary" id="tpaStart"><i class="bi bi-plus-circle me-1"></i>Start pre-authorisation</button>` : '';
            h += section('bi-shield-check', 'violet', 'Pre-authorisation', `${esc(a.PayerName || '')} ${a.AuthorizationRequired ? '· cashless needs pre-authorisation' : ''}`,
                `<div class="d-flex align-items-center gap-3 flex-wrap"><div class="small text-muted flex-grow-1">No pre-authorisation in progress.
                 ${a.BillId ? 'The final bill is made: without an approved pre-authorisation the patient pays the whole bill (the patient can claim reimbursement).'
                            : 'Start one, send the request to the TPA, and record each answer here. Without an approval the patient pays the bill.'}</div>${btn}</div>`);
        } else h += liveCard(live, a);
        if (live) h += shareCard(live, a);
        else if (a.BillId && a.BillPayerShare > 0) h += billSplit(a);
        if (live) h += checklist();
        if ((data.claims || []).length) h += claims();
        if (closed.length) h += history(closed);
        h += timeline();
        $('tpaBody').innerHTML = h;
        wire(live, a);
    }

    function liveCard(p, a) {
        const steps = C.can.preauth ? Tpa.nextSteps(p).map(s => {
            const d = Tpa.STEPS[s];
            return `<button type="button" class="btn btn-sm ${d.cls}" data-step="${s}"><i class="bi ${d.icon} me-1"></i>${esc(d.btn)}</button>`;
        }).join('') : '';
        const edit = C.can.preauth && !p.UsedByBill ? `<button type="button" class="btn btn-sm btn-light border" id="tpaEdit"><i class="bi bi-pencil me-1"></i>Details</button>` : '';
        const auth = p.Authorised || 0, bill = a.BillId ? a.BillNet : a.BillNow;
        const warn = !a.BillId && auth > 0 && bill > auth && ['APPROVED', 'FINAL_APPROVED'].includes(p.Status)
            ? `<div class="alert alert-warning py-2 small mb-2"><i class="bi bi-exclamation-triangle me-1"></i>The bill so far (${money(bill)}) is above the approved ${money(auth)}: ${p.Status === 'APPROVED' ? 'ask an enhancement, or' : ''} the difference is the patient's.</div>` : '';
        const times = [p.DecisionMinutes != null ? `decision in ${Tpa.minutes(p.DecisionMinutes)}${p.DecisionMinutes > 60 ? ' <b class="text-danger">(over 1 h)</b>' : ''}` : '',
                       p.FinalMinutes != null ? `final authorisation in ${Tpa.minutes(p.FinalMinutes)}${p.FinalMinutes > 180 ? ' <b class="text-danger">(over 3 h)</b>' : ''}` : ''].filter(Boolean).join(' · ');
        const body = `${warn}
            <div class="d-flex flex-wrap align-items-center gap-2 mb-2">${Tpa.pill(p.Status)}${p.Status === 'QUERY' ? `<span class="small text-muted">on the ${esc((Tpa.STATUS[p.PrevStatus] || '').toLowerCase())}</span>` : ''}
                ${Tpa.clock(p.WaitingMinutes, p.SlaMinutes)}${times ? `<span class="small text-muted">${times}</span>` : ''}
                ${p.UsedByBill ? '<span class="ipd-pill info">used by the final bill</span>' : ''}</div>
            <div class="tpa-amounts mb-3">
                <div><small>Estimate</small><b>${money(p.EstimatedAmount)}</b></div>
                <div><small>Asked</small><b>${money(p.RequestedAmount)}</b>${p.RequestedAt ? `<div class="small text-muted">${Ipd.dt(p.RequestedAt)}</div>` : ''}</div>
                <div class="hl"><small>Approved</small><b>${money(p.ApprovedAmount)}</b>${p.EnhancementRequested ? `<div class="small text-muted">asked ${money(p.EnhancementRequested)}</div>` : ''}</div>
                ${p.FinalRequestedAmount ? `<div><small>Final asked</small><b>${money(p.FinalRequestedAmount)}</b><div class="small text-muted">${Ipd.dt(p.FinalRequestedAt)}</div></div>` : ''}
                ${p.FinalApprovedAmount ? `<div class="hl"><small>Final authorised</small><b>${money(p.FinalApprovedAmount)}</b></div>` : ''}
            </div>
            <div class="small mb-2 text-muted">${p.Diagnosis ? `<b>Diagnosis:</b> ${esc(p.Diagnosis)} · ` : ''}${p.TreatmentPlan ? `<b>Treatment:</b> ${esc(p.TreatmentPlan)} · ` : ''}${p.ExpectedDays ? `${p.ExpectedDays} day(s) expected · ` : ''}Policy ${esc(p.PolicyNo || '—')} · Member ${esc(p.MemberId || '—')}</div>
            <div class="tpa-steps">${steps}</div>`;
        return section('bi-shield-check', 'violet', `Pre-authorisation ${esc(p.PreAuthNo)}`, `${esc(p.PayerName || '')}${p.TpaRefNo ? ' · TPA ref ' + esc(p.TpaRefNo) : ''}`, body, edit);
    }

    function splitPreview(a) {
        if (a.BillId) return billSplit(a, true);
        return `<div class="tpa-amounts mt-3">
            <div><small>Bill so far</small><b>${money(a.BillNow)}</b></div>
            <div><small>Co-pay</small><b>${money(a.LiveCoPayAmount)}</b></div>
            <div class="hl"><small>TPA pays (now)</small><b>${money(a.LivePayerShare)}</b><div class="small text-muted">of ${money(a.LiveAuthorised)} approved</div></div>
            <div class="pt"><small>Patient pays</small><b>${money(a.LivePatientShare)}</b><div class="small text-muted">advance held ${money(a.NetAdvance)}</div></div></div>
            <div class="form-text">The final bill splits the same way: (bill − non-payables − deductible) less co-pay, up to the approved / final authorised amount. With a room-rent limit, the rent above it and the associated charges (doctor, procedures, OT, services) in the same proportion are not payable by the insurer; medicines, consumables, implants and investigations are never cut.</div>`;
    }

    function billSplit(a, inner) {
        const body = `<div class="tpa-amounts ${inner ? 'mt-3' : ''}">
            <div><small>Bill ${esc(a.BillNo || '')}</small><b>${money(a.BillNet)}</b></div>
            <div><small>Authorised</small><b>${money(a.PayerAuthorised)}</b></div>
            <div><small>Co-pay / deductible / non-pay.</small><b>${money(a.BillCoPayAmount)} · ${money(a.BillDeductible)} · ${money(a.BillNonPayable)}</b></div>
            <div class="hl"><small>TPA share (claim)</small><b>${money(a.BillPayerShare - (a.PayerToPatient || 0))}</b>${a.PayerToPatient ? `<div class="small text-danger">${money(a.PayerToPatient)} disallowed → patient</div>` : ''}</div>
            <div class="pt"><small>Patient share</small><b>${money(a.BillPatientShare)}</b></div></div>`;
        return inner ? body : section('bi-pie-chart', 'green', 'Final bill split', '', body);
    }

    function shareCard(p, a) {
        const ro = !C.can.preauth || p.UsedByBill || a.BillId;
        const body = `<div class="row g-2 align-items-end tpa-split">
            <div class="col-auto"><label class="form-label small fw-semibold">Co-pay %</label><input id="spCo" type="number" min="0" max="100" step="0.01" class="form-control form-control-sm" value="${p.CoPayPercent}" ${ro ? 'disabled' : ''}></div>
            <div class="col-auto"><label class="form-label small fw-semibold">Deductible ₹</label><input id="spDed" type="number" min="0" step="0.01" class="form-control form-control-sm" value="${p.Deductible}" ${ro ? 'disabled' : ''}></div>
            <div class="col-auto"><label class="form-label small fw-semibold">Non-payables ₹</label><input id="spNp" type="number" min="0" step="0.01" class="form-control form-control-sm" value="${p.NonPayable}" ${ro ? 'disabled' : ''}></div>
            <div class="col-auto"><label class="form-label small fw-semibold" title="Room-rent eligibility per day (IRDAI proportionate deduction)">Room rent limit ₹/day</label><input id="spRr" type="number" min="0" step="1" class="form-control form-control-sm" value="${p.RoomRentLimit ?? ''}" placeholder="no limit" ${ro ? 'disabled' : ''}></div>
            <div class="col-auto"><label class="form-label small fw-semibold">ICU limit ₹/day</label><input id="spIr" type="number" min="0" step="1" class="form-control form-control-sm" value="${p.IcuRentLimit ?? ''}" placeholder="no limit" ${ro ? 'disabled' : ''}></div>
            <div class="col"><label class="form-label small fw-semibold">Remarks</label><input id="spRem" class="form-control form-control-sm" maxlength="300" value="${esc(p.SplitRemarks || '')}" placeholder="e.g. 10 % co-pay as per policy, room rent difference" ${ro ? 'disabled' : ''}></div>
            ${ro ? '' : '<div class="col-auto"><button type="button" class="btn btn-sm btn-primary" id="spSave"><i class="bi bi-save me-1"></i>Save</button></div>'}
        </div>${splitPreview(a)}`;
        return section('bi-pie-chart', 'green', "Patient's share", 'As per the policy and the TPA letter: co-pay, deductible and non-payable items are paid by the patient', body);
    }

    function checklist() {
        const rows = (data.checklist || []).map(c => `<tr class="${c.IsDone ? 'done' : c.IsMandatory ? 'missing' : ''}" data-doc="${c.DocTypeId}">
            <td style="width:34px"><input type="checkbox" class="form-check-input tpa-tick" ${c.IsDone ? 'checked' : ''} ${C.can.preauth ? '' : 'disabled'}></td>
            <td>${esc(c.Name)}${c.IsMandatory ? ' <span class="text-danger">*</span>' : ''}${c.CheckedByName && c.IsDone ? `<div class="small text-muted">${esc(c.CheckedByName)} · ${Ipd.dt(c.CheckedAt)}</div>` : ''}</td>
            <td>${c.DocumentPath ? `<a href="${esc(c.DocumentPath)}" target="_blank"><i class="bi bi-paperclip"></i> ${esc(c.DocumentTitle || 'View')}</a>` : ''}</td>
            <td class="text-end">${C.can.preauth ? `<label class="btn btn-sm btn-light border mb-0"><i class="bi bi-upload me-1"></i>Upload<input type="file" class="d-none tpa-up" accept=".pdf,.jpg,.jpeg,.png,.doc,.docx"></label>` : ''}</td></tr>`).join('');
        return section('bi-card-checklist', 'amber', 'Pre-authorisation documents', 'Tick what was sent to the TPA, or upload it (Master › IPD Master › TPA Document Checklist)',
            `<table class="table table-sm tpa-check mb-0"><tbody>${rows || '<tr><td class="text-muted">No document types in the checklist master.</td></tr>'}</tbody></table>`);
    }

    function claims() {
        const rows = data.claims.map(c => `<tr><td class="fw-semibold">${esc(c.ClaimNo)}</td><td>${Tpa.pill(c.Status)}</td><td>${esc(c.BillNo)}</td><td class="text-end">${money(c.ClaimAmount)}</td>
            <td class="text-end">${money(c.SettledAmount)}</td><td class="text-end">${money(c.TdsAmount)}</td><td class="text-end">${money(c.DisallowedAmount)}</td><td class="text-end fw-semibold">${money(c.Outstanding)}</td></tr>`).join('');
        return section('bi-file-earmark-medical', 'blue', 'TPA claims', 'Submit, settle and follow up in IPD › TPA Claims',
            `<table class="table table-sm ipd-table mb-0"><thead><tr><th>Claim</th><th>Status</th><th>Bill</th><th class="text-end">Claim</th><th class="text-end">Received</th><th class="text-end">TDS</th><th class="text-end">Disallowed</th><th class="text-end">Outstanding</th></tr></thead><tbody>${rows}</tbody></table>`,
            data.claimsUrl ? `<a class="btn btn-sm btn-light border" href="${esc(data.claimsUrl)}"><i class="bi bi-box-arrow-up-right me-1"></i>TPA Claims</a>` : '');
    }

    function history(list) {
        const rows = list.map(p => `<tr><td class="fw-semibold">${esc(p.PreAuthNo)}</td><td>${Tpa.pill(p.Status)}</td><td>${esc(p.PayerName || '')}</td><td class="text-end">${money(p.RequestedAmount)}</td>
            <td class="text-end">${money(p.Authorised)}</td><td>${esc(p.CancelReason || '')}</td><td>${Ipd.dt(p.CreatedDate)}</td></tr>`).join('');
        return section('bi-clock-history', 'slate', 'Earlier pre-authorisations', '', `<table class="table table-sm ipd-table mb-0"><thead><tr><th>No.</th><th>Status</th><th>Payer</th><th class="text-end">Asked</th><th class="text-end">Authorised</th><th>Reason</th><th>Started</th></tr></thead><tbody>${rows}</tbody></table>`);
    }

    function timeline() {
        const ev = data.events || [];
        if (!ev.length) return '';
        const li = ev.map(e => `<li class="e-${esc(e.EventType)}"><b>${esc((Tpa.STEPS[e.EventType] || {}).title || e.EventType)}</b>
            ${e.Amount != null ? ` · ${money(e.Amount)}` : ''}${e.RefNo ? ` · ref ${esc(e.RefNo)}` : ''}
            ${e.DocumentPath ? ` · <a href="${esc(e.DocumentPath)}" target="_blank"><i class="bi bi-paperclip"></i>${esc(e.DocumentTitle || 'letter')}</a>` : ''}
            ${e.Remarks ? `<div>${esc(e.Remarks)}</div>` : ''}<div class="t">${Ipd.dt(e.EventAt)} · ${esc(e.CreatedByName || '')}${e.ToStatus && e.ToStatus !== e.FromStatus ? ' · ' + esc(Tpa.STATUS[e.ToStatus] || e.ToStatus) : ''}</div></li>`).join('');
        return section('bi-list-ol', 'slate', 'Timeline', 'Every step with its time (the IRDAI clock)', `<ul class="tpa-timeline">${li}</ul>`);
    }

    // ── actions ──
    async function details(p) {
        const a = data.admission || {};
        const r = await Swal.fire({
            title: p ? 'Pre-authorisation details' : 'Start pre-authorisation', width: 620, showCancelButton: true, confirmButtonText: 'Save', focusConfirm: false,
            html: `<div class="text-start small">
                <label class="form-label fw-semibold">Diagnosis</label><input id="pdDx" class="form-control" maxlength="300" value="${esc(p ? p.Diagnosis || '' : '')}">
                <label class="form-label fw-semibold mt-2">Line of treatment / procedure</label><input id="pdTx" class="form-control" maxlength="500" value="${esc(p ? p.TreatmentPlan || '' : '')}">
                <div class="row g-2 mt-1"><div class="col"><label class="form-label fw-semibold">Expected stay (days)</label><input id="pdDays" type="number" min="0" class="form-control" value="${p ? p.ExpectedDays ?? '' : ''}"></div>
                <div class="col"><label class="form-label fw-semibold">Estimated cost ₹</label><input id="pdEst" type="number" min="0" step="0.01" class="form-control" value="${p ? p.EstimatedAmount : ''}"></div></div>
                <label class="form-label fw-semibold mt-2">TPA / insurer reference (if given)</label><input id="pdRef" class="form-control" maxlength="60" value="${esc(p ? p.TpaRefNo || '' : '')}">
                <label class="form-label fw-semibold mt-2">Remarks</label><textarea id="pdRem" class="form-control" rows="2" maxlength="500">${esc(p ? p.Remarks || '' : '')}</textarea>
                ${p ? '' : `<div class="form-text">Payer: <b>${esc(a.PayerName || '')}</b> · policy ${esc(a.PolicyNo || '—')}. The diagnosis is taken from the admission if left blank.</div>`}</div>`,
            preConfirm: () => ({ preAuthId: p ? p.PreAuthId : null, diagnosis: $('pdDx').value.trim() || null, treatmentPlan: $('pdTx').value.trim() || null,
                expectedDays: $('pdDays').value ? Number($('pdDays').value) : null, estimatedAmount: Number($('pdEst').value) || 0,
                tpaRefNo: $('pdRef').value.trim() || null, remarks: $('pdRem').value.trim() || null })
        });
        if (!r.isConfirmed) return;
        const res = await Ipd.post(url + 'SavePreAuth?id=' + C.id, r.value);
        if (!res.success) return Ipd.error(res.error);
        Ipd.toast((p ? 'Saved ' : 'Started ') + res.data.PreAuthNo);
        await load();
        if (!p && await Ipd.confirm('Send the request to the TPA now?', 'Record it when the request is sent (the IRDAI clock starts then).', 'Record request')) {
            const live = (data.preAuths || []).find(x => x.IsLive);
            if (live) await Tpa.stepDialog('REQUEST', live, { url, admissionId: C.id, amountHint: live.EstimatedAmount || '', onDone: refresh });
        }
    }

    function hint(step, p, a) {
        const bill = a.BillNow || 0;
        return { REQUEST: p.EstimatedAmount || '', APPROVAL: p.EnhancementRequested || p.RequestedAmount || '', ENHANCE_REQUEST: Math.max(bill, p.ApprovedAmount + 1) || '',
                 FINAL_REQUEST: bill || '', FINAL_APPROVAL: p.FinalRequestedAmount || '' }[step] ?? '';
    }

    function wire(live, a) {
        $('tpaStart')?.addEventListener('click', () => details(null));
        $('tpaEdit')?.addEventListener('click', () => details(live));
        document.querySelectorAll('#tpaBody [data-step]').forEach(b => b.addEventListener('click', () =>
            Tpa.stepDialog(b.dataset.step, live, { url, admissionId: C.id, amountHint: hint(b.dataset.step, live, a), onDone: refresh })));
        $('spSave')?.addEventListener('click', async () => {
            const res = await Ipd.post(url + 'SaveSplit?preAuthId=' + live.PreAuthId, {
                coPayPercent: Number($('spCo').value) || 0, deductible: Number($('spDed').value) || 0, nonPayable: Number($('spNp').value) || 0, remarks: $('spRem').value.trim() || null,
                roomRentLimit: Number($('spRr').value) || null, icuRentLimit: Number($('spIr').value) || null });
            if (!res.success) return Ipd.error(res.error);
            Ipd.toast("Patient's share saved"); refresh();
        });
        document.querySelectorAll('#tpaBody .tpa-tick').forEach(cb => cb.addEventListener('change', async () => {
            const tr = cb.closest('tr');
            const res = await Ipd.post(url + 'Checklist', { preAuthId: live.PreAuthId, docTypeId: Number(tr.dataset.doc), isDone: cb.checked });
            if (!res.success) { cb.checked = !cb.checked; return Ipd.error(res.error); }
            tr.classList.toggle('done', cb.checked); tr.classList.remove('missing');
        }));
        document.querySelectorAll('#tpaBody .tpa-up').forEach(inp => inp.addEventListener('change', async () => {
            const f = inp.files[0]; if (!f) return;
            const fd = new FormData(); fd.append('file', f); fd.append('preAuthId', live.PreAuthId); fd.append('docTypeId', inp.closest('tr').dataset.doc);
            const res = await Ipd.postForm(url + 'UploadDocument?id=' + C.id, fd);
            if (!res.success) return Ipd.error(res.error);
            Ipd.toast('Document uploaded'); load();
        }));
    }

    const tabBtn = document.querySelector('[data-tab="insurance"]');
    tabBtn?.addEventListener('shown.bs.tab', () => { if (!loaded) { loaded = true; load(); } });
    if (document.getElementById('tab-insurance')?.classList.contains('active')) { loaded = true; load(); }
})();
