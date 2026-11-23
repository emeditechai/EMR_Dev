/* Pharmacy > Sales > IPD Issue (SQLScripts/2475): the medicine indents of the wards - issue batches (FEFO) or close with a reason. */
(function () {
    'use strict';
    const P = window.PhIpd; if (!P) return;
    const E = Ipd.esc, $ = id => document.getElementById(id);
    const REASONS = [['NO_STOCK', 'Out of stock'], ['NOT_STOCKED', 'Not stocked / not available'], ['SUBSTITUTE', 'Substitute needed (ask the doctor)'],
                     ['DOCTOR_STOPPED', 'Stopped by the doctor'], ['DUPLICATE', 'Duplicate request'], ['OTHER', 'Other']];
    const qn = v => Number(v || 0), fq = v => Number(qn(v).toFixed(3));
    let selected = null, detail = null;

    const statusPill = s => ({
        PENDING: '<span class="ipd-pill warn">Pending</span>', PARTIAL: '<span class="ipd-pill info">Part issued</span>', COMPLETED: '<span class="ipd-pill ok">Completed</span>',
        CANCELLED: '<span class="ipd-pill muted">Cancelled</span>', ISSUED: '<span class="ipd-pill ok">Issued</span>', NOT_ISSUED: '<span class="ipd-pill alert">Not issued</span>',
        SHORT_CLOSED: '<span class="ipd-pill warn">Part issued, rest not</span>'
    }[s] || `<span class="ipd-pill muted">${E(s)}</span>`);
    const recvPill = s => ({
        PENDING: '<span class="ipd-pill warn">Awaiting ward</span>', RECEIVED: '<span class="ipd-pill ok">Received</span>',
        NOT_RECEIVED: '<span class="ipd-pill alert">Not received</span>', TAKEN_BACK: '<span class="ipd-pill muted">Taken back</span>'
    }[s] || '');
    const priPill = p => p === 'STAT' ? '<span class="ipd-pill alert">STAT</span>' : p === 'URGENT' ? '<span class="ipd-pill warn">Urgent</span>' : '';

    // ── board ────────────────────────────────────────────────────────────────────────────────────────────────
    async function loadBoard() {
        const qs = new URLSearchParams({ status: $('indStatus').value, q: $('indQ').value.trim(), from: $('indFrom').value, to: $('indTo').value });
        let d;
        try { d = await Ipd.get(P.base + 'Board?' + qs); } catch (e) { $('indRows').innerHTML = `<tr><td colspan="4" class="text-danger small">${E(e.message)}</td></tr>`; return; }
        const t = (d.tiles || [])[0] || {}, st = $('indStatus').value;
        const tile = (key, label, val, sub, cls) => `<div class="col-6 col-md-4 col-xl-2"><div class="ipd-tile ${cls} ind-tile ${st === key ? 'sel' : ''}" data-status="${key}">
            <div class="lbl">${label}</div><div class="val">${val ?? 0}</div><div class="sub">${sub}</div></div></div>`;
        $('indTiles').innerHTML = tile('PENDING', 'Pending', t.Pending, 'nothing issued yet', 'warn') + tile('PARTIAL', 'Part issued', t.Partial, 'lines still open', 'accent')
            + tile('OPEN', 'Urgent / STAT', t.UrgentOpen, 'open now', 'bad') + tile('NOT_RECEIVED', 'Not received', t.NotReceived, 'ward did not get it', 'bad')
            + tile('COMPLETED', 'Completed today', t.CompletedToday, 'all lines closed', 'good') + tile('ALL', 'Not issued today', t.NotIssuedToday, 'lines closed with a reason', 'warn');
        const rows = d.rows || [];
        $('indCount').textContent = rows.length || '';
        $('indRows').innerHTML = rows.length ? rows.map(r => `<tr class="ind-row pri-${E(r.Priority)} ${r.IndentId === selected ? 'sel' : ''}" data-id="${r.IndentId}">
            <td><div class="fw-semibold font-monospace small">${E(r.IndentNo)} ${priPill(r.Priority)}</div><div class="small text-muted">${Ipd.dt(r.IndentAt)}</div></td>
            <td><div class="fw-semibold">${E(r.PatientName)}</div><div class="small text-muted">${E(r.IpNo)} · ${E(r.BedNumber || 'no bed')}${r.WardName ? ' · ' + E(r.WardName) : ''}</div></td>
            <td class="text-center small"><span class="fw-semibold">${r.OpenLines}</span> open / ${r.Lines}${r.NotReceived ? `<div class="text-danger">${r.NotReceived} not received</div>` : ''}</td>
            <td>${statusPill(r.Status)}${!r.IsOpen || r.Billed ? '<div class="small text-danger mt-1">Not admitted / billed</div>' : ''}</td></tr>`).join('')
            : '<tr><td colspan="4" class="text-muted small">No indents for this filter.</td></tr>';
    }

    // ── detail: a line table; Issue / Not issue open a popup (batches nearest expiry first) ─────────────────────
    const isOpen = l => ['PENDING', 'PARTIAL'].includes(l.Status);
    const conv = l => qn(l.ConversionQty) > 1 ? qn(l.ConversionQty) : 1;
    const su = l => E(l.SaleUom || 'unit');
    const asked = l => l.QtyMode === 'P' && conv(l) > 1
        ? `${fq(l.QtyIn)} ${E(l.PurchaseUom || 'pack')}<div class="small text-muted">${fq(l.ReqQty)} ${su(l)}</div>` : `${fq(l.ReqQty)} <span class="small text-muted">${su(l)}</span>`;
    const inPacks = (l, units) => conv(l) > 1 && units > 0 ? ` <span class="text-muted">(= ${fq(units / conv(l))} ${E(l.PurchaseUom || 'pack')})</span>` : '';
    const reasonSelect = (id, val) => `<select id="${id}" class="form-select form-select-sm"><option value="">Reason…</option>${REASONS.map(r => `<option value="${r[0]}" ${val === r[0] ? 'selected' : ''}>${r[1]}</option>`).join('')}</select>`;

    async function batchesFor(l) {
        if (qn(l.Stock) <= 0) return [];
        try { return await Ipd.get(P.base + 'Batches?itemId=' + l.ItemId + '&storeId=' + detail.header[0].StoreId) || []; } catch { return []; }
    }
    const fefo = (batches, need) => batches.map(b => { const q = Math.min(need, qn(b.Stock)); need = fq(need - q); return fq(q); });

    async function openIndent(id) {
        selected = id;
        document.querySelectorAll('.ind-row').forEach(r => r.classList.toggle('sel', Number(r.dataset.id) === id));
        $('indDetail').innerHTML = '<div class="ind-detail-empty">Loading…</div>';
        try { detail = await Ipd.get(P.base + 'Detail?id=' + id); } catch (e) { $('indDetail').innerHTML = `<div class="alert alert-danger mb-0">${E(e.message)}</div>`; return; }
        if (!(detail.header || [])[0]) { $('indDetail').innerHTML = '<div class="alert alert-warning mb-0">The indent was not found.</div>'; return; }
        render();
    }

    function render() {
        const h = detail.header[0], lines = detail.lines || [], issues = detail.issues || [];
        const open = lines.filter(isOpen), canAct = P.can.issue, canIssue = canAct && h.CanIssue;
        const blocked = !h.CanIssue && open.length ? `<div class="alert alert-warning py-2 small mb-3"><i class="bi bi-lock me-1"></i>The patient is ${E((h.AdmissionStatus || '').replace('_', ' ').toLowerCase())}${h.Billed ? ' and the final bill is made' : ''}: nothing can be issued. Close the open lines with "Not issue".</div>` : '';
        const flags = l => `${l.ScheduleCode ? ` <span class="badge text-bg-light border">Sch ${E(l.ScheduleCode)}</span>` : ''}${l.IsHighAlert ? ' <span class="ipd-pill alert">High alert</span>' : ''}${l.IsLasa ? ' <span class="ipd-pill warn">LASA</span>' : ''}${l.IsColdChain ? ' <span class="ipd-pill info">Cold chain</span>' : ''}`;
        const why = l => l.Status === 'CANCELLED' ? `Cancelled by the ward: ${E(l.CancelReason || '')}`
            : l.NotIssueReason ? `${E(l.NotIssueReasonText || l.NotIssueReason)}${l.NotIssueRemarks ? ': ' + E(l.NotIssueRemarks) : ''} · ${E(l.NotIssuedBy || '')}` : '';
        $('indDetail').innerHTML = `
            <div class="d-flex justify-content-between flex-wrap gap-2 mb-3">
                <div><div class="h5 fw-bold mb-0">${E(h.IndentNo)} ${priPill(h.Priority)} ${statusPill(h.Status)}</div>
                    <div class="small text-muted">${Ipd.dt(h.IndentAt)} · raised by ${E(h.RaisedBy || '')} · ${E(h.StoreName || '')}${h.DoctorName ? ' · Dr ' + E(h.DoctorName) : ''}</div>
                    ${h.Remarks ? `<div class="small mt-1"><i class="bi bi-chat-left-text me-1"></i>${E(h.Remarks)}</div>` : ''}</div>
                <div class="text-end"><a class="fw-semibold" href="${P.patientBase}${h.AdmissionId}?tab=indent">${E(h.PatientName)}</a>
                    <div class="small text-muted">${E(h.PatientCode)} · ${E(h.AgeText || '')} ${E(h.Gender || '')} · ${E(Ipd.payer(h.PayerType))}</div>
                    <div class="small text-muted">${E(h.IpNo)} · ${E(h.BedNumber || 'no bed')}${h.WardName ? ' · ' + E(h.WardName) : ''}</div></div></div>
            ${blocked}
            <div class="table-responsive"><table class="table ipd-table align-middle mb-0">
                <thead><tr><th>Medicine</th><th class="text-end">Asked</th><th class="text-end">Issued</th><th class="text-end">Open</th><th class="text-end">Stock</th><th>Status</th><th></th></tr></thead><tbody>
                ${lines.map(l => `<tr class="${isOpen(l) ? '' : 'text-muted'}">
                    <td><div class="fw-semibold ${isOpen(l) ? '' : 'text-body-secondary'}">${E(l.ItemName)}${flags(l)}</div>
                        <div class="small text-muted">${E(l.ItemCode || '')}${l.PackSize ? ' · ' + E(l.PackSize) : ''}${l.Remarks ? ' · <i>' + E(l.Remarks) + '</i>' : ''}${l.ReIndentOfNo ? ' · re-indent of ' + E(l.ReIndentOfNo) : ''}</div>
                        ${why(l) ? `<div class="small text-danger">${why(l)}</div>` : ''}</td>
                    <td class="text-end ind-qty">${asked(l)}</td>
                    <td class="text-end ind-qty">${qn(l.IssuedQty) ? fq(l.IssuedQty) : '—'}${qn(l.NotIssuedQty) ? `<div class="small text-danger">not ${fq(l.NotIssuedQty)}</div>` : ''}</td>
                    <td class="text-end ind-qty fw-semibold">${isOpen(l) ? fq(l.OpenQty) : '—'}</td>
                    <td class="text-end ind-qty ${isOpen(l) && qn(l.Stock) < qn(l.OpenQty) ? 'text-danger' : ''}">${isOpen(l) ? fq(l.Stock) : ''}</td>
                    <td>${statusPill(l.Status)}</td>
                    <td class="text-end text-nowrap">${isOpen(l) && canAct ? `
                        ${canIssue && qn(l.Stock) > 0 ? `<button type="button" class="btn btn-sm btn-success l-issue" data-line="${l.LineId}"><i class="bi bi-box-arrow-right me-1"></i>Issue</button>` : ''}
                        <button type="button" class="btn btn-sm btn-outline-danger l-not" data-line="${l.LineId}" title="Close as not issued"><i class="bi bi-slash-circle me-1"></i>Not issue</button>` : ''}</td></tr>`).join('')}
            </tbody></table></div>
            ${canIssue && open.some(l => qn(l.Stock) > 0) && open.length > 1 ? `<div class="d-flex justify-content-end mt-2"><button type="button" class="btn btn-outline-success btn-sm" id="indIssueAll"><i class="bi bi-lightning-charge me-1"></i>Issue all available (nearest expiry first)</button></div>` : ''}
            ${open.length && !canAct ? '<div class="small text-muted mt-2">Issuing needs the IPD Issue › Issue permission.</div>' : ''}
            <h6 class="fw-bold mt-4 mb-2">Issued against this indent</h6>
            <div class="table-responsive"><table class="table table-sm ipd-table mb-0"><thead><tr><th>Issue</th><th>Medicine / batch</th><th class="text-end">Qty</th><th class="text-end">Amount</th><th>Ward</th><th></th></tr></thead><tbody>
            ${issues.length ? issues.map(r => `<tr><td><div class="font-monospace small fw-semibold">${E(r.IssueNo)}</div><div class="small text-muted">${Ipd.dt(r.IssueAt)} · ${E(r.IssuedBy || '')}</div></td>
                <td>${E(r.ItemName)} <span class="small text-muted">batch ${E(r.BatchNo)} · exp ${Ipd.date(r.ExpiryDate)}</span></td>
                <td class="text-end ind-qty">${fq(r.Qty)}${qn(r.ReturnedQty) ? `<div class="small text-muted">returned ${fq(r.ReturnedQty)}</div>` : ''}</td><td class="text-end">${Ipd.num(r.Amount)}</td>
                <td>${recvPill(r.ReceiveStatus)}${r.ReceivedBy ? `<div class="small text-muted">${E(r.ReceivedBy)} ${Ipd.dt(r.ReceivedAt)}</div>` : ''}${r.ReceiveRemarks ? `<div class="small">${E(r.ReceiveRemarks)}</div>` : ''}</td>
                <td class="text-end">${r.CanTakeBack && P.can.takeBack ? `<button type="button" class="btn btn-sm btn-outline-danger t-back" data-line="${r.LineId}" data-name="${E(r.ItemName)}" title="Take back to stock"><i class="bi bi-arrow-return-left me-1"></i>Take back</button>` : ''}</td></tr>`).join('')
                : '<tr><td colspan="6" class="text-muted small">Nothing issued yet.</td></tr>'}
            </tbody></table></div>`;
    }

    async function process(body) {
        const r = await Ipd.post(P.base + 'Process?id=' + selected, body);
        if (!r.success) { Swal.showValidationMessage(r.error || 'Not saved.'); return false; }
        return r.data || { };
    }
    const after = async (data, fallback) => { Ipd.toast(data && data.IssueNo ? `Issued ${data.IssueNo}: ${Ipd.money(data.Total)}` : fallback); await openIndent(selected); loadBoard(); };

    // issue one line: batch popup
    async function issueLine(l) {
        const batches = await batchesFor(l);
        if (!batches.length) return Ipd.error('No saleable batch of this medicine in the store (expired, blocked or out of stock).');
        const open = qn(l.OpenQty), init = fefo(batches, open);
        const res = await Swal.fire({
            title: 'Issue ' + E(l.ItemName), width: 760, showCancelButton: true, confirmButtonText: '<i class="bi bi-box-arrow-right me-1"></i>Issue', confirmButtonColor: '#16a34a',
            showLoaderOnConfirm: true, focusConfirm: false,
            html: `<div class="text-start">
                <div class="d-flex flex-wrap gap-3 small mb-2"><span>Asked <b>${l.QtyMode === 'P' && conv(l) > 1 ? fq(l.QtyIn) + ' ' + E(l.PurchaseUom || 'pack') + ' (' + fq(l.ReqQty) + ' ' + su(l) + ')' : fq(l.ReqQty) + ' ' + su(l)}</b></span>
                    <span>Issued <b>${fq(l.IssuedQty)}</b></span><span>Open <b>${fq(open)} ${su(l)}</b></span><span>In store <b>${fq(l.Stock)} ${su(l)}</b></span></div>
                ${l.Remarks ? `<div class="small mb-2"><i class="bi bi-chat-left-text me-1"></i>${E(l.Remarks)}</div>` : ''}
                <table class="table table-sm align-middle mb-2"><thead><tr><th>Batch</th><th>Expiry</th><th class="text-end">Stock</th><th class="text-end">MRP / ${su(l)}</th><th style="width:120px">Issue (${su(l)})</th></tr></thead><tbody>
                ${batches.map((b, i) => `<tr><td class="font-monospace">${E(b.BatchNo)}${i === 0 ? ' <span class="ipd-pill info">FEFO</span>' : ''}</td><td>${Ipd.date(b.ExpiryDate)}</td><td class="text-end">${fq(b.Stock)}</td>
                    <td class="text-end">${Ipd.num(b.UnitMrp)}</td><td><input type="number" class="form-control form-control-sm text-end sw-q" data-i="${i}" min="0" max="${fq(b.Stock)}" step="any" value="${init[i]}" /></td></tr>`).join('')}
                </tbody></table>
                <div class="d-flex justify-content-between align-items-center small"><span id="swTot"></span><button type="button" class="btn btn-link btn-sm p-0" id="swFefo">Reset to nearest expiry</button></div>
                <div id="swRest" class="border rounded p-2 mt-2 d-none"><div class="form-check mb-1"><input class="form-check-input" type="checkbox" id="swClose" />
                    <label class="form-check-label small" for="swClose">Close the rest (<span id="swRestQty"></span> ${su(l)}) as not issued</label></div>
                    <div class="d-flex gap-2">${reasonSelect('swReason', '')}<input id="swRem" class="form-control form-control-sm" maxlength="300" placeholder="Remarks" /></div>
                    <div class="small text-muted mt-1">Leave it unticked to keep the rest open for a later issue.</div></div>
                <input id="swNote" class="form-control form-control-sm mt-2" maxlength="300" placeholder="Remarks for the issue (optional)" /></div>`,
            didOpen: () => {
                const pop = Swal.getPopup(), qs = () => [...pop.querySelectorAll('.sw-q')];
                const upd = () => {
                    const tot = fq(qs().reduce((s, x) => s + qn(x.value), 0)), rest = fq(open - tot);
                    pop.querySelector('#swTot').innerHTML = `Issuing <b>${tot}</b> of ${fq(open)} ${su(l)}${inPacks(l, tot)}`;
                    pop.querySelector('#swRest').classList.toggle('d-none', !(rest > 0 && tot > 0));
                    pop.querySelector('#swRestQty').textContent = rest;
                };
                pop.addEventListener('input', upd);
                pop.querySelector('#swFefo').addEventListener('click', () => { qs().forEach((x, i) => { x.value = init[i]; }); upd(); });
                upd();
            },
            preConfirm: async () => {
                const pop = Swal.getPopup(), issue = [];
                let tot = 0;
                for (const x of pop.querySelectorAll('.sw-q')) {
                    const b = batches[Number(x.dataset.i)], q = qn(x.value);
                    if (q < 0) { Swal.showValidationMessage('Quantities cannot be negative.'); return false; }
                    if (q > qn(b.Stock)) { Swal.showValidationMessage(`Only ${fq(b.Stock)} in batch ${b.BatchNo}.`); return false; }
                    if (q > 0) { issue.push({ indentLineId: l.LineId, batchId: b.BatchId, qty: fq(q) }); tot += q; }
                }
                if (!issue.length) { Swal.showValidationMessage('Enter the quantity to issue.'); return false; }
                if (fq(tot) > fq(open)) { Swal.showValidationMessage(`At most ${fq(open)} ${l.SaleUom || ''} can be issued.`); return false; }
                const notIssue = [];
                if (fq(tot) < fq(open) && pop.querySelector('#swClose').checked) {
                    const reason = pop.querySelector('#swReason').value, rem = pop.querySelector('#swRem').value.trim();
                    if (!reason) { Swal.showValidationMessage('Choose the reason the rest is not issued.'); return false; }
                    if (reason === 'OTHER' && !rem) { Swal.showValidationMessage('Write the reason ("Other").'); return false; }
                    notIssue.push({ indentLineId: l.LineId, reason, remarks: rem || null });
                }
                return process({ issue, notIssue, storeId: detail.header[0].StoreId, remarks: pop.querySelector('#swNote').value.trim() || null });
            }
        });
        if (res.isConfirmed) await after(res.value, 'Saved');
    }

    // close one line as not issued
    async function notIssueLine(l) {
        const res = await Swal.fire({
            title: 'Not issue ' + E(l.ItemName), showCancelButton: true, confirmButtonText: 'Close as not issued', confirmButtonColor: '#dc2626', showLoaderOnConfirm: true,
            html: `<div class="text-start"><div class="small mb-2">${fq(l.OpenQty)} ${su(l)} open${qn(l.Stock) <= 0 ? ' · <span class="text-danger">no stock in the store</span>' : ''}. The ward sees the reason and can re-indent.</div>
                ${reasonSelect('swReason', qn(l.Stock) <= 0 ? 'NO_STOCK' : '')}<input id="swRem" class="form-control form-control-sm mt-2" maxlength="300" placeholder="Remarks (e.g. expected tomorrow)" /></div>`,
            preConfirm: () => {
                const pop = Swal.getPopup(), reason = pop.querySelector('#swReason').value, rem = pop.querySelector('#swRem').value.trim();
                if (!reason) { Swal.showValidationMessage('Choose the reason.'); return false; }
                if (reason === 'OTHER' && !rem) { Swal.showValidationMessage('Write the reason ("Other").'); return false; }
                return process({ issue: [], notIssue: [{ indentLineId: l.LineId, reason, remarks: rem || null }], storeId: detail.header[0].StoreId });
            }
        });
        if (res.isConfirmed) await after(res.value, 'Closed as not issued');
    }

    // every open line with stock, nearest expiry first; the rest stays open
    async function issueAll() {
        const open = (detail.lines || []).filter(l => isOpen(l) && qn(l.Stock) > 0);
        const plan = [];
        for (const l of open) {
            const batches = await batchesFor(l), q = fefo(batches, qn(l.OpenQty));
            batches.forEach((b, i) => { if (q[i] > 0) plan.push({ l, b, qty: q[i] }); });
        }
        if (!plan.length) return Ipd.error('Nothing can be issued from the store.');
        const res = await Swal.fire({
            title: 'Issue all available?', width: 720, showCancelButton: true, confirmButtonText: 'Issue', confirmButtonColor: '#16a34a', showLoaderOnConfirm: true,
            html: `<table class="table table-sm text-start mb-1"><thead><tr><th>Medicine</th><th>Batch</th><th>Expiry</th><th class="text-end">Qty</th></tr></thead><tbody>
                ${plan.map(p => `<tr><td>${E(p.l.ItemName)}</td><td class="font-monospace">${E(p.b.BatchNo)}</td><td>${Ipd.date(p.b.ExpiryDate)}</td><td class="text-end">${fq(p.qty)} ${su(p.l)}</td></tr>`).join('')}
                </tbody></table><div class="small text-muted text-start">Lines short of stock stay open for a later issue or "Not issue".</div>`,
            preConfirm: () => process({ issue: plan.map(p => ({ indentLineId: p.l.LineId, batchId: p.b.BatchId, qty: p.qty })), notIssue: [], storeId: detail.header[0].StoreId })
        });
        if (res.isConfirmed) await after(res.value, 'Issued');
    }

    $('indDetail').addEventListener('click', async e => {
        const line = id => (detail.lines || []).find(x => x.LineId === Number(id));
        const i = e.target.closest('.l-issue'); if (i) return issueLine(line(i.dataset.line));
        const n = e.target.closest('.l-not'); if (n) return notIssueLine(line(n.dataset.line));
        if (e.target.closest('#indIssueAll')) return issueAll();
        const t = e.target.closest('.t-back'); if (!t) return;
        const remarks = await Ipd.reason(`Take back ${t.dataset.name} to stock?`, 'Remarks (e.g. found in the pharmacy, never sent)');
        if (!remarks) return;
        const r = await Ipd.post(P.base + 'TakeBack?lineId=' + t.dataset.line, { remarks });
        if (!r.success) return Ipd.error(r.error);
        Ipd.toast('Taken back ' + (r.data.IssueNo || '')); openIndent(selected); loadBoard();
    });

    $('indRows').addEventListener('click', e => { const r = e.target.closest('.ind-row'); if (r) openIndent(Number(r.dataset.id)); });
    $('indTiles').addEventListener('click', e => { const t = e.target.closest('.ind-tile'); if (!t) return; $('indStatus').value = t.dataset.status; loadBoard(); });
    let qt; $('indQ').addEventListener('input', () => { clearTimeout(qt); qt = setTimeout(loadBoard, 300); });
    ['indStatus', 'indFrom', 'indTo'].forEach(id => $(id).addEventListener('change', loadBoard));
    $('indRefresh').addEventListener('click', () => { loadBoard(); if (selected) openIndent(selected); });
    loadBoard();
    setInterval(() => { if (!document.hidden) loadBoard(); }, 60000);   // new indents from the wards
})();
