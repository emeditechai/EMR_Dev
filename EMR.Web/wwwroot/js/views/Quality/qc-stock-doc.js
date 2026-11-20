/* Quality & Compliance > Stock Management - the document screens (SQLScripts/2498-2500).
   One page for OPN (opening stock), PO, GRN, PRET (purchase return), IND (indent), ISS (issue / transfer), ADJ (adjustment)
   and CNT (physical count). window.QcStockDoc = { docType, title, controller, perms, lookups, me, open }.
   Quantities in stock are consumption units; a line may be entered in packs (UnitMode P) or units (C).
   Every rule is checked again by the stored procedures; this page only guides. */
(function () {
    'use strict';
    const C = window.QcStockDoc || {};
    const L = C.lookups || {};
    const P = C.perms || {};
    const T = C.docType;
    const base = '/' + C.controller + '/';
    const url = a => base + a;
    const esc = QC.esc, qty = QC.qty, money = QC.money;
    const today = () => new Date().toISOString().slice(0, 10);
    const n = v => (v === null || v === undefined || v === '' || isNaN(+v)) ? 0 : +v;
    const d10 = s => s ? String(s).slice(0, 10) : '';

    const RET_REASONS = [{ Id: 'DAMAGED', Name: 'Damaged / broken in transit' }, { Id: 'QUALITY', Name: 'Failed quality / lot rejected' },
        { Id: 'EXPIRED', Name: 'Expired' }, { Id: 'SHORTEXP', Name: 'Short expiry' }, { Id: 'WRONG', Name: 'Wrong item / not ordered' },
        { Id: 'EXCESS', Name: 'Excess supply' }, { Id: 'RECALL', Name: 'Manufacturer recall' }];

    // ── the document types ────────────────────────────────────────────────────────────────────────────────────
    const TYPES = {
        OPN: { icon: 'bi-box-arrow-in-down', sub: 'Stock already on the shelf when tracking starts - lot, expiry and cost per store. Posted once, with an opening journal in Accounts.',
               head: ['store', 'date', 'remarks'], lotEntry: true, unitMode: true, rate: 'Cost', defaultMode: 'P',
               primary: { action: 'Post', label: 'Save & post', perm: 'POST', ask: 'Post this opening stock? Stock and accounts are updated; it cannot be edited afterwards.' } },
        PO: { icon: 'bi-file-earmark-text', sub: 'Order reagents and consumables. Approved orders are received through Goods Receipt; part receipts keep the order open.',
              head: ['store', 'supplier', 'date', 'expected', 'terms', 'remarks'], packOnly: true, rate: 'Rate / pack', disc: true, gst: true, amounts: true, received: true,
              primary: { action: 'Submit', label: 'Save & submit', perm: 'SUBMIT' } },
        GRN: { icon: 'bi-truck', sub: 'Receive supplier goods against the bill: batch number and expiry are required on every line. Reagent, kit and control lots wait in quarantine until accepted.',
               head: ['supplier', 'po', 'store', 'invNo', 'invDate', 'interstate', 'date', 'other', 'remarks'], lotEntry: true, batchRequired: true, packOnly: true, free: true,
               rate: 'Rate / pack', disc: true, gst: true, amounts: true,
               primary: { action: 'Post', label: 'Save & post', perm: 'POST', ask: 'Post this receipt? Stock, lots and the purchase voucher are created; it cannot be edited afterwards.' } },
        PRET: { icon: 'bi-arrow-return-left', sub: 'Return damaged, rejected or excess stock to the supplier (debit note in Accounts).',
                head: ['store', 'supplier', 'grn', 'retReason', 'date', 'remarks'], lotPick: 'OUT', unitMode: true, rate: 'Rate', gst: true, amounts: true, defaultMode: 'P',
                primary: { action: 'Post', label: 'Save & post', perm: 'POST', ask: 'Post this return? Stock goes out and a debit note is posted.' } },
        IND: { icon: 'bi-clipboard-plus', sub: 'A bench or branch asks another store for stock. The supplying store issues against it.',
               head: ['store', 'toStore', 'priority', 'expected', 'remarks'], unitMode: true, remarks: true, defaultMode: 'P', received: true,
               primary: { action: 'Submit', label: 'Save & submit', perm: 'SUBMIT' } },
        ISS: { icon: 'bi-arrow-left-right', sub: 'Move stock to a bench store or another branch, lot by lot (first expiry, first out). The receiving store confirms receipt.',
               head: ['store', 'toStore', 'indent', 'date', 'remarks'], lotPick: 'ISSUE', fefo: true, unitMode: true, defaultMode: 'C',
               primary: { action: 'Dispatch', label: 'Save & dispatch', perm: 'DISPATCH', ask: 'Dispatch this issue? The stock leaves the store now.' } },
        ADJ: { icon: 'bi-sliders', sub: 'QC and calibration use, expiry, breakage, spillage or stock found - with a reason, approved by another user.',
               head: ['store', 'reason', 'date', 'remarks'], lotPick: 'OUT', unitMode: true, remarks: true, defaultMode: 'C',
               primary: { action: 'Submit', label: 'Save & submit', perm: 'SUBMIT' } },
        CNT: { icon: 'bi-list-check', sub: 'Count each lot on the shelf against the frozen book stock; differences are posted when approved.' }
    };
    const D = TYPES[T];
    const STATUS = {
        OPN: ['DRAFT', 'POSTED', 'CANCELLED'], PO: ['DRAFT', 'SUBMITTED', 'APPROVED', 'PARTIAL', 'CLOSED', 'REJECTED', 'CANCELLED'],
        GRN: ['DRAFT', 'POSTED', 'CANCELLED'], PRET: ['DRAFT', 'POSTED', 'CANCELLED'], IND: ['DRAFT', 'SUBMITTED', 'PARTIAL', 'CLOSED', 'REJECTED', 'CANCELLED'],
        ISS: ['DRAFT', 'INTRANSIT', 'RECEIVED', 'CANCELLED'], ADJ: ['DRAFT', 'SUBMITTED', 'POSTED', 'REJECTED', 'CANCELLED'], CNT: ['DRAFT', 'SUBMITTED', 'POSTED', 'REJECTED', 'CANCELLED']
    };
    const LABEL = { DRAFT: 'Draft', SUBMITTED: 'Submitted', APPROVED: 'Approved', PARTIAL: 'Part done', CLOSED: 'Closed', POSTED: 'Posted', REJECTED: 'Rejected',
        CANCELLED: 'Cancelled', INTRANSIT: 'In transit', RECEIVED: 'Received', QUARANTINE: 'Quarantine', ACCEPTED: 'Accepted', BLOCKED: 'Blocked', OPEN: 'Open' };
    const badge = s => `<span class="qs-badge qs-st-${esc(s)}">${esc(LABEL[s] || s)}</span>`;

    const stores = L.stores || [], mine = stores.filter(s => s.IsMine), items = L.items || [], suppliers = L.suppliers || [];
    const item = id => items.find(i => i.ItemId === +id);
    const store = id => stores.find(s => s.StoreId === +id);
    const storeLabel = s => s ? `${s.StoreName}${s.IsMine ? '' : ' (' + s.BranchName + ')'}` : '';
    const reasonName = code => ((L.reasons || []).find(r => r.Id === code) || RET_REASONS.find(r => r.Id === code) || {}).Name || code || '';

    // ── page header ───────────────────────────────────────────────────────────────────────────────────────────
    document.getElementById('qsIcon').classList.add(D.icon);
    document.getElementById('qsSub').textContent = D.sub;
    if (L.error) { const e = document.getElementById('qsLookupError'); e.textContent = 'Lists could not be loaded: ' + L.error; e.classList.remove('d-none'); }
    const top = document.getElementById('qsTopButtons');
    if (T === 'CNT') { if (P.ADD) top.insertAdjacentHTML('beforeend', '<button class="btn btn-primary px-3 shadow-sm" id="btnNew"><i class="bi bi-list-check me-1"></i>Start count</button>'); }
    else if (P.ADD) top.insertAdjacentHTML('beforeend', `<button class="btn btn-primary px-3 shadow-sm" id="btnNew"><i class="bi bi-plus-lg me-1"></i>New ${esc(newLabel())}</button>`);
    function newLabel() { return { OPN: 'opening stock', PO: 'purchase order', GRN: 'receipt', PRET: 'return', IND: 'indent', ISS: 'issue', ADJ: 'adjustment' }[T] || 'document'; }

    let scope = 'OUT';
    if (T === 'IND' || T === 'ISS') {
        const sc = document.getElementById('qsScope');
        sc.classList.remove('d-none');
        const tabs = T === 'IND' ? [['OUT', 'My indents'], ['IN', 'Indents to my stores']] : [['OUT', 'Sent from this branch'], ['IN', 'To receive / received']];
        sc.innerHTML = tabs.map(([k, l], i) => `<li class="nav-item"><a href="#" class="nav-link ${i === 0 ? 'active' : ''}" data-scope="${k}">${l}</a></li>`).join('');
        sc.addEventListener('click', e => { const a = e.target.closest('[data-scope]'); if (!a) return; e.preventDefault();
            sc.querySelectorAll('.nav-link').forEach(x => x.classList.toggle('active', x === a)); scope = a.dataset.scope; load(); });
    }
    document.getElementById('fStatus').innerHTML = '<option value="">All</option><option value="OPEN" selected>Open</option>' + STATUS[T].map(s => `<option value="${s}">${LABEL[s]}</option>`).join('');

    // ── list ──────────────────────────────────────────────────────────────────────────────────────────────────
    const COLS = {
        OPN: [['No', r => mono(r.DocNo)], ['Date', r => QC.date(r.DocDate)], ['Store', r => esc(r.StoreName)], ['Lines', r => r.LineCount, 'c'], ['Value', r => money(r.StockValue), 'r']],
        PO: [['No', r => mono(r.DocNo)], ['Date', r => QC.date(r.DocDate)], ['Supplier', r => esc(r.SupplierName)], ['Expected', r => QC.date(r.ExpectedDate)], ['Lines', r => r.LineCount, 'c'], ['Amount', r => money(r.NetAmount), 'r']],
        GRN: [['No', r => mono(r.DocNo)], ['Date', r => QC.date(r.DocDate)], ['Supplier', r => esc(r.SupplierName)], ['Bill', r => esc(r.SupplierInvNo || '') + (r.SupplierInvDate ? '<div class="small text-muted">' + QC.date(r.SupplierInvDate) + '</div>' : '')],
              ['PO', r => esc(r.RefDocNo || '—')], ['Amount', r => money(r.NetAmount), 'r']],
        PRET: [['No', r => mono(r.DocNo)], ['Date', r => QC.date(r.DocDate)], ['Supplier', r => esc(r.SupplierName)], ['Against', r => esc(r.RefDocNo || '—')], ['Amount', r => money(r.NetAmount), 'r']],
        IND: [['No', r => mono(r.DocNo)], ['Date', r => QC.date(r.DocDate)], ['From (asking)', r => esc(r.StoreName) + (scope === 'IN' ? '<div class="small text-muted">' + esc(r.StoreBranch || '') + '</div>' : '')],
              ['To (supplying)', r => esc(r.ToStoreName) + '<div class="small text-muted">' + esc(r.ToBranchName || '') + '</div>'], ['Priority', r => r.Priority === 'Urgent' ? '<span class="badge bg-danger">Urgent</span>' : esc(r.Priority || '')], ['Lines', r => r.LineCount, 'c']],
        ISS: [['No', r => mono(r.DocNo)], ['Date', r => QC.date(r.DocDate)], ['From', r => esc(r.StoreName) + '<div class="small text-muted">' + esc(r.StoreBranch || '') + '</div>'],
              ['To', r => esc(r.ToStoreName) + '<div class="small text-muted">' + esc(r.ToBranchName || '') + '</div>'], ['Indent', r => esc(r.RefDocNo || '—')], ['Value', r => money(r.StockValue), 'r']],
        ADJ: [['No', r => mono(r.DocNo)], ['Date', r => QC.date(r.DocDate)], ['Store', r => esc(r.StoreName)], ['Reason', r => esc(r.ReasonName || '')], ['Lines', r => r.LineCount, 'c'], ['Value', r => r.StockValue == null ? '—' : money(r.StockValue), 'r']],
        CNT: [['No', r => mono(r.DocNo)], ['Date', r => QC.date(r.DocDate)], ['Store', r => esc(r.StoreName)], ['Lots', r => r.LineCount, 'c'], ['Difference value', r => r.StockValue == null ? '—' : money(r.StockValue), 'r']]
    }[T];
    function mono(s) { return `<span class="font-monospace small">${esc(s)}</span>`; }
    document.getElementById('qsHead').innerHTML = COLS.map(c => `<th class="${c[2] === 'r' ? 'text-end' : c[2] === 'c' ? 'text-center' : ''}">${c[0]}</th>`).join('') +
        '<th>Status</th><th>By</th><th class="text-end pe-3"></th>';

    let rows = [];
    async function load() {
        const tb = document.getElementById('qsRows'), span = COLS.length + 3;
        tb.innerHTML = `<tr><td colspan="${span}" class="text-center text-muted py-4">Loading...</td></tr>`;
        const r = await QC.get(url('List'), { status: document.getElementById('fStatus').value, from: document.getElementById('fFrom').value, to: document.getElementById('fTo').value,
            search: document.getElementById('fSearch').value, scope });
        if (!r.success) { tb.innerHTML = `<tr><td colspan="${span}" class="text-danger text-center py-4">${esc(r.message)}</td></tr>`; return; }
        rows = r.data || [];
        tb.innerHTML = rows.length ? rows.map(r => `<tr class="act-open" role="button" data-id="${r.DocId}">
            ${COLS.map(c => `<td class="${c[2] === 'r' ? 'text-end' : c[2] === 'c' ? 'text-center' : ''}">${c[1](r) ?? ''}</td>`).join('')}
            <td>${badge(r.Status)}${r.RejectReason && r.Status === 'REJECTED' ? `<div class="small text-danger">${esc(r.RejectReason)}</div>` : ''}</td>
            <td class="small">${esc(r.CreatedByName || '')}<div class="text-muted">${QC.date(r.CreatedOn)}</div></td>
            <td class="text-end pe-3 text-nowrap"><button class="btn btn-sm btn-outline-primary" title="Open"><i class="bi bi-eye"></i></button></td></tr>`).join('')
            : `<tr><td colspan="${span}" class="text-center text-muted py-4">Nothing here for these filters.</td></tr>`;
    }
    document.getElementById('btnFilter').addEventListener('click', load);
    document.getElementById('fSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    document.getElementById('qsRows').addEventListener('click', e => { const tr = e.target.closest('.act-open'); if (tr) view(+tr.dataset.id); });

    // ── editor ────────────────────────────────────────────────────────────────────────────────────────────────
    const edModal = new bootstrap.Modal(document.getElementById('edModal'));
    let ed = null;   // { DocId, head:{}, lines:[] }

    function headField(k) {
        const h = ed.head, col = (w, html) => `<div class="col-md-${w}">${html}</div>`;
        const sel = (id, label, opts, req, extra) => col(extra || 3, `<label class="form-label small fw-semibold" for="${id}">${label}${req ? ' <span class="text-danger">*</span>' : ''}</label><select class="form-select" id="${id}">${opts}</select>`);
        const inp = (id, label, type, val, w, attrs) => col(w || 3, `<label class="form-label small fw-semibold" for="${id}">${label}</label><input type="${type}" class="form-control" id="${id}" value="${esc(val ?? '')}" ${attrs || ''}/>`);
        const storeOpts = (list, v, ph) => `<option value="">${ph}</option>` + list.map(s => `<option value="${s.StoreId}" ${+v === s.StoreId ? 'selected' : ''}>${esc(storeLabel(s))}${s.StoreType === 'Bench' ? ' · bench' : ''}</option>`).join('');
        switch (k) {
            case 'store': return sel('hStore', { IND: 'Requesting store', ISS: 'From store' }[T] || 'Store', storeOpts(mine, h.StoreId, '-- Store --'), true);
            case 'toStore': return sel('hToStore', T === 'IND' ? 'Ask from store' : 'To store', storeOpts(stores.filter(s => s.StoreId !== +h.StoreId), h.ToStoreId, '-- Store --'), true);
            case 'supplier': return sel('hSupplier', 'Supplier', '<option value="">-- Supplier --</option>' + suppliers.map(s => `<option value="${s.SupplierId}" ${+h.SupplierId === s.SupplierId ? 'selected' : ''}>${esc(s.SupplierName)}${s.IsApproved ? '' : ' (not approved)'}</option>`).join(''), true, 4);
            case 'po': return sel('hPo', 'Against purchase order', '<option value="">Direct receipt (no PO)</option>', false);
            case 'grn': return sel('hGrn', 'Against receipt', '<option value="">-- optional --</option>', false);
            case 'indent': return sel('hIndent', 'Against indent', '<option value="">Direct issue (no indent)</option>', false);
            case 'reason': return sel('hReason', 'Reason', '<option value="">-- Reason --</option>' + (L.reasons || []).map(r => `<option value="${r.Id}" ${h.ReasonCode === r.Id ? 'selected' : ''}>${r.Direction > 0 ? '+ ' : '- '}${esc(r.Name)}</option>`).join(''), true, 4);
            case 'retReason': return sel('hReason', 'Reason', '<option value="">-- Reason --</option>' + RET_REASONS.map(r => `<option value="${r.Id}" ${h.ReasonCode === r.Id ? 'selected' : ''}>${esc(r.Name)}</option>`).join(''), false);
            case 'priority': return sel('hPriority', 'Priority', ['Normal', 'Urgent'].map(p => `<option ${h.Priority === p ? 'selected' : ''}>${p}</option>`).join(''), false, 2);
            case 'date': return inp('hDate', 'Date', 'date', d10(h.DocDate) || today(), 2, `max="${today()}"`);
            case 'expected': return inp('hExpected', T === 'IND' ? 'Needed by' : 'Expected delivery', 'date', d10(h.ExpectedDate), 2);
            case 'invNo': return inp('hInvNo', 'Supplier bill no <span class="text-danger">*</span>', 'text', h.SupplierInvNo, 2, 'maxlength="50"');
            case 'invDate': return inp('hInvDate', 'Bill date', 'date', d10(h.SupplierInvDate), 2, `max="${today()}"`);
            case 'other': return inp('hOther', 'Freight / other (₹)', 'number', h.OtherCharges || '', 2, 'step="0.01" min="0"');
            case 'interstate': return col(2, `<label class="form-label small fw-semibold d-block">Tax</label><div class="form-check form-switch mt-2"><input class="form-check-input" type="checkbox" id="hIgst" ${h.IsInterState ? 'checked' : ''}/><label class="form-check-label" for="hIgst">Inter-state (IGST)</label></div>`);
            case 'terms': return inp('hTerms', 'Terms (delivery, payment)', 'text', h.Terms, 6, 'maxlength="1000"');
            case 'remarks': return inp('hRemarks', 'Remarks', 'text', h.Remarks, 6, 'maxlength="1000"');
        }
        return '';
    }

    function readHead() {
        const v = id => { const el = document.getElementById(id); return el ? (el.type === 'checkbox' ? el.checked : el.value.trim()) : undefined; };
        const h = ed.head;
        if (v('hStore') !== undefined) h.StoreId = v('hStore') ? +v('hStore') : null;
        if (v('hToStore') !== undefined) h.ToStoreId = v('hToStore') ? +v('hToStore') : null;
        if (v('hSupplier') !== undefined) h.SupplierId = v('hSupplier') ? +v('hSupplier') : null;
        if (v('hPo') !== undefined) h.RefDocId = v('hPo') ? +v('hPo') : null;
        if (v('hGrn') !== undefined) h.RefDocId = v('hGrn') ? +v('hGrn') : null;
        if (v('hIndent') !== undefined) h.RefDocId = v('hIndent') ? +v('hIndent') : null;
        if (v('hReason') !== undefined) h.ReasonCode = v('hReason') || null;
        if (v('hPriority') !== undefined) h.Priority = v('hPriority');
        if (v('hDate') !== undefined) h.DocDate = v('hDate') || null;
        if (v('hExpected') !== undefined) h.ExpectedDate = v('hExpected') || null;
        if (v('hInvNo') !== undefined) h.SupplierInvNo = v('hInvNo') || null;
        if (v('hInvDate') !== undefined) h.SupplierInvDate = v('hInvDate') || null;
        if (v('hOther') !== undefined) h.OtherCharges = n(v('hOther'));
        if (v('hIgst') !== undefined) h.IsInterState = v('hIgst');
        if (v('hTerms') !== undefined) h.Terms = v('hTerms') || null;
        if (v('hRemarks') !== undefined) h.Remarks = v('hRemarks') || null;
    }

    function renderHead() {
        document.getElementById('edHead').innerHTML = D.head.map(headField).join('');
        const on = (id, ev, f) => document.getElementById(id)?.addEventListener(ev, f);
        on('hStore', 'change', () => { const old = ed.head.StoreId; readHead(); if (D.lotPick && ed.lines.length && old !== ed.head.StoreId) { ed.lines = []; renderLines(); QC.ok('Lines cleared: lots belong to the store'); }
            if (D.head.includes('toStore')) { renderHead(); } });
        on('hSupplier', 'change', () => { readHead(); if (T === 'GRN') fillOrders(); if (T === 'PRET') fillGrns(); });
        on('hPo', 'change', () => { readHead(); if (ed.head.RefDocId) loadOrder(ed.head.RefDocId); });
        on('hIndent', 'change', () => { readHead(); if (ed.head.RefDocId) loadIndent(ed.head.RefDocId); });
        on('hReason', 'change', () => { readHead(); if (T === 'ADJ') { ed.lines.forEach(l => { l.lots = null; }); renderLines(); refreshLots(); } });
        on('hOther', 'input', () => { readHead(); totals(); });
        on('hIgst', 'change', () => { readHead(); totals(); });
        if (T === 'GRN') fillOrders();
        if (T === 'PRET') fillGrns();
        if (T === 'ISS') fillIndents();
    }

    async function fillOrders() {
        const s = document.getElementById('hPo'); if (!s) return;
        const r = await QC.get('/QcGoodsReceipts/OpenOrders');
        const list = (r.data || []).filter(p => ['APPROVED', 'PARTIAL'].includes(p.Status) && (!ed.head.SupplierId || p.SupplierId === ed.head.SupplierId));
        s.innerHTML = '<option value="">Direct receipt (no PO)</option>' + list.map(p => `<option value="${p.DocId}" ${ed.head.RefDocId === p.DocId ? 'selected' : ''}>${esc(p.DocNo)} · ${QC.date(p.DocDate)} · ${esc(p.SupplierName)}</option>`).join('');
        if (ed.head.RefDocId && !list.some(p => p.DocId === ed.head.RefDocId)) ed.head.RefDocId = null;
    }
    async function loadOrder(id) {
        const r = await QC.get('/QcGoodsReceipts/Order', { id });
        if (!r.success) return QC.fail(r.message);
        const h = (r.data[0] || [])[0], lines = r.data[1] || [];
        if (!h) return;
        ed.head.SupplierId = h.SupplierId; ed.head.StoreId = h.StoreId;
        ed.lines = lines.filter(l => n(l.PendingBaseQty) > 0).map(l => newLine(item(l.ItemId), {
            Qty: +(n(l.PendingBaseQty) / n(l.Factor)).toFixed(3), Rate: l.Rate, DiscPct: l.DiscPct, GstPct: l.GstPct, RefLineId: l.LineId, poPending: n(l.PendingBaseQty) / n(l.Factor) }));
        renderHead(); renderLines();
        document.getElementById('hPo').value = id;
        if (!ed.lines.length) QC.fail('Everything on this order is already received.');
    }
    async function fillGrns() {
        const s = document.getElementById('hGrn'); if (!s) return;
        const r = await QC.get(url('Receipts'));
        const list = (r.data || []).filter(g => !ed.head.SupplierId || g.SupplierId === ed.head.SupplierId).slice(0, 100);
        s.innerHTML = '<option value="">-- optional --</option>' + list.map(g => `<option value="${g.DocId}" ${ed.head.RefDocId === g.DocId ? 'selected' : ''}>${esc(g.DocNo)} · bill ${esc(g.SupplierInvNo || '')} · ${QC.date(g.DocDate)}</option>`).join('');
    }
    async function fillIndents() {
        const s = document.getElementById('hIndent'); if (!s) return;
        const r = await QC.get(url('OpenIndents'));
        const list = (r.data || []).filter(i => ['SUBMITTED', 'PARTIAL'].includes(i.Status));
        s.innerHTML = '<option value="">Direct issue (no indent)</option>' + list.map(i => `<option value="${i.DocId}" ${ed.head.RefDocId === i.DocId ? 'selected' : ''}>${esc(i.DocNo)} · ${esc(i.StoreName)} (${esc(i.StoreBranch || '')})${i.Priority === 'Urgent' ? ' · URGENT' : ''}</option>`).join('');
    }
    async function loadIndent(id) {
        const r = await QC.get(url('FromIndent'), { id });
        if (!r.success) return QC.fail(r.message);
        const g = await QC.get(url('OpenIndents'));
        const ind = (g.data || []).find(i => i.DocId === id);
        if (ind) { ed.head.StoreId = ind.ToStoreId; ed.head.ToStoreId = ind.StoreId; }
        const short = [];
        ed.lines = [];
        (r.data || []).forEach(a => {
            if (!a.LotId || n(a.Take) <= 0) { short.push(item(a.ItemId)?.ItemName); return; }
            ed.lines.push(newLine(item(a.ItemId), { LotId: a.LotId, UnitMode: 'C', Qty: +n(a.Take).toFixed(4), RefLineId: a.RefLineId }));
        });
        renderHead(); document.getElementById('hIndent').value = id;
        renderLines(); await refreshLots();
        const totalPending = {}; (r.data || []).forEach(a => { totalPending[a.RefLineId] = n(a.Pending); });
        const given = {}; ed.lines.forEach(l => { given[l.RefLineId] = (given[l.RefLineId] || 0) + n(l.Qty); });
        const partial = Object.keys(totalPending).filter(k => (given[k] || 0) + 0.0001 < totalPending[k]).length;
        if (short.length || partial) QC.fail(`Not enough usable stock for ${short.length + partial} line(s)${short.length ? ': ' + [...new Set(short)].join(', ') : ''}. Issue what is available; the indent stays open for the rest.`);
    }

    // a line
    function newLine(it, o) {
        const mode = D.packOnly ? 'P' : (o && o.UnitMode) || D.defaultMode || 'P';
        return Object.assign({ ItemId: it.ItemId, LotId: null, LotNo: '', ExpiryDate: '', MfgDate: '', UnitMode: mode, Qty: 1, FreeQty: 0,
            Rate: D.rate ? (mode === 'P' ? n(it.PurchaseRate) : +(n(it.PurchaseRate) / n(it.PackSize)).toFixed(4)) : 0,
            DiscPct: 0, GstPct: n(it.GstPercent), RefLineId: null, Remarks: '', lots: null }, o || {});
    }
    const factor = l => { const it = item(l.ItemId); return l.UnitMode === 'P' ? n(it?.PackSize) || 1 : 1; };
    const unitName = l => { const it = item(l.ItemId) || {}; return l.UnitMode === 'P' ? it.PurchaseUnit : it.ConsumptionUnit; };

    function lineCols() {
        const c = [['#', ''], ['Item', '']];
        if (D.lotEntry) c.push(D.batchRequired ? ['Batch / lot no <span class="text-danger">*</span>', ''] : ['Lot no', ''],
                               D.batchRequired ? ['Expiry <span class="text-danger">*</span>', ''] : ['Expiry', ''], ['Mfg', '']);
        if (D.lotPick) c.push(['Lot (expiry · in store)', '']);
        if (D.unitMode) c.push(['Unit', '']);
        c.push(['Qty', 'r']);
        if (D.free) c.push(['Free', 'r']);
        if (D.rate) c.push([D.rate, 'r']);
        if (D.disc) c.push(['Disc %', 'r']);
        if (D.gst) c.push(['GST %', 'r']);
        if (D.amounts) c.push(['Amount', 'r']);
        if (D.remarks) c.push(['Remarks', '']);
        c.push(['', '']);
        return c;
    }

    function lotOptions(l) {
        if (!l.lots) return '<option value="">Loading lots...</option>';
        if (!l.lots.length) return '<option value="">No stock of this item in the store</option>';
        return '<option value="">-- Lot --</option>' + l.lots.map(x => `<option value="${x.LotId}" ${l.LotId === x.LotId ? 'selected' : ''}>${esc(x.LotNo === 'NA' ? 'No lot' : x.LotNo)}${x.ExpiryDate ? ' · exp ' + QC.date(x.ExpiryDate) : ''} · ${qty(x.Qty)} ${esc(item(l.ItemId)?.ConsumptionUnit || '')}${x.Status !== 'ACCEPTED' ? ' · ' + x.Status.toLowerCase() : ''}${x.OpenedOn ? ' · open' : ''}</option>`).join('');
    }

    function renderLines() {
        const cols = lineCols();
        document.getElementById('edLinesHead').innerHTML = cols.map(c => `<th class="${c[1] === 'r' ? 'text-end' : ''}">${c[0]}</th>`).join('');
        const tb = document.getElementById('edLines');
        if (!ed.lines.length) { tb.innerHTML = `<tr><td colspan="${cols.length}" class="text-center text-muted py-3">Add items above.</td></tr>`; totals(); return; }
        tb.innerHTML = ed.lines.map((l, i) => {
            const it = item(l.ItemId) || {};
            const num = (k, step, w) => `<td class="text-end"><input type="number" class="form-control qs-num qs-in-r" data-i="${i}" data-k="${k}" value="${l[k] ?? ''}" step="${step || 'any'}" min="0" style="max-width:${w || 110}px"/></td>`;
            let h = `<td class="text-muted small">${i + 1}</td><td><div class="fw-semibold small">${esc(it.ItemName || '?')}</div><div class="text-muted small">${esc(it.ItemCode || '')} · 1 ${esc(it.PurchaseUnit || '')} = ${qty(it.PackSize)} ${esc(it.ConsumptionUnit || '')}${l.poPending ? ' · PO due ' + qty(l.poPending) : ''}</div></td>`;
            if (D.lotEntry) h += `<td><input class="form-control qs-w-lot text-uppercase" data-i="${i}" data-k="LotNo" value="${esc(l.LotNo || '')}" maxlength="50" ${it.IsLotTracked || D.batchRequired ? 'placeholder="Batch no"' : 'disabled placeholder="not lot tracked"'}/></td>
                <td><input type="date" class="form-control qs-w-date" data-i="${i}" data-k="ExpiryDate" value="${d10(l.ExpiryDate)}" ${it.IsExpiryTracked || it.IsLotTracked || D.batchRequired ? '' : 'disabled'}/></td>
                <td><input type="date" class="form-control qs-w-date" data-i="${i}" data-k="MfgDate" value="${d10(l.MfgDate)}" max="${today()}"/></td>`;
            if (D.lotPick) h += `<td><select class="form-select qs-w-lotpick" data-i="${i}" data-k="LotId">${lotOptions(l)}</select></td>`;
            if (D.unitMode) h += `<td><select class="form-select" data-i="${i}" data-k="UnitMode" style="max-width:120px"><option value="P" ${l.UnitMode === 'P' ? 'selected' : ''}>${esc(it.PurchaseUnit || 'Pack')}</option><option value="C" ${l.UnitMode === 'C' ? 'selected' : ''}>${esc(it.ConsumptionUnit || 'Unit')}</option></select></td>`;
            h += num('Qty', 'any', 100);
            if (D.free) h += num('FreeQty', 'any', 80);
            if (D.rate) h += num('Rate', '0.01', 110);
            if (D.disc) h += num('DiscPct', '0.01', 80);
            if (D.gst) h += num('GstPct', '0.01', 75);
            if (D.amounts) h += `<td class="qs-num small fw-semibold" id="lam${i}"></td>`;
            if (D.remarks) h += `<td><input class="form-control" data-i="${i}" data-k="Remarks" value="${esc(l.Remarks || '')}" maxlength="300"/></td>`;
            h += `<td><button type="button" class="btn btn-sm btn-outline-danger act-rm" data-i="${i}" title="Remove"><i class="bi bi-x-lg"></i></button></td>`;
            return `<tr>${h}</tr>`;
        }).join('');
        totals();
    }

    function lineCalc(l) {
        const gross = n(l.Qty) * n(l.Rate), disc = gross * n(l.DiscPct) / 100, taxable = gross - disc, gst = taxable * n(l.GstPct) / 100;
        return { gross, disc, taxable, gst, amount: taxable + gst };
    }
    function totals() {
        const box = document.getElementById('edTotals'), hint = document.getElementById('edHint');
        const base = ed.lines.reduce((s, l) => s + n(l.Qty) * factor(l), 0);
        hint.textContent = ed.lines.length ? `${ed.lines.length} line(s)` + (D.amounts ? '' : ` · ${qty(base)} units in total`) : '';
        if (!D.amounts) { box.classList.add('d-none'); return; }
        let t = { gross: 0, disc: 0, taxable: 0, gst: 0 };
        ed.lines.forEach((l, i) => { const c = lineCalc(l); ['gross', 'disc', 'taxable', 'gst'].forEach(k => t[k] += c[k]); const el = document.getElementById('lam' + i); if (el) el.textContent = QC.num(c.amount); });
        const other = T === 'GRN' ? n(ed.head.OtherCharges) : 0, total = t.taxable + t.gst + other, net = Math.round(total);
        const gstRows = ed.head.IsInterState ? `<tr><td>IGST</td><td class="qs-num">${QC.num(t.gst)}</td></tr>` : `<tr><td>CGST</td><td class="qs-num">${QC.num(t.gst / 2)}</td></tr><tr><td>SGST</td><td class="qs-num">${QC.num(t.gst / 2)}</td></tr>`;
        box.innerHTML = `<tr><td>Gross</td><td class="qs-num">${QC.num(t.gross)}</td></tr><tr><td>Discount</td><td class="qs-num">-${QC.num(t.disc)}</td></tr>
            <tr><td>Taxable</td><td class="qs-num">${QC.num(t.taxable)}</td></tr>${gstRows}${other ? `<tr><td>Freight / other</td><td class="qs-num">${QC.num(other)}</td></tr>` : ''}
            <tr><td>Round off</td><td class="qs-num">${QC.num(net - total)}</td></tr><tr class="fw-bold border-top"><td>Net amount</td><td class="qs-num">₹${QC.num(net)}</td></tr>`;
        box.classList.remove('d-none');
    }

    const linesBox = document.getElementById('edLines');
    linesBox.addEventListener('input', e => {
        const el = e.target, i = +el.dataset.i, k = el.dataset.k; if (isNaN(i) || !k || el.tagName === 'SELECT') return;
        const l = ed.lines[i];
        l[k] = el.type === 'number' ? (el.value === '' ? null : +el.value) : el.value;
        if (['Qty', 'Rate', 'DiscPct', 'GstPct', 'FreeQty'].includes(k)) totals();
    });
    linesBox.addEventListener('change', e => {
        const el = e.target, i = +el.dataset.i, k = el.dataset.k; if (isNaN(i) || !k || el.tagName !== 'SELECT') return;
        const l = ed.lines[i];
        if (k === 'LotId') { l.LotId = el.value ? +el.value : null; if (T === 'PRET') pretRate(l); totals(); return; }
        if (k === 'UnitMode') {
            const it = item(l.ItemId), f = n(it?.PackSize) || 1, old = l.UnitMode; l.UnitMode = el.value;
            if (old !== l.UnitMode && D.rate) l.Rate = +(l.UnitMode === 'P' ? n(l.Rate) * f : n(l.Rate) / f).toFixed(4);
            renderLines();
        }
    });
    linesBox.addEventListener('click', e => { const b = e.target.closest('.act-rm'); if (!b) return; ed.lines.splice(+b.dataset.i, 1); renderLines(); });

    function pretRate(l) {
        const x = (l.lots || []).find(z => z.LotId === l.LotId); if (!x) return;
        const per = n(x.GrnUnitRate) || n(x.LotCost) || n(x.AvgCost);
        l.Rate = +(l.UnitMode === 'P' ? per * factor(l) : per).toFixed(4);
        if (x.GrnGstPct != null) l.GstPct = x.GrnGstPct;
        renderLines();
    }

    function lotPurpose() {
        if (T === 'ISS') return 'ISSUE';
        if (T === 'ADJ') { const r = (L.reasons || []).find(x => x.Id === ed.head.ReasonCode); return r && r.Direction > 0 ? 'ANY' : 'OUT'; }
        return 'OUT';
    }
    async function refreshLots() {
        if (!D.lotPick) return;
        const sid = ed.head.StoreId; if (!sid) return;
        const byItem = {};
        for (const l of ed.lines) {
            if (l.lots) continue;
            if (!byItem[l.ItemId]) {
                const r = await QC.get(url('Lots'), { storeId: sid, itemId: l.ItemId, purpose: lotPurpose() });
                byItem[l.ItemId] = r.success ? (r.data || []) : [];
            }
            l.lots = byItem[l.ItemId];
            if (!l.LotId && l.lots.length === 1) l.LotId = l.lots[0].LotId;
            if (T === 'PRET' && l.LotId && !n(l.Rate)) pretRate(l);
        }
        renderLines();
    }

    // add-item bar
    function renderAdd() {
        const box = document.getElementById('edAdd');
        const fefo = D.fefo;
        box.innerHTML = `<div class="row g-2 align-items-end">
            <div class="col-md-${fefo ? 6 : 8}"><label class="form-label small fw-semibold mb-1" for="edItem">Add item</label><select id="edItem" class="form-select"></select></div>
            ${fefo ? `<div class="col-md-2"><label class="form-label small fw-semibold mb-1" for="edQty">Quantity</label><input type="number" id="edQty" class="form-control" min="0" step="any"/></div>
                      <div class="col-md-2"><label class="form-label small fw-semibold mb-1" for="edUnit">Unit</label><select id="edUnit" class="form-select"><option value="C">Unit</option><option value="P">Pack</option></select></div>
                      <div class="col-md-2"><button type="button" class="btn btn-outline-primary w-100" id="edFefo"><i class="bi bi-sort-down me-1"></i>Add (FEFO)</button></div>` : ''}
            ${T === 'PO' ? '<div class="col-md-4 text-md-end"><button type="button" class="btn btn-outline-secondary" id="edReorder"><i class="bi bi-arrow-repeat me-1"></i>Add items below reorder level</button></div>' : ''}
            </div>${fefo ? '<div class="form-text">Lots are taken in order: opened first, then the earliest expiry. Change a line\'s lot if needed.</div>' : ''}`;
        const sel = document.getElementById('edItem');
        let picked = null;
        QC.itemPicker(sel, items, document.getElementById('edModal'), async it => {
            if (!it) return;
            if (fefo) { picked = it; const u = document.getElementById('edUnit'); u.options[0].text = it.ConsumptionUnit; u.options[1].text = it.PurchaseUnit; document.getElementById('edQty').focus(); return; }
            readHead();
            if (D.lotPick && !ed.head.StoreId) { QC.clearPicker(sel); return QC.fail('Select the store first.'); }
            ed.lines.push(newLine(it));
            QC.clearPicker(sel);
            renderLines(); await refreshLots();
        });
        document.getElementById('edFefo')?.addEventListener('click', async () => {
            readHead();
            const q = n(document.getElementById('edQty').value), mode = document.getElementById('edUnit').value;
            if (!picked) return QC.fail('Pick an item.');
            if (!ed.head.StoreId) return QC.fail('Select the store first.');
            if (q <= 0) return QC.fail('Enter the quantity to issue.');
            const base = mode === 'P' ? q * n(picked.PackSize) : q;
            const r = await QC.get(url('Fefo'), { storeId: ed.head.StoreId, itemId: picked.ItemId, qty: base });
            if (!r.success) return QC.fail(r.message);
            const alloc = r.data || [], got = alloc.reduce((s, a) => s + n(a.Take), 0);
            if (!alloc.length) return QC.fail(`No usable stock of ${picked.ItemName} in this store (accepted, unexpired lots).`);
            alloc.forEach(a => ed.lines.push(newLine(picked, { LotId: a.LotId, UnitMode: 'C', Qty: +n(a.Take).toFixed(4) })));
            if (got + 0.0001 < base) QC.fail(`Only ${qty(got)} ${picked.ConsumptionUnit} usable in this store; that much was added.`);
            picked = null; QC.clearPicker(sel); document.getElementById('edQty').value = '';
            renderLines(); await refreshLots();
        });
        document.getElementById('edReorder')?.addEventListener('click', async () => {
            const r = await QC.get(url('Reorder'));
            if (!r.success) return QC.fail(r.message);
            readHead();
            const list = (r.data || []).filter(x => n(x.SuggestPacks) > 0 && !ed.lines.some(l => l.ItemId === x.ItemId) && (!ed.head.SupplierId || !x.LastSupplierId || x.LastSupplierId === ed.head.SupplierId));
            if (!list.length) return QC.ok('Nothing below reorder level' + (ed.head.SupplierId ? ' for this supplier' : ''));
            list.forEach(x => { const it = item(x.ItemId); if (it) ed.lines.push(newLine(it, { Qty: n(x.SuggestPacks), Rate: n(x.PurchaseRate), GstPct: n(x.GstPercent) })); });
            renderLines(); QC.ok(`${list.length} item(s) added`);
        });
    }

    function openEditor(doc) {
        const h = doc ? doc.head : {};
        ed = { DocId: h.DocId || null, head: Object.assign({ StoreId: (mine.find(s => s.StoreType === 'Main') || mine[0] || {}).StoreId || null, DocDate: today(), Priority: 'Normal' }, h), lines: [] };
        if (doc) ed.lines = doc.lines.map(l => newLine(item(l.ItemId) || { ItemId: l.ItemId }, {
            LotId: l.LotId, LotNo: l.LotNo === 'NA' ? '' : (l.LotNo || ''), ExpiryDate: d10(l.ExpiryDate), MfgDate: d10(l.MfgDate), UnitMode: l.UnitMode, Qty: n(l.Qty),
            FreeQty: n(l.FreeQty), Rate: n(l.Rate), DiscPct: n(l.DiscPct), GstPct: n(l.GstPct), RefLineId: l.RefLineId, Remarks: l.Remarks || '' }));
        document.getElementById('edTitle').textContent = doc ? `Edit ${h.DocNo}` : `New ${newLabel()}`;
        const pb = document.getElementById('edPrimary');
        pb.innerHTML = `<i class="bi bi-check2-circle me-1"></i>${D.primary.label}`;
        pb.classList.toggle('d-none', !P[D.primary.perm]);
        if (T === 'ISS') pb.innerHTML = '<i class="bi bi-send me-1"></i>Save & dispatch';
        renderHead(); renderAdd(); renderLines(); refreshLots();
        edModal.show();
    }

    function payload() {
        readHead();
        const h = ed.head;
        return {
            DocId: ed.DocId, DocDate: h.DocDate, StoreId: h.StoreId, ToStoreId: h.ToStoreId, SupplierId: h.SupplierId, RefDocId: h.RefDocId,
            SupplierInvNo: h.SupplierInvNo, SupplierInvDate: h.SupplierInvDate, ExpectedDate: h.ExpectedDate, IsInterState: !!h.IsInterState,
            ReasonCode: h.ReasonCode, Priority: h.Priority, Terms: h.Terms, OtherCharges: h.OtherCharges || 0, Remarks: h.Remarks,
            Lines: ed.lines.map(l => ({ ItemId: l.ItemId, LotId: l.LotId, LotNo: l.LotNo || null, ExpiryDate: l.ExpiryDate || null, MfgDate: l.MfgDate || null,
                UnitMode: l.UnitMode, Qty: n(l.Qty), FreeQty: n(l.FreeQty), Rate: n(l.Rate), DiscPct: n(l.DiscPct), GstPct: n(l.GstPct), RefLineId: l.RefLineId, Remarks: l.Remarks || null }))
        };
    }
    function check() {
        const h = ed.head;
        if (!h.StoreId) return 'Select the store.';
        if (D.head.includes('toStore') && !h.ToStoreId) return 'Select the other store.';
        if (D.head.includes('supplier') && !h.SupplierId) return 'Select the supplier.';
        if (T === 'ADJ' && !h.ReasonCode) return 'Select the reason.';
        if (!ed.lines.length) return 'Add at least one item.';
        if (D.lotPick && ed.lines.some(l => !l.LotId)) return 'Select the lot of every line.';
        if (ed.lines.some(l => n(l.Qty) <= 0 && !(T === 'GRN' && n(l.FreeQty) > 0))) return 'Every line needs a quantity.';
        if (D.lotEntry && D.batchRequired) {
            const nb = ed.lines.find(l => !String(l.LotNo || '').trim()); if (nb) return `${item(nb.ItemId)?.ItemName}: enter the batch / lot number (required on every receipt line).`;
            const ne = ed.lines.find(l => !l.ExpiryDate); if (ne) return `${item(ne.ItemId)?.ItemName}: enter the expiry date (required on every receipt line).`;
        }
        if (D.lotEntry && ed.lines.some(l => item(l.ItemId)?.IsLotTracked && !l.LotNo)) return 'Enter the lot number of every lot-tracked item.';
        if (D.lotEntry && ed.lines.some(l => item(l.ItemId)?.IsExpiryTracked && !l.ExpiryDate)) return 'Enter the expiry date of every expiry-tracked item.';
        if (D.lotPick && T !== 'ADJ') {
            for (const l of ed.lines) { const x = (l.lots || []).find(z => z.LotId === l.LotId); if (x && n(l.Qty) * factor(l) > n(x.Qty) + 0.0001) return `${item(l.ItemId)?.ItemName}: more than the ${qty(x.Qty)} ${item(l.ItemId)?.ConsumptionUnit} in this lot.`; }
        }
        return null;
    }

    async function save(then) {
        const p = payload(), err = check();
        if (err) return QC.fail(err);
        if (then && D.primary.ask && !(await QC.confirm(D.primary.label + '?', D.primary.ask, 'Yes'))) return;
        const b1 = document.getElementById('edSave'), b2 = document.getElementById('edPrimary');
        b1.disabled = b2.disabled = true;
        try {
            const r = await QC.post(url('Save'), p);
            if (!r.success) return QC.fail(r.message);
            ed.DocId = r.data.DocId;
            if (then) {
                const a = await QC.post(url(D.primary.action), { id: ed.DocId });
                if (!a.success) { QC.fail('Saved as draft ' + r.data.DocNo + ', but: ' + a.message); load(); return; }
                QC.ok(`${a.data.DocNo} ${(LABEL[a.data.Status] || a.data.Status).toLowerCase()}${a.data.VoucherNo ? ' · voucher ' + a.data.VoucherNo : ''}`);
            } else QC.ok('Draft saved: ' + r.data.DocNo);
            edModal.hide(); load(); view(ed.DocId);
        } finally { b1.disabled = b2.disabled = false; }
    }
    document.getElementById('edSave').addEventListener('click', () => save(false));
    document.getElementById('edPrimary').addEventListener('click', () => save(true));

    // ── viewer ────────────────────────────────────────────────────────────────────────────────────────────────
    const vwModal = new bootstrap.Modal(document.getElementById('vwModal'));
    let cur = null;   // { head, lines, related, moves }

    async function view(id) {
        const r = await QC.get(url('Get'), { id });
        if (!r.success) return QC.fail(r.message);
        const s = r.data || [], head = (s[0] || [])[0];
        if (!head) return QC.fail('The document was not found in this branch.');
        cur = { head, lines: s[1] || [], related: s[2] || [], moves: s[3] || [] };
        renderView();
        vwModal.show();
    }

    function fact(k, v) { return v === null || v === undefined || v === '' ? '' : `<div><div class="k">${k}</div><div class="v">${v}</div></div>`; }
    function renderView() {
        const h = cur.head, ls = cur.lines;
        document.getElementById('vwTitle').innerHTML = `${esc(h.DocTypeName)} <span class="font-monospace">${esc(h.DocNo)}</span> ${badge(h.Status)}`;
        const isCountEdit = T === 'CNT' && h.Status === 'DRAFT' && h.IsMine && P.ADD;
        const isReceive = T === 'ISS' && h.Status === 'INTRANSIT' && h.IsToMine && P.RECEIVE;
        let facts = fact('Date', QC.date(h.DocDate)) +
            fact({ IND: 'Requesting store', ISS: 'From store' }[T] || 'Store', esc(h.StoreName) + (h.StoreBranch ? ` <span class="text-muted fw-normal">· ${esc(h.StoreBranch)}</span>` : '')) +
            fact(T === 'IND' ? 'Asked from' : 'To store', h.ToStoreName ? esc(h.ToStoreName) + ` <span class="text-muted fw-normal">· ${esc(h.ToBranchName || '')}</span>` : '') +
            fact('Supplier', h.SupplierName ? esc(h.SupplierName) + (h.SupplierGstin ? ` <span class="text-muted fw-normal">· ${esc(h.SupplierGstin)}</span>` : '') + (h.SupplierApproved === false ? ' <span class="badge bg-warning text-dark">not approved</span>' : '') : '') +
            fact('Against', h.RefDocNo ? esc(h.RefDocNo) : '') + fact('Supplier bill', h.SupplierInvNo ? esc(h.SupplierInvNo) + (h.SupplierInvDate ? ' · ' + QC.date(h.SupplierInvDate) : '') : '') +
            fact(T === 'IND' ? 'Needed by' : 'Expected', QC.date(h.ExpectedDate)) + fact('Priority', T === 'IND' ? esc(h.Priority || '') : '') +
            fact('Reason', h.ReasonCode ? esc(reasonName(h.ReasonCode)) : '') + fact('Category', h.CategoryName ? esc(h.CategoryName) : '') +
            fact('Voucher', h.VoucherNo ? esc(h.VoucherNo) : '') + fact('Terms', h.Terms ? esc(h.Terms) : '') + fact('Remarks', h.Remarks ? esc(h.Remarks) : '');
        const trail = [['Raised', h.CreatedByName, h.CreatedOn], ['Submitted', h.SubmittedByName, h.SubmittedOn], ['Approved', h.ApprovedByName, h.ApprovedOn],
            ['Rejected', h.RejectedByName, h.RejectedOn], [T === 'ISS' ? 'Dispatched' : 'Posted', h.PostedByName, h.PostedOn], ['Received', h.ReceivedByName, h.ReceivedOn],
            ['Closed', h.ClosedByName, h.ClosedOn], ['Cancelled', h.CancelledByName, h.CancelledOn]].filter(x => x[2])
            .map(x => `<span class="me-3"><span class="text-muted">${x[0]}</span> ${esc(x[1] || '')} · ${QC.dateTime(x[2])}</span>`).join('');
        const reasons = (h.RejectReason && h.Status === 'REJECTED' ? `<div class="alert alert-danger py-2 small mb-2">Rejected: ${esc(h.RejectReason)}</div>` : '') +
            (h.CancelReason ? `<div class="alert alert-secondary py-2 small mb-2">Cancelled: ${esc(h.CancelReason)}</div>` : '');

        // lines
        let head = '<th>#</th><th>Item</th>', body;
        if (T === 'CNT') {
            head += '<th>Lot</th><th>Expiry</th><th class="text-end">Book stock</th><th class="text-end">Counted</th><th class="text-end">Difference</th><th class="text-end">Value</th><th>Remarks</th>';
            body = ls.map((l, i) => `<tr class="${l.DiffBaseQty ? 'qs-rowwarn' : ''}"><td class="small text-muted">${i + 1}</td><td><div class="small fw-semibold">${esc(l.ItemName)}</div><div class="small text-muted">${esc(l.ConsumptionUnit)}</div></td>
                <td class="small">${esc(l.LotLabel === 'NA' ? '—' : l.LotLabel)}</td><td class="small">${QC.date(l.LotExpiry)}</td><td class="qs-num">${qty(l.SystemBaseQty)}</td>
                <td class="qs-num">${isCountEdit ? `<input type="number" class="form-control form-control-sm qs-num cnt-q" data-line="${l.LineId}" value="${l.CountedBaseQty ?? ''}" min="0" step="any" style="max-width:110px;margin-left:auto"/>` : qty(l.CountedBaseQty)}</td>
                <td class="qs-num ${n(l.DiffBaseQty) < 0 ? 'text-danger' : n(l.DiffBaseQty) > 0 ? 'text-success' : ''}">${l.DiffBaseQty == null ? '—' : (l.DiffBaseQty > 0 ? '+' : '') + qty(l.DiffBaseQty)}</td>
                <td class="qs-num">${l.DiffValue == null ? '—' : QC.num(l.DiffValue)}</td>
                <td>${isCountEdit ? `<input class="form-control form-control-sm cnt-r" data-line="${l.LineId}" value="${esc(l.Remarks || '')}" maxlength="300"/>` : esc(l.Remarks || '')}</td></tr>`).join('');
        } else {
            const lot = ['GRN', 'OPN', 'PRET', 'ISS', 'ADJ'].includes(T), amt = ['PO', 'GRN', 'PRET'].includes(T);
            if (lot) head += '<th>Lot</th><th>Expiry</th>';
            head += '<th class="text-end">Qty</th>';
            if (T === 'GRN') head += '<th class="text-end">Free</th>';
            if (T === 'PO' || T === 'IND') head += `<th class="text-end">${T === 'PO' ? 'Received' : 'Issued'}</th><th class="text-end">Pending</th>`;
            if (T === 'ISS') head += '<th class="text-end">Received</th>';
            if (amt || T === 'OPN') head += '<th class="text-end">Rate</th>';
            if (amt) head += '<th class="text-end">Disc %</th><th class="text-end">GST %</th><th class="text-end">Amount</th>';
            if (['ISS', 'ADJ'].includes(T) && h.Status !== 'DRAFT') head += '<th class="text-end">Unit cost</th>';
            if (T === 'GRN' && h.Status === 'POSTED') head += '<th>Lot status</th>';
            head += '<th>Remarks</th>';
            body = ls.map((l, i) => {
                const u = l.UnitMode === 'P' ? l.PurchaseUnit : l.ConsumptionUnit;
                let r = `<td class="small text-muted">${i + 1}</td><td><div class="small fw-semibold">${esc(l.ItemName)}</div><div class="small text-muted">${esc(l.ItemCode)}${l.HsnCode ? ' · HSN ' + esc(l.HsnCode) : ''}</div></td>`;
                if (lot) r += `<td class="small">${esc(!l.LotLabel || l.LotLabel === 'NA' ? '—' : l.LotLabel)}</td><td class="small">${QC.date(l.LotExpiry)}</td>`;
                r += `<td class="qs-num">${qty(T === 'ADJ' ? l.Sign * l.Qty : l.Qty)} <span class="small text-muted">${esc(u)}</span></td>`;
                if (T === 'GRN') r += `<td class="qs-num">${l.FreeQty ? qty(l.FreeQty) : '—'}</td>`;
                if (T === 'PO' || T === 'IND') r += `<td class="qs-num">${qty(n(l.DoneBaseQty) / n(l.Factor))}</td><td class="qs-num ${n(l.PendingBaseQty) > 0 ? 'fw-semibold' : 'text-muted'}">${qty(n(l.PendingBaseQty) / n(l.Factor))}</td>`;
                if (T === 'ISS') r += `<td class="qs-num">${isReceive ? `<input type="number" class="form-control form-control-sm qs-num rcv-q" data-line="${l.LineId}" value="${n(l.BaseQty)}" min="0" max="${n(l.BaseQty)}" step="any" style="max-width:110px;margin-left:auto" title="${esc(l.ConsumptionUnit)}"/>` : (h.Status === 'RECEIVED' ? qty(l.DoneBaseQty) + ' ' + esc(l.ConsumptionUnit) : '—')}</td>`;
                if (amt || T === 'OPN') r += `<td class="qs-num">${QC.num(l.Rate)}</td>`;
                if (amt) r += `<td class="qs-num">${l.DiscPct ? QC.num(l.DiscPct) : '—'}</td><td class="qs-num">${QC.num(l.GstPct, 0)}</td><td class="qs-num fw-semibold">${QC.num(l.LineAmount)}</td>`;
                if (['ISS', 'ADJ'].includes(T) && h.Status !== 'DRAFT') r += `<td class="qs-num">${l.UnitCost != null ? QC.num(l.UnitCost, 4) : '—'}</td>`;
                if (T === 'GRN' && h.Status === 'POSTED') r += `<td>${l.LotStatus ? badge(l.LotStatus) : ''}</td>`;
                r += `<td class="small">${esc(l.Remarks || '')}</td>`;
                return `<tr>${r}</tr>`;
            }).join('');
        }
        const money3 = ['PO', 'GRN', 'PRET'].includes(T) ? `<div class="d-flex justify-content-end"><table class="qs-totals small">
            <tr><td>Taxable</td><td class="qs-num">${QC.num(h.TaxableAmount)}</td></tr><tr><td>GST${h.IsInterState ? ' (IGST)' : ' (CGST + SGST)'}</td><td class="qs-num">${QC.num(h.GstAmount)}</td></tr>
            ${n(h.OtherCharges) ? `<tr><td>Freight / other</td><td class="qs-num">${QC.num(h.OtherCharges)}</td></tr>` : ''}<tr><td>Round off</td><td class="qs-num">${QC.num(h.RoundOff)}</td></tr>
            <tr class="fw-bold border-top"><td>Net amount</td><td class="qs-num">₹${QC.num(h.NetAmount)}</td></tr></table></div>` :
            (h.StockValue != null ? `<div class="text-end small"><span class="text-muted">Stock value moved</span> <b>${money(Math.abs(h.StockValue))}</b></div>` : '');
        const related = cur.related.length ? `<div class="small mt-2"><span class="text-muted">Linked:</span> ${cur.related.map(x => `${esc(x.DocTypeName)} <span class="font-monospace">${esc(x.DocNo)}</span> ${badge(x.Status)}`).join(' · ')}</div>` : '';
        const moves = cur.moves.length ? `<details class="mt-3"><summary class="small fw-semibold">Stock movements (${cur.moves.length})</summary><div class="table-responsive"><table class="table table-sm small mb-0">
            <thead><tr><th>When</th><th>Movement</th><th>Store</th><th>Item</th><th>Lot</th><th class="text-end">In</th><th class="text-end">Out</th><th class="text-end">Unit cost</th><th class="text-end">Value</th></tr></thead>
            <tbody>${cur.moves.map(m => `<tr><td>${QC.dateTime(m.TxnOn)}</td><td>${esc(m.MoveName)}</td><td>${esc(m.StoreName)}</td><td>${esc(m.ItemName)}</td><td>${esc(m.LotNo === 'NA' ? '—' : m.LotNo)}</td>
            <td class="qs-num">${m.QtyIn ? qty(m.QtyIn) : ''}</td><td class="qs-num">${m.QtyOut ? qty(m.QtyOut) : ''}</td><td class="qs-num">${QC.num(m.UnitCost, 4)}</td><td class="qs-num">${QC.num(m.Value)}</td></tr>`).join('')}</tbody></table></div></details>` : '';
        const countAdd = isCountEdit ? `<div class="qs-add mt-2"><div class="row g-2 align-items-end"><div class="col-md-6"><label class="form-label small fw-semibold mb-1" for="cntItem">Found a lot that is not on the sheet?</label><select id="cntItem" class="form-select"></select></div>
            <div class="col-md-4"><label class="form-label small fw-semibold mb-1" for="cntLot">Lot</label><select id="cntLot" class="form-select"><option value="">-- pick an item --</option></select></div>
            <div class="col-md-2"><button type="button" class="btn btn-outline-primary w-100" id="cntAddLot"><i class="bi bi-plus-lg"></i> Add</button></div></div></div>` : '';
        document.getElementById('vwBody').innerHTML = reasons + `<div class="qs-facts mb-3">${facts}</div>` +
            (isReceive ? '<div class="alert alert-info py-2 small">Enter what actually arrived. A shortage is written off as a transit loss.</div>' : '') +
            (isCountEdit ? '<div class="alert alert-info py-2 small">Enter the quantity counted on the shelf (in the consumption unit). Leave blank for a lot you have not counted - it is not changed.</div>' : '') +
            `<div class="table-responsive"><table class="table table-sm qs-lines align-middle"><thead><tr>${head}</tr></thead><tbody>${body || ''}</tbody></table></div>${money3}${countAdd}${related}${moves}
            <div class="small text-muted mt-3">${trail}</div>`;
        if (isCountEdit) wireCountAdd();
        renderActions(isCountEdit, isReceive);
    }

    function wireCountAdd() {
        const sel = document.getElementById('cntItem'), lot = document.getElementById('cntLot');
        let pickedLots = [];
        QC.itemPicker(sel, items, document.getElementById('vwModal'), async it => {
            if (!it) return;
            const r = await QC.get(url('Lots'), { storeId: cur.head.StoreId, itemId: it.ItemId, purpose: 'ANY' });
            pickedLots = (r.data || []).filter(x => !cur.lines.some(l => l.LotId === x.LotId));
            lot.innerHTML = pickedLots.length ? pickedLots.map(x => `<option value="${x.LotId}">${esc(x.LotNo === 'NA' ? 'No lot' : x.LotNo)}${x.ExpiryDate ? ' · exp ' + QC.date(x.ExpiryDate) : ''}</option>`).join('')
                : '<option value="">No other lot of this item - receive it through GRN / opening stock</option>';
        });
        document.getElementById('cntAddLot').addEventListener('click', async () => {
            const id = +lot.value; if (!id) return;
            const q = await Swal.fire({ title: 'Counted quantity', input: 'number', inputAttributes: { min: 0, step: 'any' }, showCancelButton: true, confirmButtonText: 'Add to sheet' });
            if (!q.isConfirmed || q.value === '') return;
            const r = await QC.post(url('SaveCounts'), { id: cur.head.DocId, data: [...countData(), { LotId: id, CountedQty: +q.value }] });
            if (!r.success) return QC.fail(r.message);
            view(cur.head.DocId);
        });
    }
    function countData() {
        return [...document.querySelectorAll('#vwBody .cnt-q')].map(i => {
            const r = document.querySelector(`#vwBody .cnt-r[data-line="${i.dataset.line}"]`);
            return { LineId: +i.dataset.line, CountedQty: i.value === '' ? null : +i.value, Remarks: r ? r.value : null };
        });
    }

    function btn(id, cls, icon, label) { return `<button type="button" class="btn ${cls}" data-act="${id}"><i class="bi ${icon} me-1"></i>${label}</button>`; }
    function renderActions(isCountEdit, isReceive) {
        const h = cur.head, s = h.Status, a = [], left = [];
        left.push(`<a class="btn btn-outline-secondary" href="${url('Print')}?id=${h.DocId}" target="_blank" rel="noopener"><i class="bi bi-printer me-1"></i>Print</a>`);
        const mineDoc = h.IsMine;
        if (mineDoc && ['DRAFT', 'REJECTED'].includes(s) && P.ADD && T !== 'CNT') a.push(btn('edit', 'btn-outline-primary', 'bi-pencil', 'Edit'));
        if (isCountEdit) a.push(btn('counts', 'btn-outline-primary', 'bi-save', 'Save counts'));
        if (mineDoc && s === 'DRAFT') {
            if (['OPN', 'GRN', 'PRET'].includes(T) && P.POST) a.push(btn('Post', 'btn-success', 'bi-check2-circle', 'Post'));
            if (['PO', 'IND', 'ADJ', 'CNT'].includes(T) && P.SUBMIT) a.push(btn('Submit', 'btn-primary', 'bi-send', T === 'IND' ? 'Submit indent' : 'Submit'));
            if (T === 'ISS' && P.DISPATCH) { a.push(btn('Dispatch', 'btn-primary', 'bi-send', 'Dispatch'));
                if (h.IsToMine && P.RECEIVE) a.push(btn('DispatchReceive', 'btn-success', 'bi-box-arrow-in-down', 'Dispatch & receive now')); }
        }
        if (mineDoc && s === 'REJECTED' && ['PO', 'ADJ', 'CNT', 'IND'].includes(T) && P.SUBMIT) a.push(btn('Submit', 'btn-primary', 'bi-send', 'Submit again'));
        if (mineDoc && s === 'SUBMITTED' && ['PO', 'ADJ', 'CNT'].includes(T) && P.APPROVE) {
            a.push(btn('Reject', 'btn-outline-danger', 'bi-x-circle', 'Reject'));
            a.push(btn('Approve', 'btn-success', 'bi-check2-circle', ['ADJ', 'CNT'].includes(T) ? 'Approve & post' : 'Approve'));
        }
        if (T === 'PO' && mineDoc && ['APPROVED', 'PARTIAL'].includes(s)) {
            a.push(`<a class="btn btn-primary" href="/QcGoodsReceipts/Index?fromPo=${h.DocId}"><i class="bi bi-truck me-1"></i>Receive goods</a>`);
            if (P.CLOSE) a.push(btn('Close', 'btn-outline-secondary', 'bi-lock', 'Short-close'));
        }
        if (T === 'IND' && h.IsToMine && ['SUBMITTED', 'PARTIAL'].includes(s)) {
            a.push(`<a class="btn btn-primary" href="/QcStockIssues/Index?fromIndent=${h.DocId}"><i class="bi bi-arrow-left-right me-1"></i>Issue against it</a>`);
            if (s === 'SUBMITTED' && P.REJECT) a.push(btn('Reject', 'btn-outline-danger', 'bi-x-circle', 'Reject'));
            if (P.CLOSE) a.push(btn('Close', 'btn-outline-secondary', 'bi-lock', 'Close'));
        }
        if (isReceive) a.push(btn('Receive', 'btn-success', 'bi-box-arrow-in-down', 'Receive'));
        const cancellable = mineDoc && P.CANCEL && (['DRAFT', 'SUBMITTED', 'REJECTED'].includes(s) || (T === 'PO' && s === 'APPROVED'));
        if (cancellable) left.push(btn('Cancel', 'btn-outline-danger', 'bi-trash', s === 'DRAFT' ? 'Discard draft' : 'Cancel'));
        document.getElementById('vwActions').innerHTML = a.join('');
        document.getElementById('vwLeft').innerHTML = left.join('');
    }

    async function act(action, extra) {
        const h = cur.head, body = Object.assign({ id: h.DocId }, extra || {});
        const map = { Post: 'Post', Submit: 'Submit', Approve: 'Approve', Reject: 'Reject', Cancel: 'Cancel', Close: 'Close', Dispatch: 'Dispatch', DispatchReceive: 'Dispatch', Receive: 'Receive' };
        const r = await QC.post(url(map[action]), body);
        if (!r.success) return QC.fail(r.message);
        QC.ok(`${r.data.DocNo} ${(LABEL[r.data.Status] || r.data.Status).toLowerCase()}${r.data.VoucherNo ? ' · voucher ' + r.data.VoucherNo : ''}`);
        load(); view(h.DocId);
    }
    async function ask(title, required, placeholder) {
        const r = await Swal.fire({ title, input: 'textarea', inputPlaceholder: placeholder || 'Reason', showCancelButton: true, confirmButtonText: 'Continue',
            inputValidator: v => required && !String(v || '').trim() ? 'Please give a reason.' : undefined });
        return r.isConfirmed ? String(r.value || '').trim() : null;
    }

    document.getElementById('vwModal').addEventListener('click', async e => {
        const b = e.target.closest('[data-act]'); if (!b) return;
        const k = b.dataset.act, h = cur.head;
        if (k === 'edit') { vwModal.hide(); openEditor({ head: h, lines: cur.lines }); return; }
        if (k === 'counts') { const r = await QC.post(url('SaveCounts'), { id: h.DocId, data: countData() }); if (!r.success) return QC.fail(r.message); QC.ok('Counts saved'); view(h.DocId); return; }
        if (k === 'Submit' && T === 'CNT') { const r = await QC.post(url('SaveCounts'), { id: h.DocId, data: countData() }); if (!r.success) return QC.fail(r.message); }
        if (k === 'Reject') { const why = await ask('Reject ' + h.DocNo + '?', true); if (why === null) return; return act('Reject', { remarks: why }); }
        if (k === 'Cancel') {
            if (h.Status === 'DRAFT') { if (!(await QC.confirm('Discard this draft?', h.DocNo + ' will be cancelled.', 'Discard'))) return; return act('Cancel'); }
            const why = await ask('Cancel ' + h.DocNo + '?', true); if (why === null) return; return act('Cancel', { remarks: why });
        }
        if (k === 'Close') { const why = await ask((T === 'PO' ? 'Short-close ' : 'Close ') + h.DocNo + '?', false, 'Why the rest is not needed (optional)'); if (why === null) return; return act('Close', { remarks: why }); }
        if (k === 'Approve') {
            const t = ['ADJ', 'CNT'].includes(T) ? 'Approve and post? Stock and accounts are updated now.' : 'Approve this purchase order?';
            if (!(await QC.confirm('Approve ' + h.DocNo + '?', t, 'Approve'))) return; return act('Approve');
        }
        if (k === 'Post') { if (!(await QC.confirm('Post ' + h.DocNo + '?', D.primary.ask || 'Stock is updated now.', 'Post'))) return; return act('Post'); }
        if (k === 'Dispatch') { if (!(await QC.confirm('Dispatch ' + h.DocNo + '?', 'The stock leaves ' + h.StoreName + ' now; ' + h.ToStoreName + ' receives it.', 'Dispatch'))) return; return act('Dispatch'); }
        if (k === 'DispatchReceive') { if (!(await QC.confirm('Dispatch and receive ' + h.DocNo + '?', 'The stock moves to ' + h.ToStoreName + ' at once.', 'Yes'))) return; return act('DispatchReceive', { receiveNow: true }); }
        if (k === 'Receive') {
            const data = [...document.querySelectorAll('#vwBody .rcv-q')].map(i => ({ LineId: +i.dataset.line, ReceivedQty: i.value === '' ? 0 : +i.value }));
            const short = data.filter(d => { const l = cur.lines.find(x => x.LineId === d.LineId); return l && d.ReceivedQty + 0.0001 < n(l.BaseQty); }).length;
            if (!(await QC.confirm('Receive ' + h.DocNo + '?', short ? `${short} line(s) received short: the difference is written off as a transit loss.` : 'Everything sent is received into ' + h.ToStoreName + '.', 'Receive'))) return;
            return act('Receive', { data });
        }
        if (k === 'Submit') return act('Submit');
    });

    // ── physical count start ──────────────────────────────────────────────────────────────────────────────────
    if (T === 'CNT') {
        const cm = new bootstrap.Modal(document.getElementById('cntModal'));
        document.getElementById('cntStore').innerHTML = QC.options(mine.map(s => ({ Id: s.StoreId, Name: s.StoreName })), (mine.find(s => s.StoreType === 'Main') || {}).StoreId, '-- Store --');
        document.getElementById('cntCategory').innerHTML = QC.options(L.categories || [], '', 'All categories');
        document.getElementById('btnNew')?.addEventListener('click', () => cm.show());
        document.getElementById('cntCreate').addEventListener('click', async function () {
            const sid = +document.getElementById('cntStore').value; if (!sid) return QC.fail('Select the store.');
            this.disabled = true;
            const r = await QC.post(url('Create'), { storeId: sid, categoryId: +document.getElementById('cntCategory').value || null,
                includeZero: document.getElementById('cntZero').checked, remarks: document.getElementById('cntRemarks').value });
            this.disabled = false;
            if (!r.success) return QC.fail(r.message);
            cm.hide(); QC.ok('Count sheet ' + r.data.DocNo + ' created'); load(); view(r.data.DocId);
        });
    } else document.getElementById('btnNew')?.addEventListener('click', () => openEditor(null));

    // ── start ─────────────────────────────────────────────────────────────────────────────────────────────────
    load().then(() => {
        const q = new URLSearchParams(location.search);
        if (C.open) view(+C.open);
        else if (T === 'GRN' && q.get('fromPo') && P.ADD) { openEditor(null); ed.head.RefDocId = +q.get('fromPo'); loadOrder(+q.get('fromPo')); }
        else if (T === 'ISS' && q.get('fromIndent') && P.ADD) { openEditor(null); ed.head.RefDocId = +q.get('fromIndent'); loadIndent(+q.get('fromIndent')); }
    });
})();
