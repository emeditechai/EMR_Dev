// Pharmacy > Purchase document form (indent / order / GRN / return) - SQLScripts/2344.
// Builds the line grid, the item / batch picker and the totals; on save the whole document goes to the server as JSON.
// Amounts here are a preview only: the server works them out again.
(function () {
    'use strict';
    const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
    const num = v => { const n = parseFloat(v); return isFinite(n) ? n : 0; };
    const r2 = v => Math.round((v + Number.EPSILON) * 100) / 100;
    const money = v => r2(v).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const qtyFmt = v => (Math.round(v * 1000) / 1000).toLocaleString('en-IN');
    const monthVal = d => d ? String(d).substring(0, 7) : '';
    const fmtMonth = d => d ? new Date(d).toLocaleDateString('en-GB', { month: 'short', year: 'numeric' }) : '';
    const pascal = o => { const r = {}; for (const k in o) r[k.charAt(0).toUpperCase() + k.slice(1)] = o[k]; return r; };

    const COLS = {
        indent: ['item', 'stock', 'reorder', 'qty', 'remarks'],
        po: ['item', 'stock', 'qty', 'free', 'rate', 'disc', 'gst', 'taxable', 'total'],
        grn: ['item', 'batch', 'expiry', 'mrp', 'qty', 'free', 'rate', 'disc', 'gst', 'taxable', 'total'],
        return: ['batchitem', 'expiry', 'mrp', 'stock', 'rqty', 'urate', 'gst', 'taxable', 'total']
    };
    const HEAD = {
        item: ['Item', ''], batchitem: ['Item / batch', ''], stock: ['Stock', 'text-end'], reorder: ['Reorder', 'text-end'], qty: ['Qty (packs)', 'text-end'],
        rqty: ['Return qty', 'text-end'], free: ['Free', 'text-end'], rate: ['Rate / pack', 'text-end'], urate: ['Rate / unit', 'text-end'], disc: ['Disc %', 'text-end'],
        gst: ['GST %', 'text-end'], taxable: ['Taxable', 'text-end'], total: ['Amount', 'text-end'], batch: ['Batch no.', ''], expiry: ['Expiry', ''],
        mrp: ['MRP / pack', 'text-end'], remarks: ['Remarks', '']
    };

    window.PhDocForm = function (cfg) {
        const kind = cfg.kind, editable = cfg.editable, doc = cfg.doc;
        const lines = (doc.Lines || []).map(l => Object.assign({}, l));
        const grnLike = kind === 'grn' || !!cfg.direct;   // stock comes in on this document
        const cols = kind === 'po' && cfg.direct ? COLS.grn : COLS[kind];
        const table = document.getElementById('phLines');
        const $ = id => document.getElementById(id);
        const inter = () => $('IsInterState') ? $('IsInterState').checked : false;
        const minExpiry = new Date(); minExpiry.setDate(minExpiry.getDate() + (cfg.minShelfDays || 0));

        table.querySelector('thead').innerHTML = '<tr><th style="width:40px">#</th>' + cols.map(c => `<th class="${HEAD[c][1]}">${HEAD[c][0]}</th>`).join('') + (editable ? '<th style="width:40px"></th>' : '') + '</tr>';
        const tbody = table.querySelector('tbody');

        function packs(l) { return l.ConversionQty > 1 ? ` <span class="text-muted small">(${qtyFmt(num(l.Stock) / l.ConversionQty)} ${esc(l.PurchaseUom)})</span>` : ''; }
        function price(l) {
            if (kind === 'indent') return;
            const q = num(l.Qty), rate = num(l.Rate), disc = kind === 'return' ? 0 : num(l.DiscPercent);
            l.TaxableAmount = r2(q * rate * (1 - disc / 100));
            l.GstAmount = r2(l.TaxableAmount * num(l.GstPercent) / 100);
        }
        function rowWarn(l) {
            const w = [];
            if (grnLike) {
                if (l.ExpiryDate && new Date(l.ExpiryDate) < minExpiry) w.push(`Short expiry: less than ${cfg.minShelfDays} days`);
                const cost = num(l.Rate) * (1 - num(l.DiscPercent) / 100) * (1 + num(l.GstPercent) / 100);
                if (num(l.Mrp) > 0 && cost > num(l.Mrp)) w.push(`Cost with GST ₹${cost.toFixed(2)} is above MRP`);
                if (l.PoDtlId && num(l.Qty) > num(l.PendingQty)) w.push(`More than pending on order (${qtyFmt(num(l.PendingQty))})`);
                if (num(l.LastMrp) > 0 && num(l.Mrp) > 0 && num(l.Mrp) !== num(l.LastMrp)) w.push(`MRP changed from last purchase (₹${money(num(l.LastMrp))})`);
            }
            if (kind === 'return' && num(l.Qty) > num(l.Stock)) w.push('More than stock');
            return w;
        }
        const inp = (i, f, v, attrs = '', cls = 'text-end') => `<input class="form-control form-control-sm ${cls}" data-i="${i}" data-f="${f}" value="${esc(v)}" ${attrs}>`;
        const n = (i, f, v, step = '0.01', w = 80) => editable ? inp(i, f, v === 0 || v ? v : '', `type="number" min="0" step="${step}" style="width:${w}px;margin-left:auto"`) : qtyFmt(num(v));

        function cell(c, l, i) {
            switch (c) {
                case 'item':
                    return `<div class="fw-semibold">${l.FormShort ? `<span class="ph-form-tag">${esc(l.FormShort)}</span>` : ''}${esc(l.ItemName)}</div>
                            <div class="small text-muted">${esc(l.ItemCode || '')} · 1 ${esc(l.PurchaseUom)} = ${l.ConversionQty} ${esc(l.SaleUom)}${l.PoDtlId ? ` · <span class="text-primary">pending on PO ${qtyFmt(num(l.PendingQty))}</span>` : ''}
                            ${cfg.urls.rateHistory && (kind === 'po' || kind === 'grn') ? `<button type="button" class="btn btn-link btn-sm p-0 ms-1 align-baseline" data-hist="${l.ItemId}" data-name="${esc(l.ItemName)}" title="Purchase rate history"><i class="bi bi-clock-history"></i> rates</button>` : ''}</div>`;
                case 'batchitem':
                    return `<div class="fw-semibold">${l.FormShort ? `<span class="ph-form-tag">${esc(l.FormShort)}</span>` : ''}${esc(l.ItemName)}</div><div class="small text-muted">Batch <b>${esc(l.BatchNo)}</b></div>`;
                case 'stock': return `<span class="text-nowrap">${qtyFmt(num(l.Stock))} ${esc(l.SaleUom || '')}${kind === 'return' ? '' : packs(l)}</span>`;
                case 'reorder': return `<span class="text-muted">${qtyFmt(num(l.ReorderLevel))}</span>`;
                case 'qty': return n(i, 'Qty', l.Qty);
                case 'rqty': return editable ? `<div class="input-group input-group-sm justify-content-end">${inp(i, 'Qty', l.Qty || '', `type="number" min="0" step="1" max="${num(l.Stock)}" style="max-width:80px"`)}<span class="input-group-text">${esc(l.SaleUom || '')}</span></div>` : `${qtyFmt(num(l.Qty))} ${esc(l.SaleUom || '')}`;
                case 'free': return n(i, 'FreeQty', l.FreeQty, '1', 64);
                case 'rate': return n(i, 'Rate', l.Rate, '0.0001', 92);
                case 'urate': return money(num(l.Rate));
                case 'disc': return n(i, 'DiscPercent', l.DiscPercent, '0.01', 64);
                case 'gst':
                    if (!editable || kind === 'return') return `${num(l.GstPercent)}%`;
                    return `<select class="form-select form-select-sm" data-i="${i}" data-f="GstPercent" style="width:72px;margin-left:auto">${[0, 5, 12, 18, 28].map(g => `<option value="${g}" ${num(l.GstPercent) === g ? 'selected' : ''}>${g}%</option>`).join('')}</select>`;
                case 'taxable': return money(num(l.TaxableAmount));
                case 'total': {
                    let m = '';
                    if (grnLike && num(l.Mrp) > 0 && num(l.Qty) > 0) {   // margin on MRP, both before GST, free goods spread
                        const landed = num(l.TaxableAmount) / (num(l.Qty) + num(l.FreeQty)), mrpEx = num(l.Mrp) / (1 + num(l.GstPercent) / 100);
                        const pct = (mrpEx - landed) / mrpEx * 100;
                        m = `<div class="small ${pct < 10 ? 'text-danger' : 'text-success'}" title="Landed cost ₹${landed.toFixed(2)} / pack before GST">Margin ${pct.toFixed(1)}%</div>`;
                    }
                    return `<b>${money(num(l.TaxableAmount) + num(l.GstAmount))}</b>${m}`;
                }
                case 'batch': return editable ? inp(i, 'BatchNo', l.BatchNo || '', 'maxlength="30" style="width:110px" placeholder="Batch"', 'text-uppercase') : `<span class="font-monospace">${esc(l.BatchNo)}</span>`;
                case 'expiry':
                    if (grnLike && editable) return inp(i, 'ExpiryDate', monthVal(l.ExpiryDate), 'type="month" style="width:130px"', '');
                    return fmtMonth(l.ExpiryDate);
                case 'mrp': return grnLike ? n(i, 'Mrp', l.Mrp, '0.01', 86) : money(num(l.Mrp));
                case 'remarks': return editable ? inp(i, 'Remarks', l.Remarks || '', 'maxlength="200"', '') : esc(l.Remarks || '');
            }
            return '';
        }

        function render() {
            tbody.innerHTML = lines.map((l, i) => {
                price(l);
                const w = rowWarn(l);
                return `<tr class="${w.length ? 'table-warning' : ''}" title="${esc(w.join('; '))}"><td class="text-muted small">${i + 1}${w.length ? ' <i class="bi bi-exclamation-triangle-fill text-warning"></i>' : ''}</td>`
                    + cols.map(c => `<td class="${HEAD[c][1]}">${cell(c, l, i)}</td>`).join('')
                    + (editable ? `<td><button type="button" class="btn btn-sm btn-link text-danger p-0" data-del="${i}" title="Remove line"><i class="bi bi-x-circle"></i></button></td>` : '') + '</tr>';
            }).join('') + (editable ? `<tr class="ph-newrow"><td class="text-muted small">${lines.length + 1}</td><td colspan="${cols.length + 1}"><div class="position-relative" style="max-width:560px">
                <div class="input-group input-group-sm"><span class="input-group-text"><i class="bi ${kind === 'return' ? 'bi-upc-scan' : 'bi-plus-lg'}"></i></span>
                <input id="phPick" class="form-control" placeholder="${kind === 'return' ? 'Add batch: type item, batch or scan barcode (F2)' : 'Add item: type brand, generic or scan barcode (F2)'}" autocomplete="off"></div>
                <div id="phPickList" class="list-group position-absolute w-100 shadow d-none" style="z-index:30;max-height:340px;overflow:auto"></div></div></td></tr>` : '');
            totals();
            if (editable) bindPicker();
        }

        // Bill amount follows the net total until the user types their own (clearing it goes back to automatic)
        const billBox = $('InvoiceAmount');
        let billAuto = !!billBox && (!num(billBox.value) || num(billBox.value) === num(doc.NetAmount));
        if (billBox && editable) billBox.addEventListener('input', () => { billAuto = billBox.value.trim() === ''; totals(); });

        function totals() {
            let taxable = 0, gst = 0;
            lines.forEach(l => { taxable += num(l.TaxableAmount); gst += num(l.GstAmount); });
            const other = $('OtherCharges') ? num($('OtherCharges').value) : 0;
            const exact = taxable + gst + other, net = kind === 'po' && !cfg.direct ? r2(exact) : Math.round(exact);
            const set = (id, v) => { if ($(id)) $(id).textContent = v; };
            set('tTaxable', money(taxable));
            set('tCgst', inter() ? '—' : money(r2(gst / 2)));
            set('tSgst', inter() ? '—' : money(gst - r2(gst / 2)));
            set('tIgst', inter() ? money(gst) : '—');
            set('tRound', money(net - exact));
            set('tNet', '₹ ' + money(net));
            set('tLines', `${lines.length} item(s)`);
            if (billBox && billAuto && editable) billBox.value = lines.length ? net.toFixed(2) : '';
            if ($('InvoiceAmount') && $('tDiff')) {
                const diff = r2(num($('InvoiceAmount').value) - net);
                $('tDiff').innerHTML = Math.abs(diff) <= 1 ? '<span class="text-success"><i class="bi bi-check-circle-fill me-1"></i>Matches the supplier bill</span>'
                    : `<span class="text-danger"><i class="bi bi-x-circle-fill me-1"></i>Differs from the bill by ₹${money(diff)}</span>`;
            }
        }

        // ── edits ──
        tbody.addEventListener('input', e => {
            const t = e.target; if (!t.dataset.f) return;
            const l = lines[t.dataset.i];
            l[t.dataset.f] = t.dataset.f === 'ExpiryDate' ? (t.value ? t.value + '-01' : null) : t.dataset.f === 'BatchNo' ? t.value.toUpperCase() : t.dataset.f === 'Remarks' ? t.value : num(t.value);
            price(l);
            const tr = t.closest('tr'), w = rowWarn(l);
            tr.classList.toggle('table-warning', w.length > 0); tr.title = w.join('; ');
            const ti = cols.indexOf('taxable'), to = cols.indexOf('total');
            if (ti >= 0) tr.children[ti + 1].innerHTML = cell('taxable', l, t.dataset.i);
            if (to >= 0) tr.children[to + 1].innerHTML = cell('total', l, t.dataset.i);
            totals();
        });
        tbody.addEventListener('change', e => { if (e.target.dataset.f === 'GstPercent') { lines[e.target.dataset.i].GstPercent = num(e.target.value); render(); } });
        tbody.addEventListener('click', e => { const b = e.target.closest('[data-del]'); if (b) { lines.splice(+b.dataset.del, 1); render(); focusPicker(); } });
        tbody.addEventListener('click', async e => {
            const h = e.target.closest('[data-hist]'); if (!h) return;
            const rows = await fetch(cfg.urls.rateHistory + '?itemId=' + h.dataset.hist).then(r => r.json()).catch(() => []);
            const d = v => new Date(v).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: '2-digit' });
            Swal.fire({ title: h.dataset.name, width: 820, html: rows.length
                ? `<table class="table table-sm small text-start mb-0"><thead><tr><th>Date</th><th>Supplier</th><th>Batch</th><th class="text-end">Qty+Free</th><th class="text-end">Rate</th><th class="text-end">Disc</th><th class="text-end">Net rate</th><th class="text-end">MRP</th></tr></thead><tbody>`
                  + rows.map(r => `<tr><td>${d(r.grnDate)}</td><td>${esc(r.supplierName)}</td><td>${esc(r.batchNo)}</td><td class="text-end">${qtyFmt(r.qty)}+${qtyFmt(r.freeQty)}</td><td class="text-end">${money(r.rate)}</td><td class="text-end">${r.discPercent}%</td><td class="text-end fw-bold">${money(r.netRate)}</td><td class="text-end">${money(r.mrp)}</td></tr>`).join('')
                  + '</tbody></table><div class="small text-muted text-start mt-1">Net rate = rate after discount, spread over free goods.</div>'
                : 'No earlier purchase of this item.' });
        });
        tbody.addEventListener('keydown', e => {   // Enter moves along the row, then to the picker
            if (e.key !== 'Enter' || !e.target.dataset.f) return;
            e.preventDefault();
            const ins = [...e.target.closest('tr').querySelectorAll('input,select')];
            const k = ins.indexOf(e.target);
            if (k < ins.length - 1) { ins[k + 1].focus(); ins[k + 1].select && ins[k + 1].select(); } else focusPicker();
        });
        ['IsInterState', 'OtherCharges'].forEach(id => $(id) && $(id).addEventListener('input', totals));
        $('IsInterState') && $('IsInterState').addEventListener('change', totals);

        // ── picker ──
        function focusPicker() { const p = $('phPick'); p && p.focus(); }
        function addItem(it) {
            it = pascal(it);
            if (kind === 'return') {
                if (lines.some(l => l.BatchId === it.BatchId)) { flash('This batch is already on the return.'); return; }
                lines.push({ BatchId: it.BatchId, ItemId: it.ItemId, ItemName: it.ItemName, FormShort: it.FormShort, BatchNo: it.BatchNo, ExpiryDate: it.ExpiryDate, Mrp: it.Mrp,
                    Rate: it.RatePerUnit, GstPercent: it.GstPercent, Stock: it.Stock, SaleUom: it.SaleUom, ConversionQty: it.ConversionQty, Qty: null });
            } else {
                if (!grnLike && lines.some(l => l.ItemId === it.ItemId)) { flash('This item is already on the list.'); return; }
                const l = { ItemId: it.ItemId, ItemName: it.ItemName, ItemCode: it.ItemCode, FormShort: it.FormShort, PurchaseUom: it.PurchaseUom, SaleUom: it.SaleUom,
                    ConversionQty: it.ConversionQty, Stock: it.Stock, ReorderLevel: it.ReorderLevel, GstPercent: it.GstPercent, Rate: it.LastRate || 0, Mrp: it.LastMrp || 0, LastMrp: it.LastMrp || 0,
                    Qty: kind === 'indent' ? suggest(it) : null, FreeQty: 0, DiscPercent: 0 };
                lines.push(l);
            }
            render();
            const tr = tbody.querySelectorAll('tr')[lines.length - 1];
            const first = tr && tr.querySelector('input,select'); first && (first.focus(), first.select && first.select());
        }
        function suggest(it) {
            const have = num(it.Stock) / Math.max(1, it.ConversionQty) + num(it.PendingPoQty);
            const target = num(it.MaxQty) > 0 ? num(it.MaxQty) : num(it.ReorderLevel) * 2;
            return Math.max(1, Math.ceil(target - have));
        }
        function flash(msg) { if (window.Swal) Swal.fire({ toast: true, position: 'top-end', icon: 'info', title: msg, timer: 2200, showConfirmButton: false }); }
        let timer, results = [], active = -1;
        function bindPicker() {
            const p = $('phPick'), list = $('phPickList');
            if (!p) return;
            p.addEventListener('input', () => {
                clearTimeout(timer);
                const q = p.value.trim();
                if (q.length < 2) { list.classList.add('d-none'); return; }
                timer = setTimeout(async () => {
                    const sup = $('SupplierId') ? $('SupplierId').value : '';
                    const url = (kind === 'return' ? cfg.urls.batchSearch + '?supplierId=' + encodeURIComponent(sup) + '&q=' : cfg.urls.itemSearch + '?q=') + encodeURIComponent(q);
                    results = await fetch(url).then(r => r.ok ? r.json() : []).catch(() => []);
                    active = results.length ? 0 : -1;
                    draw();
                    if (results.length === 1 && /^\d{8,14}$/.test(q)) { addItem(results[0]); }   // scanned barcode
                }, 250);
            });
            p.addEventListener('keydown', e => {
                if (list.classList.contains('d-none')) return;
                if (e.key === 'ArrowDown') { e.preventDefault(); active = Math.min(results.length - 1, active + 1); draw(); }
                else if (e.key === 'ArrowUp') { e.preventDefault(); active = Math.max(0, active - 1); draw(); }
                else if (e.key === 'Enter') { e.preventDefault(); if (results[active]) addItem(results[active]); }
                else if (e.key === 'Escape') list.classList.add('d-none');
            });
            list.addEventListener('mousedown', e => { const a = e.target.closest('[data-k]'); if (a) { e.preventDefault(); addItem(results[a.dataset.k]); } });
            p.addEventListener('blur', () => setTimeout(() => list.classList.add('d-none'), 150));
            function draw() {
                if (!results.length) {
                    list.innerHTML = '<div class="list-group-item small text-muted">Nothing found.' + (cfg.urls.newItem && kind !== 'return'
                        ? ` <a href="${cfg.urls.newItem}" target="_blank" class="ms-1"><i class="bi bi-plus-circle"></i> Create a new item</a> (then search again)` : '') + '</div>';
                    list.classList.remove('d-none'); return;
                }
                list.innerHTML = results.map((r, k) => kind === 'return'
                    ? `<a href="#" class="list-group-item list-group-item-action py-1 ${k === active ? 'active' : ''}" data-k="${k}"><div class="d-flex justify-content-between"><span class="fw-semibold">${r.formShort ? esc(r.formShort) + ' ' : ''}${esc(r.itemName)}</span><span class="small">Stock ${qtyFmt(r.stock)} ${esc(r.saleUom)}</span></div>
                       <div class="small ${k === active ? '' : 'text-muted'}">Batch ${esc(r.batchNo)} · Exp ${fmtMonth(r.expiryDate)} · MRP ₹${money(r.mrp)} · ${esc(r.supplierName || '')}</div></a>`
                    : `<a href="#" class="list-group-item list-group-item-action py-1 ${k === active ? 'active' : ''}" data-k="${k}"><div class="d-flex justify-content-between"><span class="fw-semibold">${r.formShort ? esc(r.formShort) + ' ' : ''}${esc(r.itemName)} <span class="badge sch sch-${esc(r.scheduleCode)}">${esc(r.scheduleCode)}</span></span><span class="small">Stock ${qtyFmt(r.stock)} ${esc(r.saleUom)}</span></div>
                       <div class="small ${k === active ? '' : 'text-muted'}">${esc(r.genericName || '')} · ${esc(r.manufacturerName || '')} · 1 ${esc(r.purchaseUom)} = ${r.conversionQty} ${esc(r.saleUom)}${r.lastRate ? ` · last rate ₹${money(r.lastRate)} (${esc(r.lastSupplier || '')})` : ''}</div></a>`).join('');
                list.classList.remove('d-none');
                const a = list.querySelector('.active'); a && a.scrollIntoView({ block: 'nearest' });
            }
        }
        document.addEventListener('keydown', e => { if (e.key === 'F2' && editable) { e.preventDefault(); focusPicker(); } });

        // ── header helpers ──
        async function supplierChanged() {
            const id = $('SupplierId') && $('SupplierId').value;
            if (!id) return;
            const s = await fetch(cfg.urls.supplierInfo + '?id=' + id).then(r => r.json()).catch(() => null);
            if (!s) return;
            if ($('IsInterState')) { $('IsInterState').checked = !!s.isInterState; totals(); }
            if ($('supWarn')) $('supWarn').innerHTML = s.warning ? `<i class="bi bi-exclamation-triangle-fill text-warning me-1"></i>${esc(s.warning)}` : (s.creditDays ? `Credit ${s.creditDays} days${s.gstin ? ' · GSTIN ' + esc(s.gstin) : ''}` : '');
            if (kind === 'grn' && $('RefId')) {
                const pos = await fetch(cfg.urls.openPos + '?supplierId=' + id).then(r => r.json()).catch(() => []);
                $('RefId').innerHTML = '<option value="">— direct purchase (no PO) —</option>' + pos.map(p => `<option value="${p.value}">${esc(p.text)}</option>`).join('');
            }
        }
        if (editable && $('SupplierId')) {
            if (window.TomSelect && !$('SupplierId').tomselect) new TomSelect($('SupplierId'), { maxOptions: 500, onChange: supplierChanged });
            else $('SupplierId').addEventListener('change', supplierChanged);
        }
        if (editable && kind === 'grn' && $('RefId')) $('RefId').addEventListener('change', async () => {
            const po = $('RefId').value;
            if (!po) { lines.filter(l => l.PoDtlId).forEach(l => l.PoDtlId = null); render(); return; }
            if (lines.length && !confirm('Replace the lines with the items pending on this order?')) return;
            const got = await fetch(cfg.urls.poLines + '?poId=' + po).then(r => r.json()).catch(() => []);
            lines.length = 0; got.map(pascal).forEach(l => lines.push(l)); render();
        });
        const reorder = $('btnReorder');
        reorder && reorder.addEventListener('click', async () => {
            const got = await fetch(cfg.urls.reorder).then(r => r.json()).catch(() => []);
            let added = 0;
            got.forEach(it => { if (!lines.some(l => l.ItemId === it.itemId)) { const p = pascal(it); lines.push({ ItemId: p.ItemId, ItemName: p.ItemName, ItemCode: p.ItemCode, FormShort: p.FormShort, PurchaseUom: p.PurchaseUom, SaleUom: p.SaleUom, ConversionQty: p.ConversionQty, Stock: p.Stock, ReorderLevel: p.ReorderLevel, Qty: suggest(it) }); added++; } });
            render();
            flash(added ? `${added} item(s) at or below reorder level added.` : 'No other item is at or below its reorder level.');
        });

        // ── GRN lines from the distributor's Excel / CSV ──
        const COLS_IMPORT = ['Item Code / Barcode / Name', 'Batch', 'Expiry (MM/YYYY)', 'MRP', 'Qty', 'Free', 'Rate', 'Disc %', 'GST %'];
        const tpl = $('btnTemplate');
        tpl && tpl.addEventListener('click', () => {
            const ws = XLSX.utils.aoa_to_sheet([COLS_IMPORT, ['PH00001', 'DL2401', '06/2027', 32.5, 10, 1, 21.5, 0, 5]]);
            const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, 'GRN lines'); XLSX.writeFile(wb, 'GRN_import_template.xlsx');
        });
        const imp = $('importFile');
        imp && imp.addEventListener('change', async () => {
            const file = imp.files[0]; if (!file) return;
            const wb = XLSX.read(await file.arrayBuffer(), { type: 'array', cellDates: true });
            const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, raw: true }).slice(1).filter(r => r && r.length && r[0] !== undefined && r[0] !== '');
            const missed = []; let added = 0;
            for (const r of rows) {
                const key = String(r[0]).trim();
                const found = await fetch(cfg.urls.itemSearch + '?q=' + encodeURIComponent(key)).then(x => x.json()).catch(() => []);
                const it = found.find(f => [f.itemCode, f.itemName].some(v => String(v || '').toLowerCase() === key.toLowerCase())) || (found.length === 1 ? found[0] : null);
                if (!it) { missed.push(key); continue; }
                let exp = r[2];
                if (exp instanceof Date) exp = exp.toISOString().substring(0, 7) + '-01';
                else { const m = String(exp || '').match(/^(\d{1,2})[\/\-](\d{2,4})$/); exp = m ? `${m[2].length === 2 ? '20' + m[2] : m[2]}-${m[1].padStart(2, '0')}-01` : null; }
                const p = pascal(it);
                lines.push({ ItemId: p.ItemId, ItemName: p.ItemName, ItemCode: p.ItemCode, FormShort: p.FormShort, PurchaseUom: p.PurchaseUom, SaleUom: p.SaleUom, ConversionQty: p.ConversionQty,
                    Stock: p.Stock, LastMrp: p.LastMrp || 0, BatchNo: String(r[1] || '').toUpperCase(), ExpiryDate: exp, Mrp: num(r[3]), Qty: num(r[4]), FreeQty: num(r[5]), Rate: num(r[6]),
                    DiscPercent: num(r[7]), GstPercent: r[8] === undefined || r[8] === '' ? p.GstPercent : num(r[8]) });
                added++;
            }
            imp.value = '';
            render();
            Swal.fire({ icon: missed.length ? 'warning' : 'success', title: `${added} line(s) imported`,
                html: missed.length ? `Not found in the Item Master (add them by hand):<br><b>${missed.map(esc).join(', ')}</b>` : 'Check batch, expiry and rates before saving.' });
        });

        // ── save ──
        const form = $('phDocForm');
        form && form.addEventListener('submit', e => {
            const val = id => $(id) ? $(id).value || null : undefined;
            const d = {
                Id: doc.Id, DocDate: val('DocDate'), SupplierId: val('SupplierId') ? +val('SupplierId') : null, RefId: val('RefId') ? +val('RefId') : (doc.RefId || null),
                ExpectedDate: val('ExpectedDate'), Priority: val('Priority'), IsInterState: inter(), InvoiceNo: val('InvoiceNo'), InvoiceDate: val('InvoiceDate'),
                InvoiceAmount: num(val('InvoiceAmount')), OtherCharges: num(val('OtherCharges')), ReasonId: val('ReasonId') ? +val('ReasonId') : null,
                Terms: val('Terms'), Remarks: val('Remarks'), Lines: lines
            };
            if (!lines.length) { e.preventDefault(); flash('Add at least one line.'); focusPicker(); return; }
            $('phJson').value = JSON.stringify(d);
        });
        window.addEventListener('keydown', e => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's' && editable && form) { e.preventDefault(); form.requestSubmit(); } });

        render();
        if (editable && !lines.length) setTimeout(focusPicker, 100);
    };
})();
