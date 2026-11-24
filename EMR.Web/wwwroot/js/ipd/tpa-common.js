/* IPD Phase 6 - Insurance / TPA (SQLScripts/2539-2542): shared by the Insurance / TPA tab (insurance.js) and the
   Pre-Authorisations worklist (preauths.js): status pills, the IRDAI clock, and the dialog that records a pre-auth step. */
(function () {
    'use strict';
    const esc = v => Ipd.esc(v);

    const STATUS = {
        DRAFT: 'Draft', REQUESTED: 'Waiting for TPA', QUERY: 'TPA query', APPROVED: 'Approved', ENHANCE_REQUESTED: 'Enhancement asked',
        FINAL_REQUESTED: 'Final authorisation asked', FINAL_APPROVED: 'Final authorised', REJECTED: 'Rejected', CANCELLED: 'Cancelled',
        OPEN: 'Documents pending', SUBMITTED: 'Submitted', PART_SETTLED: 'Part settled', SETTLED: 'Settled', PENDING: 'Pending', POSTED: 'Posted'
    };

    // what each step asks for; amount = label of the amount, ref = the TPA's reference, why = remarks required
    const STEPS = {
        REQUEST:         { title: 'Send the pre-authorisation request', btn: 'Send request', icon: 'bi-send', cls: 'btn-primary', amount: 'Amount asked (estimate)', ref: 'TPA / insurer reference (if given)' },
        QUERY:           { title: 'The TPA raised a query', btn: 'TPA query', icon: 'bi-question-circle', cls: 'btn-outline-warning', why: 'What the TPA asked' },
        QUERY_REPLY:     { title: 'Reply sent to the TPA query', btn: 'Reply sent', icon: 'bi-reply', cls: 'btn-outline-primary', note: 'What was sent' },
        APPROVAL:        { title: 'The TPA approved', btn: 'Approved', icon: 'bi-check2-circle', cls: 'btn-success', amount: 'Total approved amount (incl. enhancements)', ref: 'Authorisation / approval no.' },
        REJECTION:       { title: 'The TPA rejected', btn: 'Rejected', icon: 'bi-x-circle', cls: 'btn-outline-danger', why: 'Reason given by the TPA' },
        ENHANCE_REQUEST: { title: 'Ask for an enhancement', btn: 'Ask enhancement', icon: 'bi-arrow-up-circle', cls: 'btn-outline-primary', amount: 'New total amount asked' },
        FINAL_REQUEST:   { title: 'Ask for the final (discharge) authorisation', btn: 'Ask final authorisation', icon: 'bi-flag', cls: 'btn-primary', amount: 'Final bill amount sent to the TPA' },
        FINAL_APPROVAL:  { title: 'Final authorisation received', btn: 'Final authorised', icon: 'bi-patch-check', cls: 'btn-success', amount: 'Final authorised amount', ref: 'Final authorisation no.' },
        CANCEL:          { title: 'Cancel this pre-authorisation', btn: 'Cancel pre-auth', icon: 'bi-slash-circle', cls: 'btn-outline-danger', why: 'Reason (e.g. patient chose to pay, wrong policy)' },
        NOTE:            { title: 'Add a note', btn: 'Note', icon: 'bi-chat-left-text', cls: 'btn-outline-secondary', why: 'Note' }
    };

    /** The steps that fit the current status (the stored procedure checks them again). */
    function nextSteps(p) {
        if (!p || !p.IsLive || p.UsedByBill) return ['NOTE'];
        const s = p.Status, prev = p.PrevStatus;
        const map = {
            DRAFT: ['REQUEST', 'CANCEL'],
            REQUESTED: ['APPROVAL', 'QUERY', 'REJECTION', 'CANCEL'],
            QUERY: prev === 'FINAL_REQUESTED' ? ['QUERY_REPLY', 'FINAL_APPROVAL', 'REJECTION'] : ['QUERY_REPLY', 'APPROVAL', 'REJECTION'],
            APPROVED: ['FINAL_REQUEST', 'ENHANCE_REQUEST', 'CANCEL'],
            ENHANCE_REQUESTED: ['APPROVAL', 'QUERY', 'REJECTION', 'FINAL_REQUEST'],
            FINAL_REQUESTED: ['FINAL_APPROVAL', 'QUERY', 'REJECTION'],
            FINAL_APPROVED: []
        };
        return (map[s] || []).concat(['NOTE']);
    }

    function pill(s) { return `<span class="tpa-pill s-${esc(s)}">${esc(STATUS[s] || s)}</span>`; }

    /** The IRDAI clock: minutes waiting for the TPA against the limit (60 min decision, 180 min final authorisation). */
    function clock(waiting, sla) {
        if (waiting == null || !sla) return '';
        const r = waiting / sla, cls = r > 1 ? 'late' : r >= 0.75 ? 'near' : 'ok';
        const t = waiting >= 120 ? `${Math.floor(waiting / 60)} h ${waiting % 60} min` : `${waiting} min`;
        return `<span class="tpa-clock ${cls}" title="IRDAI: decision within ${sla === 180 ? '3 hours (final authorisation)' : '1 hour'} of the request"><i class="bi bi-stopwatch"></i>${t} / ${sla === 180 ? '3 h' : '1 h'}</span>`;
    }

    function minutes(m) { return m == null ? '' : m >= 120 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`; }

    /**
     * Records a step of pre-auth p. opts: { url: IpdInsurance base, admissionId, amountHint, onDone }.
     * Optional file: uploaded first as a pre-auth document, then linked to the step.
     */
    async function stepDialog(step, p, opts) {
        const d = STEPS[step]; if (!d || !window.Swal) return;
        const last = p.LastEventAt ? new Date(p.LastEventAt) : null;
        const amt = d.amount ? `<label class="form-label small fw-semibold mt-2">${esc(d.amount)}</label><input id="tsAmt" type="number" min="1" step="0.01" class="form-control" value="${opts.amountHint ?? ''}">` : '';
        const ref = d.ref ? `<label class="form-label small fw-semibold mt-2">${esc(d.ref)}</label><input id="tsRef" class="form-control" maxlength="60" value="${esc(step === 'REQUEST' ? '' : (p.TpaRefNo || ''))}">` : '';
        const rem = `<label class="form-label small fw-semibold mt-2">${esc(d.why || d.note || 'Remarks')}${d.why ? ' <span class="text-danger">*</span>' : ' (optional)'}</label><textarea id="tsRem" class="form-control" rows="2" maxlength="500"></textarea>`;
        const file = step === 'CANCEL' ? '' : `<label class="form-label small fw-semibold mt-2">Attach the TPA letter / e-mail (optional)</label><input id="tsFile" type="file" class="form-control" accept=".pdf,.jpg,.jpeg,.png,.doc,.docx">`;
        const html = `<div class="text-start small">
            <div class="mb-2 text-muted">${esc(p.PreAuthNo || '')} · ${esc(p.PayerName || '')}</div>
            <label class="form-label small fw-semibold">When it happened</label>
            <input id="tsAt" type="datetime-local" class="form-control" value="${Ipd.local()}" max="${Ipd.local()}">
            <div class="form-text">The IRDAI clock uses this time. Enter the actual time of the TPA's mail / call.</div>
            ${amt}${ref}${rem}${file}</div>`;
        const r = await Swal.fire({
            title: d.title, html, showCancelButton: true, confirmButtonText: d.btn, focusConfirm: false, width: 560,
            preConfirm: () => {
                const v = { at: document.getElementById('tsAt').value, amount: d.amount ? Number(document.getElementById('tsAmt').value) : null,
                            ref: d.ref ? document.getElementById('tsRef').value.trim() : null, remarks: document.getElementById('tsRem').value.trim(),
                            file: document.getElementById('tsFile')?.files?.[0] || null };
                if (!v.at) { Swal.showValidationMessage('Enter the time.'); return false; }
                if (d.amount && !(v.amount > 0)) { Swal.showValidationMessage('Enter the amount.'); return false; }
                if (d.why && !v.remarks) { Swal.showValidationMessage('Enter the ' + d.why.toLowerCase() + '.'); return false; }
                return v;
            }
        });
        if (!r.isConfirmed) return;
        const v = r.value;
        let documentId = null;
        if (v.file) {
            const fd = new FormData();
            fd.append('file', v.file); fd.append('preAuthId', p.PreAuthId); fd.append('title', d.title);
            const up = await Ipd.postForm(opts.url + 'UploadDocument?id=' + (opts.admissionId || p.AdmissionId), fd);
            if (!up.success) return Ipd.error(up.error);
            documentId = up.data.DocumentId;
        }
        const res = await Ipd.post(opts.url + 'PreAuthEvent?preAuthId=' + p.PreAuthId, {
            eventType: step, eventAt: v.at, amount: v.amount, refNo: v.ref || null, remarks: v.remarks || null, documentId
        });
        if (!res.success) return Ipd.error(res.error);
        Ipd.toast(`${p.PreAuthNo}: ${STATUS[res.data.Status] || res.data.Status}`);
        opts.onDone && opts.onDone(res.data);
    }

    window.Tpa = { STATUS, STEPS, nextSteps, pill, clock, minutes, stepDialog };
})();
