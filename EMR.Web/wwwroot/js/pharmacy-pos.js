// Pharmacy > Sales > POS (SQLScripts/2348). Keyboard-first counter billing. Amounts are a preview with the same rules as the
// server (PharmacySaleService), which works everything out again when the bill is saved.
(function () {
    'use strict';
    const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
    const num = v => { const n = parseFloat(v); return isFinite(n) ? n : 0; };
    const r2 = v => Math.round((v + Number.EPSILON) * 100) / 100;
    const money = v => r2(v).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const q3 = v => (Math.round(v * 1000) / 1000).toLocaleString('en-IN');
    const mon = d => d ? new Date(d).toLocaleDateString('en-GB', { month: 'short', year: '2-digit' }) : '';
    const $ = id => document.getElementById(id);
    const token = () => document.querySelector('input[name="__RequestVerificationToken"]').value;
    const toast = (icon, title) => Swal.fire({ toast: true, position: 'top-end', icon, title, timer: 2200, showConfirmButton: false });
    const getJson = url => fetch(url, { headers: { 'X-Requested-With': 'XMLHttpRequest' } }).then(r => r.ok ? r.json() : []).catch(() => []);
    const postJson = (url, body) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': token(), 'X-Requested-With': 'XMLHttpRequest' }, body: JSON.stringify(body) })
        .then(async r => r.ok ? r.json() : { error: r.status === 403 ? 'You do not have permission for this action.' : 'The server could not save it (' + r.status + ').' });

    window.PhPos = function (cfg) {
        let kind = 'WALKIN', patient = null, customer = null, doctorId = null, holdId = null, seq = 0;
        let lines = [], pays = [];

        // ── counter (selling store): remembered per branch on this computer; changing it empties the bill ──
        const storeSel = $('posStore');
        const storeKey = 'phPosStore:' + (cfg.branchId || '');
        try { const saved = localStorage.getItem(storeKey); if (saved && storeSel && storeSel.tagName === 'SELECT' && [...storeSel.options].some(o => o.value === saved)) storeSel.value = saved; } catch { }
        const storeQ = () => storeSel && storeSel.value ? '&storeId=' + encodeURIComponent(storeSel.value) : '';
        if (storeSel && storeSel.tagName === 'SELECT') storeSel.addEventListener('change', () => {
            try { localStorage.setItem(storeKey, storeSel.value); } catch { }
            if (lines.length) { reset(); toast('info', 'Counter changed: the bill was cleared.'); }
        });

        // ── customer ─────────────────────────────────────────────────────────────────────────────────
        function renderCustomer() {
            const box = $('custBox');
            if (kind === 'WALKIN') {
                box.innerHTML = `<div class="row g-2"><div class="col-md-4"><label class="form-label">Name</label><input id="wName" class="form-control" placeholder="Customer name" maxlength="150"></div>
                    <div class="col-md-3"><label class="form-label">Mobile</label><input id="wMobile" class="form-control num" placeholder="Bill on WhatsApp" maxlength="10" inputmode="numeric"></div>
                    <div class="col-md-5"><label class="form-label">Address</label><input id="wAddress" class="form-control" placeholder="Needed for Schedule H1 / X" maxlength="300"></div></div>`;
                $('wName').addEventListener('input', rxCheck); $('wAddress').addEventListener('input', rxCheck);
            } else {
                const sel = kind === 'PATIENT' ? patient : customer;
                if (sel) {
                    box.innerHTML = `<label class="form-label">${kind === 'PATIENT' ? 'Patient' : 'Credit customer'}</label><div class="pos-chip"><div class="text-truncate"><i class="bi ${kind === 'PATIENT' ? 'bi-person-vcard' : 'bi-wallet2'} me-1" style="color:var(--pos-accent)"></i><b>${esc(sel.name)}</b>
                        <span class="small text-muted ms-1">${kind === 'PATIENT' ? 'UHID ' + esc(sel.uhid) + ' · ' : ''}${esc(sel.mobile || '')}</span>
                        ${kind === 'CUSTOMER' ? `<span class="small ms-2 ${sel.credit ? 'text-success' : 'text-muted'}">${sel.credit ? `credit limit ₹${money(sel.creditLimit)} · due ₹${money(sel.outstanding)}` : 'no credit'}</span>` : ''}
                        ${kind === 'CUSTOMER' && sel.type === 'STAFF' ? '<span class="badge bg-info-subtle text-info-emphasis ms-1">staff price</span>' : ''}</div>
                        <button type="button" class="btn btn-sm btn-link p-0" id="custChange">Change</button></div>`;
                    $('custChange').onclick = () => { if (kind === 'PATIENT') patient = null; else customer = null; renderCustomer(); refreshPrices(); };
                } else {
                    box.innerHTML = `<label class="form-label">${kind === 'PATIENT' ? 'Find patient' : 'Find credit customer'}</label><div class="position-relative"><input id="custSearch" class="form-control" autocomplete="off"
                        placeholder="${kind === 'PATIENT' ? 'UHID, mobile or name (F4)' : 'Name or mobile (F4)'}">
                        <div id="custList" class="pos-drop simple d-none"></div></div>`;
                    picker($('custSearch'), $('custList'), q => getJson((kind === 'PATIENT' ? cfg.urls.patients : cfg.urls.customers) + '?q=' + encodeURIComponent(q)),
                        r => `<div><div class="nm">${esc(r.name)}</div><div class="sub">${kind === 'PATIENT' ? 'UHID ' + esc(r.uhid) + (r.lastDoctor ? ' · last seen by ' + esc(r.lastDoctor) : '') : (r.credit ? 'credit ₹' + money(r.creditLimit) + ' · due ₹' + money(r.outstanding) : 'no credit')}</div></div>
                              <span class="sub num">${esc(r.mobile || '')}</span>`,
                        r => {
                            if (kind === 'PATIENT') { patient = r; if (r.lastDoctor && !$('docName').value) { $('docName').value = r.lastDoctor; doctorId = r.lastDoctorId; } }
                            else customer = r;
                            renderCustomer(); refreshPrices(); focusSearch();
                        }, 1);
                }
            }
            rxCheck();
        }
        document.querySelectorAll('input[name=ck]').forEach(r => r.addEventListener('change', () => { kind = r.value; renderCustomer(); refreshPrices(); totals(); }));
        const priceType = () => kind === 'CUSTOMER' && customer?.type === 'STAFF' ? 'STAFF' : 'WALKIN';

        // generic dropdown picker (keyboard)
        function picker(input, list, fetcher, row, pick, min = 2, head = '', rowClass = () => '') {
            let res = [], act = -1, t;
            const draw = () => {
                list.innerHTML = res.length ? head + res.map((r, k) => `<a href="#" class="dr ${k === act ? 'active' : ''} ${rowClass(r)}" data-k="${k}">${row(r)}</a>`).join('')
                    : '<div class="empty"><i class="bi bi-search me-1"></i>Nothing found.</div>';
                list.classList.remove('d-none');
                list.querySelector('.dr.active')?.scrollIntoView({ block: 'nearest' });
            };
            input.addEventListener('input', () => { clearTimeout(t); const q = input.value.trim(); if (q.length < min) { list.classList.add('d-none'); return; }
                t = setTimeout(async () => { res = await fetcher(q); act = res.length ? 0 : -1; draw(); }, 220); });
            input.addEventListener('keydown', e => {
                if (list.classList.contains('d-none')) return;
                if (e.key === 'ArrowDown') { e.preventDefault(); act = Math.min(res.length - 1, act + 1); draw(); }
                else if (e.key === 'ArrowUp') { e.preventDefault(); act = Math.max(0, act - 1); draw(); }
                else if (e.key === 'Enter') { e.preventDefault(); if (res[act]) { list.classList.add('d-none'); pick(res[act]); } }
                else if (e.key === 'Escape') list.classList.add('d-none');
            });
            list.addEventListener('mousedown', e => { const a = e.target.closest('[data-k]'); if (a) { e.preventDefault(); list.classList.add('d-none'); pick(res[a.dataset.k]); } });
            input.addEventListener('blur', () => setTimeout(() => list.classList.add('d-none'), 150));
        }

        // doctor
        picker($('docName'), $('docList'), q => getJson(cfg.urls.doctors + '?q=' + encodeURIComponent(q)), r => `<span class="nm">${esc(r.name)}</span><span class="sub">${esc(r.regNo || '')}</span>`,
            r => { $('docName').value = r.name; $('docReg').value = r.regNo || ''; doctorId = r.id; $('rxNo').focus(); });
        $('docName').addEventListener('input', () => { doctorId = null; rxCheck(); });
        $('rxNo').addEventListener('input', rxCheck);

        function rxCheck() {
            const rx = lines.some(l => l.item.rxRequired), reg = lines.some(l => l.item.registerRequired);
            $('docName').classList.toggle('rx-need', rx && !$('docName').value.trim());
            $('rxNo').classList.toggle('rx-need', rx && !$('rxNo').value.trim());
            $('docLbl').classList.toggle('req', rx); $('rxLbl').classList.toggle('req', rx);
            if (kind === 'WALKIN' && $('wName')) { $('wName').classList.toggle('rx-need', reg && !$('wName').value.trim()); $('wAddress').classList.toggle('rx-need', reg && !$('wAddress').value.trim()); }
            const w = lines.filter(l => l.item.labelWarning || l.item.isHighAlert || l.item.isLasa);
            $('rxWarn').classList.toggle('d-none', !rx && !w.length);
            $('rxWarn').innerHTML = (rx ? `<div class="alert alert-danger py-1 px-2 small"><i class="bi bi-prescription2 me-1"></i>An item needing a prescription is on the bill: doctor and prescription no. are required${reg ? '; Schedule H1 / X: patient name and address go to the register' : ''}.</div>` : '')
                + w.filter(l => l.item.isHighAlert || l.item.isLasa).map(l => `<div class="alert alert-warning py-1 px-2 small"><i class="bi bi-exclamation-octagon me-1"></i>${esc(l.item.itemName)}: ${l.item.isHighAlert ? 'HIGH-ALERT medicine - double check dose. ' : ''}${l.item.isLasa ? 'Look-alike / sound-alike - confirm the pack.' : ''}</div>`).join('');
        }

        // ── items ────────────────────────────────────────────────────────────────────────────────────
        const sch = c => `<span class="badge sch sch-${esc(c)}">${esc(c)}</span>`;
        const ITEM_HEAD = '<div class="dh"><span>Item</span><span>Generic · maker</span><span>Pack</span><span class="text-end">Stock</span><span class="text-end">MRP</span><span>Exp</span><span>Rack</span></div>';
        function itemRow(r) {
            const packs = r.conversionQty > 1 ? `<div class="sub">${q3(r.stock / r.conversionQty)} ${esc(r.purchaseUom)}</div>` : '';
            return `<span><div class="nm">${r.formShort ? `<span class="ph-form-tag">${esc(r.formShort)}</span>` : ''}${esc(r.itemName)} ${sch(r.scheduleCode)}
                        ${r.isColdChain ? '<i class="bi bi-snow text-info" title="cold chain"></i>' : ''}${r.isHighAlert ? ' <i class="bi bi-exclamation-octagon-fill text-danger" title="high alert"></i>' : ''}${r.isLasa ? ' <i class="bi bi-eye-fill text-warning" title="look-alike / sound-alike"></i>' : ''}</div>
                    ${r.strength ? `<div class="sub">${esc(r.strength)}</div>` : ''}</span>
                <span class="sub">${esc(r.genericName || '')}<div>${esc(r.manufacturerName || '')}</div></span>
                <span class="sub">${esc(r.packSize || (r.conversionQty > 1 ? r.conversionQty + ' ' + r.saleUom : r.saleUom))}</span>
                <span class="text-end num"><b class="${r.stock > 0 ? 'text-success' : 'text-danger'}">${r.stock > 0 ? q3(r.stock) + ' ' + esc(r.saleUom) : 'Nil'}</b>${r.stock > 0 ? packs : (r.genericId ? '<div class="sub"><u data-subs="' + r.genericId + '">substitutes</u></div>' : '')}</span>
                <span class="text-end num">${r.packMrp ? '₹' + money(r.packMrp) : '—'}</span>
                <span class="sub">${r.nearestExpiry ? mon(r.nearestExpiry) : ''}</span>
                <span class="sub">${esc(r.rackNo || '')}</span>`;
        }
        const search = $('itemSearch'), list = $('itemList');
        let lastResults = [];
        picker(search, list, async q => (lastResults = await getJson(cfg.urls.items + '?q=' + encodeURIComponent(q) + storeQ())), itemRow, addItem, 2, ITEM_HEAD, r => r.stock > 0 ? '' : 'oos');
        list.addEventListener('mousedown', async e => {
            const s = e.target.closest('[data-subs]');
            if (!s) return;
            e.preventDefault(); e.stopPropagation();
            const subs = await getJson(cfg.urls.items + '?genericId=' + s.dataset.subs + storeQ());
            list.innerHTML = '<div class="sec"><i class="bi bi-arrow-left-right me-1"></i>Substitutes - same generic, in stock first</div>' + ITEM_HEAD
                + subs.map((r, k) => `<a href="#" class="dr ${r.stock > 0 ? '' : 'oos'}" data-sub="${k}">${itemRow(r)}</a>`).join('');
            list.onmousedown = ev => { const a = ev.target.closest('[data-sub]'); if (a) { ev.preventDefault(); list.classList.add('d-none'); addItem(subs[a.dataset.sub]); list.onmousedown = null; } };
        }, true);
        const focusSearch = () => { search.value = ''; search.focus(); };

        async function addItem(it) {
            if (it.stock <= 0) { toast('warning', it.itemName + ' is out of stock. Try a substitute.'); return; }
            const existing = lines.find(l => l.item.itemId === it.itemId && !l.batchId);
            if (existing) { render(); const q = document.querySelector(`[data-key="${existing.key}"] [data-f=qty]`); q && (q.focus(), q.select()); return; }
            const batches = await getJson(cfg.urls.batches + '?itemId=' + it.itemId + storeQ());
            if (!batches.length) { toast('warning', 'No sellable batch (expired or within ' + cfg.settings.MinShelfLifeSaleDays + ' days of expiry).'); return; }
            const l = { key: ++seq, item: it, batches, batchId: null, mode: it.conversionQty > 1 && !it.allowLooseSale ? 'P' : (it.conversionQty > 1 ? 'P' : 'U'), qtyIn: 1, disc: 0, rate: 0, unitMrp: batches[0].unitMrp };
            lines.push(l);
            await price(l);
            render(); rxCheck();
            const q = document.querySelector(`[data-key="${l.key}"] [data-f=qty]`); q && (q.focus(), q.select());
            search.value = '';
        }
        async function price(l) {
            const b = l.batchId ? l.batches.find(x => x.batchId === l.batchId) : l.batches[0];
            l.unitMrp = b.unitMrp;
            l.rate = num(await getJson(`${cfg.urls.price}?itemId=${l.item.itemId}&batchId=${b.batchId}&priceType=${priceType()}`)) || b.unitMrp;
        }
        async function refreshPrices() { for (const l of lines) await price(l); render(); }
        const units = l => l.mode === 'P' ? num(l.qtyIn) * l.item.conversionQty : num(l.qtyIn);
        function calc(l) {
            const d = l.item.isDiscountAllowed ? Math.min(100, num(l.disc) + num($('billDisc').value)) : 0;
            l.amount = r2(units(l) * l.rate * (1 - d / 100));
            l.taxable = r2(l.amount * 100 / (100 + l.item.gstPercent));
            l.gst = l.amount - l.taxable; l.mrpAmt = units(l) * l.unitMrp; l.effDisc = d;
        }

        function render() {
            $('emptyLines').classList.toggle('d-none', lines.length > 0);
            $('lines').innerHTML = lines.map((l, i) => {
                calc(l);
                const it = l.item, conv = it.conversionQty;
                const stockUnits = l.batchId ? (l.batches.find(b => b.batchId === l.batchId)?.stock || 0) : l.batches.reduce((s, b) => s + b.stock, 0);
                const short = units(l) > stockUnits;
                return `<tr data-key="${l.key}" class="${short ? 'short' : ''}" title="${short ? 'More than the sellable stock (' + q3(stockUnits) + ')' : ''}">
                    <td class="sn">${i + 1}</td>
                    <td class="it"><div class="it-nm">${it.formShort ? `<span class="ph-form-tag">${esc(it.formShort)}</span>` : ''}${esc(it.itemName)} ${sch(it.scheduleCode)}
                        ${it.isColdChain ? '<i class="bi bi-snow text-info" title="cold chain"></i>' : ''}${it.isHighAlert ? ' <i class="bi bi-exclamation-octagon-fill text-danger" title="high alert"></i>' : ''}${it.isLasa ? ' <i class="bi bi-eye-fill text-warning" title="LASA"></i>' : ''}</div>
                        <div class="it-sub">${esc(it.genericName || '')}${it.rackNo ? ' · rack ' + esc(it.rackNo) : ''} · stock <span class="${short ? 'text-danger fw-bold' : ''}">${q3(stockUnits)}</span></div></td>
                    <td><select class="form-select" data-f="batch" style="min-width:160px"><option value="">Auto (first expiry)</option>
                        ${l.batches.map(b => `<option value="${b.batchId}" ${l.batchId === b.batchId ? 'selected' : ''}>${esc(b.batchNo)} · ${mon(b.expiryDate)} · ₹${money(b.packMrp)} · ${q3(b.stock)}</option>`).join('')}</select></td>
                    <td><div class="qty"><input class="form-control num" data-f="qty" type="number" min="0" step="1" value="${l.qtyIn}">
                        ${conv > 1 ? `<select class="form-select" data-f="mode" ${it.allowLooseSale ? '' : 'disabled'}><option value="P" ${l.mode === 'P' ? 'selected' : ''}>${esc(it.purchaseUom)}</option><option value="U" ${l.mode === 'U' ? 'selected' : ''}>${esc(it.saleUom)}</option></select>`
                                   : `<span class="unit">${esc(it.saleUom)}</span>`}</div>
                        ${conv > 1 ? `<div class="it-sub text-end">${q3(units(l))} ${esc(it.saleUom)}</div>` : ''}</td>
                    <td class="text-end num">${money(l.unitMrp * (l.mode === 'P' ? conv : 1))}</td>
                    <td class="text-end num">${money(l.rate * (l.mode === 'P' ? conv : 1))}${l.rate < l.unitMrp ? '<span class="tag rule" title="price rule">rule</span>' : ''}</td>
                    <td class="text-end"><input class="form-control text-end num ms-auto" data-f="disc" type="number" min="0" max="100" step="0.5" value="${l.disc}" style="width:66px" ${it.isDiscountAllowed ? '' : 'disabled title="No discount on this item"'}></td>
                    <td class="text-end num text-muted">${num(it.gstPercent).toFixed(0)}</td>
                    <td class="text-end num amt" data-c="amt">${money(l.amount)}</td>
                    <td><button type="button" class="del" data-del title="Remove (Ctrl+Del)"><i class="bi bi-x-circle-fill"></i></button></td></tr>`;
            }).join('');
            totals();
        }
        $('lines').addEventListener('input', e => {
            const tr = e.target.closest('tr'); if (!tr) return;
            const l = lines.find(x => x.key == tr.dataset.key), f = e.target.dataset.f;
            if (f === 'qty') l.qtyIn = e.target.value; else if (f === 'disc') l.disc = e.target.value; else return;
            calc(l); tr.querySelector('[data-c=amt]').innerHTML = money(l.amount); totals();
        });
        $('lines').addEventListener('change', async e => {
            const tr = e.target.closest('tr'); if (!tr) return;
            const l = lines.find(x => x.key == tr.dataset.key), f = e.target.dataset.f;
            if (f === 'batch') { l.batchId = e.target.value ? +e.target.value : null; await price(l); }
            if (f === 'mode') { const u = units(l); l.mode = e.target.value; l.qtyIn = l.mode === 'P' ? Math.max(1, Math.round(u / l.item.conversionQty)) : u; }
            if (f === 'qty' || f === 'batch' || f === 'mode' || f === 'disc') render();
        });
        $('lines').addEventListener('click', e => { if (e.target.closest('[data-del]')) { const tr = e.target.closest('tr'); lines = lines.filter(x => x.key != tr.dataset.key); render(); rxCheck(); focusSearch(); } });
        $('lines').addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.dataset.f) { e.preventDefault(); render(); focusSearch(); } });
        $('billDisc').addEventListener('input', () => {
            if (num($('billDisc').value) > cfg.settings.MaxManualDiscountPercent && !cfg.canDiscount) toast('warning', `Above ${cfg.settings.MaxManualDiscountPercent}%: needs a user with the Discount permission.`);
            render();
        });

        // ── totals and payment ───────────────────────────────────────────────────────────────────────
        let net = 0;
        function totals() {
            let mrp = 0, amt = 0, tax = 0, gst = 0;
            lines.forEach(l => { calc(l); mrp += l.mrpAmt; amt += l.amount; tax += l.taxable; gst += l.gst; });
            net = cfg.settings.RoundOffBill ? Math.round(amt) : r2(amt);
            $('tNet').textContent = '₹ ' + money(net); $('tMrp').textContent = money(mrp); $('tDisc').textContent = money(mrp - amt);
            $('tTax').textContent = money(tax); $('tGst').textContent = money(gst); $('tRound').textContent = money(net - amt);
            $('tItems').textContent = `${lines.length} item${lines.length === 1 ? '' : 's'}`; $('tSave').textContent = mrp - net > 0.5 ? `You save ₹${money(mrp - net)}` : '';
            $('fItems').textContent = lines.length; $('fUnits').textContent = q3(lines.reduce((s, l) => s + units(l), 0));
            $('fMrp').textContent = money(mrp); $('fSave').textContent = money(Math.max(0, mrp - net));
            payTotals();
        }
        function renderPays() {
            $('pays').innerHTML = pays.map((p, i) => `<div class="pos-pay ${p.method === 'CASH' ? '' : 'ref'}" data-i="${i}"><span class="m">${esc(p.method === 'CASH' ? 'Cash' : p.method === 'CHEQUE' ? 'Cheque' : p.method)}</span>
                <input class="form-control num" data-p="amount" type="number" min="0" step="0.01" value="${p.amount}" placeholder="${p.method === 'CASH' ? 'Received' : 'Amount'}">
                ${p.method === 'CASH' ? '' : `<input class="form-control" data-p="ref" value="${esc(p.ref || '')}" placeholder="${p.method === 'CARD' ? 'Last 4 / approval' : p.method === 'UPI' ? 'UPI ref' : 'Ref no.'}" maxlength="50">`}
                <button class="x" type="button" data-pdel title="Remove"><i class="bi bi-x-circle-fill"></i></button></div>`).join('');
            document.querySelectorAll('#payBtns [data-m]').forEach(b => b.classList.toggle('on', pays.some(p => p.method === b.dataset.m)));
            payTotals();
        }
        function payTotals() {
            const cash = pays.filter(p => p.method === 'CASH').reduce((s, p) => s + num(p.amount), 0), other = pays.filter(p => p.method !== 'CASH').reduce((s, p) => s + num(p.amount), 0);
            const paid = Math.min(net, cash + other), change = cash > 0 ? Math.max(0, cash + other - net) : 0, due = r2(net - paid);
            $('tPaid').textContent = money(paid); $('tDue').textContent = money(due);
            $('dueLbl').textContent = due > 0 && kind === 'CUSTOMER' && customer?.credit ? 'On credit' : 'Balance';
            $('tDue').className = due > 0 ? 'text-danger' : '';
            $('changeRow').classList.toggle('d-none', change <= 0); $('tChange').textContent = '₹ ' + money(change);
        }
        function addPay(m) {
            let p = pays.find(x => x.method === m);
            if (!p) { const paid = pays.reduce((s, x) => s + num(x.amount), 0); p = { method: m, amount: Math.max(0, r2(net - paid)) || '', ref: '' }; pays.push(p); renderPays(); }
            const box = $('pays').querySelector(`[data-i="${pays.indexOf(p)}"] [data-p=${m === 'CASH' ? 'amount' : 'ref'}]`); box && (box.focus(), box.select && box.select());
        }
        document.querySelectorAll('#payBtns [data-m]').forEach(b => b.addEventListener('click', () => addPay(b.dataset.m)));
        $('pays').addEventListener('input', e => { const g = e.target.closest('[data-i]'); if (!g) return; pays[g.dataset.i][e.target.dataset.p] = e.target.value; payTotals(); });
        $('pays').addEventListener('click', e => { if (e.target.closest('[data-pdel]')) { pays.splice(+e.target.closest('[data-i]').dataset.i, 1); renderPays(); } });
        $('pays').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); save(); } });
        // quick cash: Exact = what is left after card / UPI; a note adds to the cash received
        $('quickCash').addEventListener('click', e => {
            const q = e.target.closest('[data-q]')?.dataset.q; if (!q) return;
            let cash = pays.find(p => p.method === 'CASH');
            if (!cash) { cash = { method: 'CASH', amount: 0, ref: '' }; pays.push(cash); }
            const other = pays.filter(p => p.method !== 'CASH').reduce((s, p) => s + num(p.amount), 0);
            cash.amount = q === 'exact' ? Math.max(0, r2(net - other)) : r2(num(cash.amount) + num(q));
            renderPays();
        });

        // ── save / hold / recall ─────────────────────────────────────────────────────────────────────
        function request() {
            const w = id => $(id) ? $(id).value.trim() || null : null;
            return {
                StoreId: storeSel && storeSel.value ? +storeSel.value : null, HoldId: holdId, CustomerKind: kind, PatientId: kind === 'PATIENT' ? patient?.id : null, CustomerId: kind === 'CUSTOMER' ? customer?.id : null,
                CustomerName: kind === 'WALKIN' ? w('wName') : null, Mobile: kind === 'WALKIN' ? w('wMobile') : null, Address: kind === 'WALKIN' ? w('wAddress') : null,
                DoctorId: doctorId, DoctorName: w('docName'), DoctorRegNo: w('docReg'), RxNo: w('rxNo'), RxDate: w('rxDate'), BillDiscPercent: num($('billDisc').value),
                Lines: lines.map(l => ({ ItemId: l.item.itemId, BatchId: l.batchId, Qty: units(l), DiscPercent: num(l.disc) })),
                Payments: pays.filter(p => num(p.amount) > 0).map(p => ({ Method: p.method, Amount: num(p.amount), Ref: p.ref || null }))
            };
        }
        let busy = false;
        async function save() {
            if (busy || !$('btnSave') || $('btnSave').disabled) return;
            if (!lines.length) { toast('info', 'Add an item first.'); focusSearch(); return; }
            if (kind !== 'WALKIN' && !(kind === 'PATIENT' ? patient : customer)) { toast('info', kind === 'PATIENT' ? 'Pick the patient.' : 'Pick the credit customer.'); return; }
            if (!pays.length && net > 0 && !(kind === 'CUSTOMER' && customer?.credit)) { addPay('CASH'); return; }
            busy = true; $('btnSave').disabled = true;
            const res = await postJson(cfg.urls.save, request());
            busy = false; $('btnSave').disabled = false;
            if (!res.success) { Swal.fire({ icon: 'error', title: 'Not saved', text: res.error || 'Please check the bill.' }); return; }
            const fmt = $('printFmt').value;
            if (fmt) window.open(`${cfg.urls.print}?id=${res.saleId}&format=${fmt}`, '_blank', 'width=900,height=900');
            showLast(res, fmt);
            Swal.fire({ icon: 'success', title: `Bill ${res.saleNo}`, html: `Net ₹${money(res.netAmount)}${res.change > 0 ? `<div class="fs-4 fw-bold text-success mt-2">Return change ₹${money(res.change)}</div>` : ''}${res.balanceDue > 0 ? `<div class="text-danger mt-1">On credit ₹${money(res.balanceDue)}</div>` : ''}`,
                confirmButtonText: 'New bill', showDenyButton: true, denyButtonText: 'Open bill' })
                .then(r => { if (r.isDenied) location.href = `${cfg.urls.bill}?id=${res.saleId}`; });
            reset();
        }
        function showLast(res, fmt) {
            const box = $('lastBill'); if (!box) return;
            box.innerHTML = `<i class="bi bi-clock-history me-1"></i>Last bill <b>${esc(res.saleNo)}</b> · ₹${money(res.netAmount)}${res.change > 0 ? ` · change ₹${money(res.change)}` : ''}
                <span class="float-end"><a href="${cfg.urls.print}?id=${res.saleId}&format=${encodeURIComponent(fmt || '80MM')}" target="_blank"><i class="bi bi-printer me-1"></i>Reprint</a>
                · <a href="${cfg.urls.bill}?id=${res.saleId}">Open</a></span>`;
            box.classList.remove('d-none');
        }
        function setMode() {
            const m = $('billMode'); if (!m) return;
            m.className = 'pos-pill ' + (holdId ? 'held' : 'mode');
            m.innerHTML = holdId ? '<i class="bi bi-pause-circle"></i>Recalled held bill' : '<i class="bi bi-plus-circle"></i>New bill';
        }
        async function hold() {
            if (!lines.length) { toast('info', 'Nothing to hold.'); return; }
            const r = await Swal.fire({ title: 'Hold this bill', input: 'text', inputLabel: 'Label (customer / token)', inputValue: $('wName')?.value || patient?.name || customer?.name || '', showCancelButton: true });
            if (!r.isConfirmed) return;
            const body = request(); body.HoldLabel = r.value || null;
            const res = await postJson(cfg.urls.hold, body);
            if (!res.success) { Swal.fire({ icon: 'error', title: 'Not held', text: res.error }); return; }
            toast('success', 'Bill held.'); reset(); heldCount();
        }
        async function heldCount() { const h = await getJson(cfg.urls.held); $('heldCount') && ($('heldCount').textContent = h.length || ''); return h; }
        async function showHeld() {
            const h = await heldCount();
            $('heldRows').innerHTML = h.length ? h.map(x => `<tr><td>${new Date(x.saleDate).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</td><td>${esc(x.holdLabel || x.customerName || '—')}</td>
                <td class="text-end">${x.lines}</td><td class="text-end">${money(x.netAmount)}</td><td class="small">${esc(x.createdByName || '')}</td>
                <td class="text-end"><button class="btn btn-sm btn-primary" data-recall="${x.saleId}">Recall</button> <button class="btn btn-sm btn-outline-danger" data-discard="${x.saleId}"><i class="bi bi-trash"></i></button></td></tr>`).join('')
                : '<tr><td colspan="6" class="text-center text-muted py-4">No held bills.</td></tr>';
            bootstrap.Modal.getOrCreateInstance($('heldModal')).show();
        }
        $('heldRows').addEventListener('click', async e => {
            const rc = e.target.closest('[data-recall]'), dc = e.target.closest('[data-discard]');
            if (rc) { bootstrap.Modal.getInstance($('heldModal')).hide(); await recall(+rc.dataset.recall); }
            if (dc && (await Swal.fire({ title: 'Discard this held bill?', icon: 'warning', showCancelButton: true })).isConfirmed) {
                const fd = new FormData(); fd.append('id', dc.dataset.discard); fd.append('__RequestVerificationToken', token());
                await fetch(cfg.urls.discard, { method: 'POST', body: fd }); showHeld();
            }
        });
        async function recall(id) {
            if (lines.length && !(await Swal.fire({ title: 'Replace the current bill?', icon: 'question', showCancelButton: true })).isConfirmed) return;
            const d = await getJson(cfg.urls.recall + '?id=' + id);
            if (!d || !d.bill) { toast('error', 'Held bill not found.'); return; }
            reset(); holdId = id;
            const b = d.bill;
            kind = b.customerKind; document.querySelector(`input[name=ck][value=${kind}]`).checked = true;
            if (kind === 'PATIENT') patient = { id: b.patientId, uhid: b.patientCode, name: b.customerName, mobile: b.mobile };
            if (kind === 'CUSTOMER') { const c = await getJson(cfg.urls.customers + '?q=' + encodeURIComponent(b.mobile || b.customerName)); customer = c.find(x => x.id === b.customerId) || null; }
            renderCustomer();
            if (kind === 'WALKIN') { $('wName').value = b.customerName || ''; $('wMobile').value = b.mobile || ''; $('wAddress').value = b.address || ''; }
            $('docName').value = b.doctorName || ''; $('docReg').value = b.doctorRegNo || ''; $('rxNo').value = b.rxNo || ''; doctorId = b.doctorId; $('billDisc').value = b.billDiscPercent || 0;
            const qty = {};
            b.lines.forEach(l => qty[l.itemId] = (qty[l.itemId] || 0) + l.qty);
            for (const [itemId, q] of Object.entries(qty)) {
                const it = d.items.find(x => x.itemId == itemId); if (!it) continue;
                const batches = await getJson(cfg.urls.batches + '?itemId=' + itemId + storeQ());
                if (!batches.length) { toast('warning', it.itemName + ': no sellable stock now.'); continue; }
                const l = { key: ++seq, item: it, batches, batchId: null, mode: 'U', qtyIn: q, disc: b.lines.find(x => x.itemId == itemId).discPercent - (b.billDiscPercent || 0), rate: 0 };
                if (it.conversionQty > 1 && q % it.conversionQty === 0) { l.mode = 'P'; l.qtyIn = q / it.conversionQty; }
                l.disc = Math.max(0, l.disc); await price(l); lines.push(l);
            }
            render(); rxCheck(); setMode(); toast('success', 'Held bill recalled.'); focusSearch();
        }
        function reset() {
            lines = []; pays = []; patient = null; customer = null; doctorId = null; holdId = null;
            ['docName', 'docReg', 'rxNo', 'rxDate'].forEach(id => $(id).value = ''); $('billDisc').value = 0;
            renderCustomer(); render(); renderPays(); setMode(); focusSearch();
        }
        $('btnSave') && $('btnSave').addEventListener('click', save);
        $('btnHold') && $('btnHold').addEventListener('click', hold);
        $('btnHeld') && $('btnHeld').addEventListener('click', showHeld);
        $('btnClear').addEventListener('click', async () => { if (!lines.length || (await Swal.fire({ title: 'Clear this bill?', icon: 'warning', showCancelButton: true })).isConfirmed) reset(); });
        let lastEsc = 0;
        document.addEventListener('keydown', e => {
            const k = e.key;
            if (k === 'F2') { e.preventDefault(); focusSearch(); }
            else if (k === 'F4') { e.preventDefault(); (kind === 'WALKIN' ? $('wName') : $('custSearch') || $('custChange'))?.focus(); }
            else if (k === 'F6') { e.preventDefault(); addPay(pays[0]?.method || 'CASH'); }
            else if (k === 'F7') { e.preventDefault(); $('btnHeld') && showHeld(); }
            else if (k === 'F8') { e.preventDefault(); $('btnHold') && hold(); }
            else if (k === 'F10') { e.preventDefault(); save(); }
            else if (k === 'Delete' && e.ctrlKey) {
                const tr = document.activeElement?.closest('#lines tr'); if (!tr) return;
                e.preventDefault(); lines = lines.filter(x => x.key != tr.dataset.key); render(); rxCheck(); focusSearch();
            }
            else if (k === 'Escape' && !document.querySelector('.modal.show, .swal2-container')) { if (Date.now() - lastEsc < 600 && lines.length) $('btnClear').click(); lastEsc = Date.now(); }
        });

        $('btnFull')?.addEventListener('click', () => document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.().catch(() => {}));
        const tick = () => { const c = $('posClock'); if (c) c.textContent = new Date().toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true }); };
        tick(); setInterval(tick, 30000);

        renderCustomer(); render(); renderPays(); setMode(); heldCount();
        if (cfg.recall) recall(cfg.recall); else setTimeout(focusSearch, 100);
    };
})();
