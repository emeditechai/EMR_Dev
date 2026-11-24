/* IPD > TPA Claims (Phase 6, SQLScripts/2539-2542): list, claim window (documents, submission, queries, settlements, write-offs).
   Config: window.ClaimsPage */
(function () {
    'use strict';
    const P = window.ClaimsPage, $ = id => document.getElementById(id), esc = v => Ipd.esc(v), money = v => Ipd.money(v);
    const url = P.base, can = P.can;
    let rows = [], lookups = null, cur = null, curId = null;

    const MODES = [['PORTAL', 'TPA / insurer portal'], ['COURIER', 'Courier'], ['EMAIL', 'E-mail'], ['HAND', 'By hand']];

    async function loadLookups() {
        if (lookups) return lookups;
        lookups = await Ipd.get(url + 'Lookups');
        $('fTpa').insertAdjacentHTML('beforeend', (lookups.tpas || []).map(t => `<option value="${t.InsuranceTpaId}">${esc(t.Name)}</option>`).join(''));
        return lookups;
    }

    async function load() {
        const q = new URLSearchParams({ status: $('fStatus').value });
        if ($('fTpa').value) q.set('insuranceTpaId', $('fTpa').value);
        if ($('fQ').value.trim()) q.set('search', $('fQ').value.trim());
        if ($('fFrom').value) q.set('fromDate', $('fFrom').value);
        if ($('fTo').value) q.set('toDate', $('fTo').value);
        try {
            const d = await Ipd.get(url + 'ListData?' + q);
            rows = d.rows || [];
            kpis(d.kpi || {}); render();
        } catch (e) { $('rows').innerHTML = `<tr><td colspan="11" class="text-danger small p-3">${esc(e.message)}</td></tr>`; }
    }

    function kpis(k) {
        const t = (c, label, val, sub, st) => `<div class="ipdx-kpi" role="button" data-st="${st || ''}"><small>${label}</small><b style="color:${c}">${val}</b><span class="small text-muted">${sub}</span></div>`;
        $('kpis').innerHTML = t('#475569', 'To submit', k.ToSubmit || 0, 'documents / submission', 'OPEN')
            + t('#1d4ed8', 'Awaiting settlement', k.AwaitingSettlement || 0, 'submitted / part settled', 'ACTIVE')
            + t('#b45309', 'TPA queries', k.OpenQueries || 0, 'reply needed', 'QUERY')
            + t('#b91c1c', 'Outstanding', money(k.Outstanding), 'receivable from TPAs', 'ACTIVE')
            + t('#7c3aed', 'Write-offs to approve', k.PendingWriteOffs || 0, 'Approval Matrix', 'WRITEOFF')
            + t('#166534', 'Received this month', money(k.ReceivedThisMonth), 'bank receipts', '');
        document.querySelectorAll('#kpis [data-st]').forEach(x => x.addEventListener('click', () => { if (x.dataset.st) { $('fStatus').value = x.dataset.st; load(); } }));
    }

    function ageCls(d) { return d <= 30 ? 'tpa-age-30' : d <= 60 ? 'tpa-age-60' : d <= 90 ? 'tpa-age-90' : 'tpa-age-old'; }

    function render() {
        if (!rows.length) { $('rows').innerHTML = '<tr><td colspan="11" class="text-muted small p-3">No claims here.</td></tr>'; $('foot').innerHTML = ''; return; }
        $('rows').innerHTML = rows.map(r => `<tr class="tpa-row-click" data-id="${r.ClaimId}">
            <td><b>${esc(r.ClaimNo)}</b>${r.TpaClaimRef ? `<div class="small text-muted">${esc(r.TpaClaimRef)}</div>` : ''}</td>
            <td>${esc(r.PatientName)}<div class="small text-muted">${esc(r.IpNo)} · ${esc(r.PatientCode)}</div></td>
            <td>${esc(r.PayerName || '')}</td>
            <td>${esc(r.BillNo)}<div class="small text-muted">${Ipd.date(r.BillAt)}</div></td>
            <td>${Tpa.pill(r.Status)}${r.MissingDocs > 0 && r.Status === 'OPEN' ? `<div class="small text-danger">${r.MissingDocs} document(s) missing</div>` : ''}${r.PendingWriteOff > 0 ? `<div class="small text-warning">write-off ${money(r.PendingWriteOff)} to approve</div>` : ''}</td>
            <td class="text-end">${money(r.ClaimAmount)}</td><td class="text-end">${money(r.SettledAmount)}</td><td class="text-end">${money(r.TdsAmount)}</td>
            <td class="text-end">${money(r.DisallowedAmount)}</td><td class="text-end fw-semibold">${money(r.Outstanding)}</td>
            <td class="text-end ${ageCls(r.AgeDays)}">${r.AgeDays} d</td></tr>`).join('');
        const sum = k => rows.reduce((s, r) => s + (Number(r[k]) || 0), 0);
        $('foot').innerHTML = `<tr class="fw-semibold"><td colspan="5" class="text-end">${rows.length} claim(s)</td><td class="text-end">${money(sum('ClaimAmount'))}</td><td class="text-end">${money(sum('SettledAmount'))}</td>
            <td class="text-end">${money(sum('TdsAmount'))}</td><td class="text-end">${money(sum('DisallowedAmount'))}</td><td class="text-end">${money(sum('Outstanding'))}</td><td></td></tr>`;
        document.querySelectorAll('#rows tr[data-id]').forEach(tr => tr.addEventListener('click', () => open(+tr.dataset.id)));
    }

    // ── the claim window ──
    async function open(id) {
        curId = id;
        bootstrap.Modal.getOrCreateInstance($('claimModal')).show();
        await loadClaim();
    }
    async function loadClaim() {
        try { await loadLookups(); cur = await Ipd.get(url + 'ClaimData?id=' + curId); draw(); }
        catch (e) { $('cmBody').innerHTML = `<div class="alert alert-danger small">${esc(e.message)}</div>`; }
    }
    const after = async () => { await loadClaim(); load(); };

    function card(title, body, tools = '') {
        return `<div class="card border-0 shadow-sm mb-3"><div class="card-header bg-white d-flex align-items-center gap-2"><b class="flex-grow-1">${title}</b>${tools}</div><div class="card-body">${body}</div></div>`;
    }

    function draw() {
        const c = cur.claim, st = c.Status, live = st !== 'CANCELLED';
        $('cmTitle').innerHTML = `${esc(c.ClaimNo)} ${Tpa.pill(st)} <span class="small text-muted ms-2">${esc(c.PatientName)} · ${esc(c.IpNo)} · ${esc(c.PayerName || '')}</span>`;
        const pending = (cur.writeOffs || []).filter(w => w.Status === 'PENDING').reduce((s, w) => s + w.Amount, 0);
        let h = `<div class="d-flex gap-2 mb-3 flex-wrap">
            <a class="btn btn-sm btn-light border" href="${esc(cur.patientUrl)}"><i class="bi bi-person-vcard me-1"></i>Patient · Insurance tab</a>
            <a class="btn btn-sm btn-light border" target="_blank" href="${esc(cur.billUrl)}"><i class="bi bi-printer me-1"></i>Bill ${esc(c.BillNo)}</a>
            <span class="small text-muted align-self-center">Pre-auth ${esc(c.PreAuthNo || '—')} · policy ${esc(c.PolicyNo || '—')} · member ${esc(c.MemberId || '—')}${c.PayerPhone ? ' · TPA ' + esc(c.PayerPhone) : ''}${c.PayerEmail ? ' · ' + esc(c.PayerEmail) : ''}</span></div>
            <div class="tpa-amounts mb-3">
                <div><small>Bill</small><b>${money(c.BillNet)}</b><div class="small text-muted">patient ${money(c.PatientShare)}</div></div>
                <div><small>Authorised</small><b>${money(c.PayerAuthorised)}</b></div>
                <div class="hl"><small>Claim (TPA share)</small><b>${money(c.ClaimAmount)}</b></div>
                <div><small>Received</small><b>${money(c.SettledAmount)}</b></div>
                <div><small>TDS</small><b>${money(c.TdsAmount)}</b></div>
                <div><small>Disallowed</small><b>${money(c.DisallowedAmount)}</b><div class="small text-muted">patient ${money(c.ToPatientAmount)} · w/off ${money(c.WrittenOffAmount)}${pending ? ' · pending ' + money(pending) : ''}</div></div>
                <div class="pt"><small>Outstanding</small><b>${money(c.Outstanding)}</b></div></div>`;
        h += card('Claim details', `<div class="row g-2 align-items-end">
            <div class="col-md-4"><label class="form-label small fw-semibold">TPA claim / reference no.</label><input id="cdRef" class="form-control form-control-sm" maxlength="60" value="${esc(c.TpaClaimRef || '')}" ${can.submit && live ? '' : 'disabled'}></div>
            <div class="col-md-6"><label class="form-label small fw-semibold">Remarks</label><input id="cdRem" class="form-control form-control-sm" maxlength="500" value="${esc(c.Remarks || '')}" ${can.submit && live ? '' : 'disabled'}></div>
            ${can.submit && live ? '<div class="col-md-2"><button type="button" class="btn btn-sm btn-outline-primary w-100" id="cdSave">Save</button></div>' : ''}</div>
            ${c.SubmittedAt ? `<div class="small text-muted mt-2">Submitted ${Ipd.dt(c.SubmittedAt)} by ${esc((c.SubmissionMode || '').toLowerCase())}${c.SubmissionRef ? ' · ' + esc(c.SubmissionRef) : ''}</div>` : ''}`);
        h += docs(c, live);
        if (st === 'OPEN' && can.submit) h += submitCard(c);
        if (['SUBMITTED', 'PART_SETTLED', 'QUERY', 'SETTLED'].includes(st) && can.submit) h += queryCard(st);
        if (['SUBMITTED', 'QUERY', 'PART_SETTLED'].includes(st) && can.settle) h += settleCard(c);
        h += settlements();
        h += writeOffs();
        h += timeline();
        $('cmBody').innerHTML = h;
        wire(c);
    }

    function docs(c, live) {
        const list = cur.checklist || [];
        const missing = list.filter(x => x.IsMandatory && !x.IsDone).length;
        const rowsH = list.map(x => `<tr class="${x.IsDone ? 'done' : x.IsMandatory ? 'missing' : ''}" data-doc="${x.DocTypeId}">
            <td style="width:34px"><input type="checkbox" class="form-check-input cl-tick" ${x.IsDone ? 'checked' : ''} ${can.submit && live ? '' : 'disabled'}></td>
            <td>${esc(x.Name)}${x.IsMandatory ? ' <span class="text-danger">*</span>' : ''}${x.IsDone && x.CheckedByName ? `<div class="small text-muted">${esc(x.CheckedByName)} · ${Ipd.dt(x.CheckedAt)}</div>` : ''}</td>
            <td>${x.DocumentPath ? `<a href="${esc(x.DocumentPath)}" target="_blank"><i class="bi bi-paperclip"></i> ${esc(x.DocumentTitle || 'View')}</a>` : ''}</td>
            <td class="text-end">${can.submit && live ? `<label class="btn btn-sm btn-light border mb-0"><i class="bi bi-upload me-1"></i>Upload<input type="file" class="d-none cl-up" accept=".pdf,.jpg,.jpeg,.png,.doc,.docx"></label>` : ''}</td></tr>`).join('');
        return card(`Documents ${missing ? `<span class="text-danger small ms-2">${missing} mandatory missing</span>` : '<span class="text-success small ms-2">all mandatory documents ready</span>'}`,
            `<table class="table table-sm tpa-check mb-0"><tbody>${rowsH || '<tr><td class="text-muted">No checklist.</td></tr>'}</tbody></table>`);
    }

    function submitCard() {
        return card('Submit to the TPA', `<div class="row g-2 align-items-end">
            <div class="col-md-3"><label class="form-label small fw-semibold">Sent on</label><input id="sbAt" type="datetime-local" class="form-control form-control-sm" value="${Ipd.local()}" max="${Ipd.local()}"></div>
            <div class="col-md-3"><label class="form-label small fw-semibold">How</label><select id="sbMode" class="form-select form-select-sm">${MODES.map(m => `<option value="${m[0]}">${m[1]}</option>`).join('')}</select></div>
            <div class="col-md-3"><label class="form-label small fw-semibold">Acknowledgement / docket no.</label><input id="sbRef" class="form-control form-control-sm" maxlength="100"></div>
            <div class="col-md-3"><button type="button" class="btn btn-sm btn-primary w-100" id="sbGo"><i class="bi bi-send me-1"></i>Submit claim</button></div></div>`);
    }

    function queryCard(st) {
        const btns = [];
        if (['SUBMITTED', 'PART_SETTLED'].includes(st)) btns.push('<button type="button" class="btn btn-sm btn-outline-warning" data-ev="QUERY"><i class="bi bi-question-circle me-1"></i>TPA raised a query</button>');
        if (st === 'QUERY') btns.push('<button type="button" class="btn btn-sm btn-outline-primary" data-ev="QUERY_REPLY"><i class="bi bi-reply me-1"></i>Reply sent</button>');
        btns.push('<button type="button" class="btn btn-sm btn-outline-secondary" data-ev="NOTE"><i class="bi bi-chat-left-text me-1"></i>Note</button>');
        return card('Follow-up with the TPA', `<div class="d-flex gap-2 flex-wrap">${btns.join('')}</div>`);
    }

    function settleCard(c) {
        const modes = (lookups.modes || []).filter(m => (m.MethodCode || '').toUpperCase() !== 'CASH');
        return card('Enter a settlement', `<div class="row g-2">
            <div class="col-md-2"><label class="form-label small fw-semibold">Date</label><input id="stOn" type="date" class="form-control form-control-sm" value="${Ipd.local().substring(0, 10)}" max="${Ipd.local().substring(0, 10)}"></div>
            <div class="col-md-2"><label class="form-label small fw-semibold">Mode</label><select id="stMode" class="form-select form-select-sm">${modes.map(m => `<option value="${esc(m.MethodCode)}">${esc(m.MethodName)}</option>`).join('')}</select></div>
            <div class="col-md-2"><label class="form-label small fw-semibold">UTR / cheque no.</label><input id="stUtr" class="form-control form-control-sm" maxlength="60"></div>
            <div class="col-md-2"><label class="form-label small fw-semibold">Amount received ₹</label><input id="stAmt" type="number" min="0" step="0.01" class="form-control form-control-sm"></div>
            <div class="col-md-2"><label class="form-label small fw-semibold">TDS ₹ <a href="#" id="stTds10" class="small">10 %</a></label><input id="stTds" type="number" min="0" step="0.01" class="form-control form-control-sm" value="0"></div>
            <div class="col-md-2"><label class="form-label small fw-semibold">Disallowed ₹</label><input id="stDis" type="number" min="0" step="0.01" class="form-control form-control-sm" value="0"></div>
            <div class="col-md-5 st-dis d-none"><label class="form-label small fw-semibold">TPA's reason for the disallowance <span class="text-danger">*</span></label><input id="stWhy" class="form-control form-control-sm" maxlength="300"></div>
            <div class="col-md-4 st-dis d-none"><label class="form-label small fw-semibold">The disallowed amount is</label>
                <select id="stAct" class="form-select form-select-sm"><option value="PATIENT">collected from the patient</option><option value="WRITEOFF">written off (needs approval)</option></select></div>
            <div class="col-md-12"><label class="form-label small fw-semibold">Remarks</label><input id="stRem" class="form-control form-control-sm" maxlength="300"></div>
            <div class="col-md-9 small align-self-center" id="stCheck"></div>
            <div class="col-md-3"><button type="button" class="btn btn-sm btn-success w-100" id="stGo"><i class="bi bi-cash-coin me-1"></i>Save settlement</button></div></div>`);
    }

    function settlements() {
        const list = cur.settlements || [];
        if (!list.length) return '';
        const rowsH = list.map(s => `<tr class="${s.Status === 'CANCELLED' ? 'text-decoration-line-through text-muted' : ''}">
            <td>${esc(s.SettlementNo)}<div class="small text-muted">${esc(s.ReceiptVoucherNo || '')}${s.PatientVoucherNo ? ' · ' + esc(s.PatientVoucherNo) : ''}</div></td><td>${Ipd.date(s.SettledOn)}</td>
            <td>${esc(s.Mode || '')}${s.UtrNo ? `<div class="small text-muted">${esc(s.UtrNo)}</div>` : ''}</td>
            <td class="text-end">${money(s.Amount)}</td><td class="text-end">${money(s.TdsAmount)}</td>
            <td class="text-end">${money(s.DisallowedAmount)}${s.DisallowedAmount > 0 ? `<div class="small text-muted">${s.DisallowAction === 'PATIENT' ? 'to the patient' : 'write-off'} · ${esc(s.DisallowReason || '')}</div>` : ''}</td>
            <td>${Tpa.pill(s.Status)}${s.CancelReason ? `<div class="small text-muted">${esc(s.CancelReason)}</div>` : ''}</td>
            <td class="text-end">${s.Status === 'POSTED' && can.settleCancel ? `<button type="button" class="btn btn-sm btn-outline-danger py-0" data-cancel="${s.SettlementId}">Cancel</button>` : ''}</td></tr>`).join('');
        return card('Settlements', `<div class="table-responsive"><table class="table table-sm ipd-table mb-0"><thead><tr><th>No.</th><th>Date</th><th>Mode</th><th class="text-end">Received</th><th class="text-end">TDS</th><th class="text-end">Disallowed</th><th>Status</th><th></th></tr></thead><tbody>${rowsH}</tbody></table></div>`);
    }

    function writeOffs() {
        const list = cur.writeOffs || [];
        if (!list.length) return '';
        const rowsH = list.map(w => {
            const mine = w.RequestedBy === cur.me;
            const act = w.Status === 'PENDING' && can.approve && cur.canApproveHere && !mine
                ? `<button type="button" class="btn btn-sm btn-success py-0" data-wo="${w.WriteOffId}" data-ok="1">Approve</button> <button type="button" class="btn btn-sm btn-outline-danger py-0" data-wo="${w.WriteOffId}" data-ok="0">Reject</button>`
                : w.Status === 'PENDING' ? `<span class="small text-muted">${mine ? 'asked by you: another person approves' : cur.matrix ? 'approvers: Approval Matrix' : 'needs the approve permission'}</span>` : '';
            return `<tr><td class="text-end">${money(w.Amount)}</td><td>${esc(w.Reason)}</td><td>${esc(w.RequestedByName || '')}<div class="small text-muted">${Ipd.dt(w.RequestedAt)}</div></td>
                <td>${Tpa.pill(w.Status)}${w.DecidedByName ? `<div class="small text-muted">${esc(w.DecidedByName)} · ${Ipd.dt(w.DecidedAt)}${w.DecisionRemarks ? ' · ' + esc(w.DecisionRemarks) : ''}</div>` : ''}</td><td class="text-end text-nowrap">${act}</td></tr>`;
        }).join('');
        return card('Write-offs', `<table class="table table-sm ipd-table mb-0"><thead><tr><th class="text-end">Amount</th><th>Reason</th><th>Asked by</th><th>Status</th><th></th></tr></thead><tbody>${rowsH}</tbody></table>`);
    }

    function timeline() {
        const ev = cur.events || [];
        const names = { CREATED: 'Claim made', SUBMITTED: 'Submitted', QUERY: 'TPA query', QUERY_REPLY: 'Reply sent', NOTE: 'Note', SETTLEMENT: 'Settlement', SETTLEMENT_CANCEL: 'Settlement cancelled',
                        WRITEOFF_REQUEST: 'Write-off asked', WRITEOFF_APPROVED: 'Write-off approved', WRITEOFF_REJECTED: 'Write-off rejected', CANCELLED: 'Claim cancelled' };
        return card('Timeline', `<ul class="tpa-timeline">${ev.map(e => `<li class="e-${esc(e.EventType)}"><b>${esc(names[e.EventType] || e.EventType)}</b>${e.Amount != null ? ' · ' + money(e.Amount) : ''}${e.RefNo ? ' · ' + esc(e.RefNo) : ''}
            ${e.Remarks ? `<div>${esc(e.Remarks)}</div>` : ''}<div class="t">${Ipd.dt(e.EventAt)} · ${esc(e.CreatedByName || '')}</div></li>`).join('')}</ul>`);
    }

    function settleCheck(c) {
        const a = Number($('stAmt').value) || 0, t = Number($('stTds').value) || 0, d = Number($('stDis').value) || 0, tot = a + t + d;
        document.querySelectorAll('.st-dis').forEach(x => x.classList.toggle('d-none', !(d > 0)));
        const left = Math.round((c.Outstanding - tot) * 100) / 100;
        $('stCheck').innerHTML = tot > c.Outstanding + 0.001
            ? `<span class="text-danger">Received + TDS + disallowed ${money(tot)} is more than the outstanding ${money(c.Outstanding)}.</span>`
            : `Outstanding ${money(c.Outstanding)} − ${money(tot)} = <b>${money(left)}</b> ${left === 0 ? '<span class="text-success">(fully settled)</span>' : 'still due from the TPA'}`;
    }

    function wire(c) {
        $('cdSave')?.addEventListener('click', async () => {
            const r = await Ipd.post(url + 'UpdateClaim?id=' + c.ClaimId, { tpaClaimRef: $('cdRef').value.trim() || null, remarks: $('cdRem').value.trim() || null });
            if (!r.success) return Ipd.error(r.error); Ipd.toast('Saved'); after();
        });
        document.querySelectorAll('#cmBody .cl-tick').forEach(cb => cb.addEventListener('change', async () => {
            const r = await Ipd.post(url + 'Checklist', { claimId: c.ClaimId, docTypeId: Number(cb.closest('tr').dataset.doc), isDone: cb.checked });
            if (!r.success) { cb.checked = !cb.checked; return Ipd.error(r.error); }
            loadClaim();
        }));
        document.querySelectorAll('#cmBody .cl-up').forEach(inp => inp.addEventListener('change', async () => {
            const f = inp.files[0]; if (!f) return;
            const fd = new FormData(); fd.append('file', f); fd.append('claimId', c.ClaimId); fd.append('docTypeId', inp.closest('tr').dataset.doc);
            const r = await Ipd.postForm(url + 'UploadDocument?id=' + c.AdmissionId, fd);
            if (!r.success) return Ipd.error(r.error); Ipd.toast('Document uploaded'); loadClaim();
        }));
        $('sbGo')?.addEventListener('click', async () => {
            if (!await Ipd.confirm('Submit the claim?', `${esc(c.ClaimNo)} for ${money(c.ClaimAmount)} to ${esc(c.PayerName || 'the TPA')}.`, 'Submit')) return;
            const r = await Ipd.post(url + 'Submit?id=' + c.ClaimId, { submittedAt: $('sbAt').value, mode: $('sbMode').value, submissionRef: $('sbRef').value.trim() || null });
            if (!r.success) return Ipd.error(r.error); Ipd.toast('Claim submitted'); after();
        });
        document.querySelectorAll('#cmBody [data-ev]').forEach(b => b.addEventListener('click', async () => {
            const ev = b.dataset.ev, title = { QUERY: 'The TPA raised a query', QUERY_REPLY: 'Reply sent to the TPA', NOTE: 'Add a note' }[ev];
            const res = await Swal.fire({ title, width: 520, showCancelButton: true, confirmButtonText: 'Save', focusConfirm: false,
                html: `<div class="text-start small"><label class="form-label fw-semibold">When</label><input id="qeAt" type="datetime-local" class="form-control" value="${Ipd.local()}" max="${Ipd.local()}">
                       <label class="form-label fw-semibold mt-2">Reference (letter / mail / docket)</label><input id="qeRef" class="form-control" maxlength="100">
                       <label class="form-label fw-semibold mt-2">${ev === 'QUERY' ? 'What the TPA asked' : ev === 'QUERY_REPLY' ? 'What was sent' : 'Note'} <span class="text-danger">*</span></label><textarea id="qeRem" class="form-control" rows="3" maxlength="500"></textarea></div>`,
                preConfirm: () => { const rem = $('qeRem').value.trim(); if (!rem) { Swal.showValidationMessage('Enter the remarks.'); return false; } return { eventAt: $('qeAt').value, refNo: $('qeRef').value.trim() || null, remarks: rem }; } });
            if (!res.isConfirmed) return;
            const r = await Ipd.post(url + 'ClaimEvent?id=' + c.ClaimId, { eventType: ev, ...res.value });
            if (!r.success) return Ipd.error(r.error); Ipd.toast('Saved'); after();
        }));
        if ($('stGo')) {
            ['stAmt', 'stTds', 'stDis'].forEach(id => $(id).addEventListener('input', () => settleCheck(c)));
            $('stTds10').addEventListener('click', e => { e.preventDefault(); const a = Number($('stAmt').value) || 0; $('stTds').value = (Math.round(a / 9) ).toFixed(2); settleCheck(c); });
            settleCheck(c);
            $('stGo').addEventListener('click', async () => {
                const body = { settledOn: $('stOn').value, mode: $('stMode').value, utrNo: $('stUtr').value.trim() || null, amount: Number($('stAmt').value) || 0,
                               tdsAmount: Number($('stTds').value) || 0, disallowedAmount: Number($('stDis').value) || 0, disallowReason: $('stWhy').value.trim() || null,
                               disallowAction: Number($('stDis').value) > 0 ? $('stAct').value : null, remarks: $('stRem').value.trim() || null };
                if (body.amount + body.tdsAmount + body.disallowedAmount <= 0) return Ipd.error('Enter the amount received, TDS or the disallowed amount.');
                const html = `Received <b>${money(body.amount)}</b>, TDS <b>${money(body.tdsAmount)}</b>${body.disallowedAmount > 0 ? `, disallowed <b>${money(body.disallowedAmount)}</b> (${body.disallowAction === 'PATIENT' ? 'now payable by the patient' : 'write-off for approval'})` : ''}.<br><small class="text-muted">The receipt is posted to the bank and the TPA's ledger.</small>`;
                if (!await Ipd.confirm('Save the settlement?', html, 'Save')) return;
                const r = await Ipd.post(url + 'Settle?id=' + c.ClaimId, body);
                if (!r.success) return Ipd.error(r.error);
                Ipd.toast(`Settlement ${r.data.SettlementNo} saved`); after();
            });
        }
        document.querySelectorAll('#cmBody [data-cancel]').forEach(b => b.addEventListener('click', async () => {
            const reason = await Ipd.reason('Cancel this settlement?', 'Reason (the receipt and postings are reversed)'); if (!reason) return;
            const r = await Ipd.post(url + 'CancelSettlement?id=' + b.dataset.cancel, { reason });
            if (!r.success) return Ipd.error(r.error); Ipd.toast('Settlement cancelled'); after();
        }));
        document.querySelectorAll('#cmBody [data-wo]').forEach(b => b.addEventListener('click', async () => {
            const ok = b.dataset.ok === '1';
            let remarks = null;
            if (ok) { if (!await Ipd.confirm('Approve the write-off?', 'The amount is written off (expense) against the TPA\'s receivable.', 'Approve')) return; }
            else { remarks = await Ipd.reason('Reject the write-off?', 'Reason (the amount goes back to the outstanding, to follow up with the TPA)'); if (!remarks) return; }
            const r = await Ipd.post(url + 'DecideWriteOff?id=' + b.dataset.wo, { approve: ok, remarks });
            if (!r.success) return Ipd.error(r.error); Ipd.toast(ok ? 'Write-off approved' : 'Write-off rejected'); after();
        }));
    }

    ['fStatus', 'fTpa', 'fFrom', 'fTo'].forEach(id => $(id).addEventListener('change', load));
    let t; $('fQ').addEventListener('input', () => { clearTimeout(t); t = setTimeout(load, 350); });
    $('reload').addEventListener('click', load);
    loadLookups().catch(() => { }).finally(load);
})();
