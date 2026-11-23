/* Quality & Compliance > Stock Management > Stock Enquiry (SQLScripts/2498-2500). window.QcStockEnq = { perms, lookups, filter } */
(function () {
    'use strict';
    const C = window.QcStockEnq || {}, P = C.perms || {}, L = C.lookups || {};
    const esc = QC.esc, qty = QC.qty;
    const mine = (L.stores || []).filter(s => s.IsMine);
    document.getElementById('eStore').innerHTML = QC.options(mine.map(s => ({ Id: s.StoreId, Name: s.StoreName + (s.StoreType === 'Bench' ? ' (bench)' : '') })), '', 'All stores of this branch');
    document.getElementById('eCategory').innerHTML = QC.options(L.categories || [], '', 'All categories');
    if (C.filter) document.getElementById('eFilter').value = C.filter;
    if (['NEAR', 'EXPIRED', 'QUARANTINE', 'OPENED'].includes(C.filter)) document.getElementById('eViewLot').checked = true;
    const view = () => document.querySelector('input[name=eView]:checked').value;
    const lotBadge = s => `<span class="qs-badge qs-st-${esc(s)}">${esc({ QUARANTINE: 'Quarantine', ACCEPTED: 'Accepted', REJECTED: 'Rejected', BLOCKED: 'Blocked' }[s] || s)}</span>`;
    let rows = [];

    async function load() {
        const v = view(), head = document.getElementById('eHead'), tb = document.getElementById('eRows'), foot = document.getElementById('eFoot');
        head.innerHTML = v === 'ITEM'
            ? '<th class="ps-3">Item</th><th>Category</th><th class="text-end">Stock</th><th class="text-end">Packs</th><th class="text-end">Usable</th><th class="text-end">Held / expired</th><th>Nearest expiry</th><th class="text-end">Value</th><th class="text-end">Reorder</th><th></th>'
            : '<th class="ps-3">Item</th><th>Store</th><th>Lot</th><th>Expiry</th><th>Status</th><th class="text-end">Qty</th><th>Opened</th><th class="text-end">Value</th><th></th>';
        tb.innerHTML = '<tr><td colspan="10" class="text-center text-muted py-4">Loading...</td></tr>'; foot.innerHTML = '';
        const r = await QC.get('/QcStockEnquiry/List', { view: v, storeId: document.getElementById('eStore').value, filter: document.getElementById('eFilter').value,
            categoryId: document.getElementById('eCategory').value, search: document.getElementById('eSearch').value });
        if (!r.success) { tb.innerHTML = `<tr><td colspan="10" class="text-danger text-center py-4">${esc(r.message)}</td></tr>`; return; }
        rows = r.data || [];
        if (!rows.length) { tb.innerHTML = '<tr><td colspan="10" class="text-center text-muted py-4">Nothing to show for these filters.</td></tr>'; return; }
        let total = 0;
        if (v === 'ITEM') {
            tb.innerHTML = rows.map(x => { total += +x.Value || 0; return `<tr class="${x.IsLow ? 'qs-rowwarn' : ''}">
                <td class="ps-3"><div class="fw-semibold">${esc(x.ItemName)}</div><div class="small text-muted">${esc(x.ItemCode)} · ${x.Lots || 0} lot(s) in ${x.Stores || 0} store(s)</div></td>
                <td class="small">${esc(x.CategoryName)}</td>
                <td class="qs-num">${qty(x.Qty)} <span class="small text-muted">${esc(x.ConsumptionUnit)}</span></td>
                <td class="qs-num">${qty(x.Packs)} <span class="small text-muted">${esc(x.PurchaseUnit)}</span></td>
                <td class="qs-num">${qty(x.UsableQty)}</td>
                <td class="qs-num small">${+x.HeldQty ? '<span class="text-warning">' + qty(x.HeldQty) + ' held</span>' : ''}${+x.ExpiredQty ? '<div class="text-danger">' + qty(x.ExpiredQty) + ' expired</div>' : ''}</td>
                <td class="small">${QC.date(x.NearestExpiry)}</td>
                <td class="qs-num">${QC.num(x.Value)}</td>
                <td class="qs-num small">${x.ReorderLevel != null ? qty(x.ReorderLevel) + (x.IsLow ? ' <span class="badge bg-warning text-dark">low</span>' : '') : '—'}</td>
                <td class="text-end pe-3"><button class="btn btn-sm btn-outline-primary act-led" data-item="${x.ItemId}" title="Movements"><i class="bi bi-journal-text"></i></button></td></tr>`; }).join('');
        } else {
            const today = new Date().toISOString().slice(0, 10);
            tb.innerHTML = rows.map(x => { total += +x.Value || 0; const useBy = x.OpenUseBy ? String(x.OpenUseBy).slice(0, 10) : null; return `<tr class="${x.ExpiryState === 'EXPIRED' ? 'table-danger' : x.ExpiryState === 'NEAR' ? 'qs-rowwarn' : ''}">
                <td class="ps-3"><div class="fw-semibold">${esc(x.ItemName)}</div><div class="small text-muted">${esc(x.ItemCode)}${x.StorageTemp ? ' · ' + esc(x.StorageTemp) : ''}</div></td>
                <td class="small">${esc(x.StoreName)}</td>
                <td class="small font-monospace">${esc(x.LotNo === 'NA' ? '—' : x.LotNo)}</td>
                <td class="small">${QC.date(x.ExpiryDate)}${x.DaysToExpiry != null ? `<div class="text-muted">${x.DaysToExpiry < 0 ? 'expired' : x.DaysToExpiry + ' days'}</div>` : ''}</td>
                <td>${lotBadge(x.LotStatus)}</td>
                <td class="qs-num">${qty(x.Qty)} <span class="small text-muted">${esc(x.ConsumptionUnit)}</span><div class="small text-muted">${qty(x.Packs)} ${esc(x.PurchaseUnit)}</div></td>
                <td class="small">${x.OpenedOn ? QC.date(x.OpenedOn) + (useBy ? `<div class="${useBy < today ? 'text-danger fw-semibold' : 'text-muted'}">use by ${QC.date(useBy)}</div>` : '') : '—'}</td>
                <td class="qs-num">${QC.num(x.Value)}</td>
                <td class="text-end pe-3 text-nowrap">${P.OPEN_VIAL && x.Qty > 0 ? `<button class="btn btn-sm btn-outline-secondary act-open" data-store="${x.StoreId}" data-lot="${x.LotId}" data-opened="${x.OpenedOn ? 1 : 0}" title="${x.OpenedOn ? 'Clear opened date' : 'Mark opened'}"><i class="bi ${x.OpenedOn ? 'bi-eraser' : 'bi-unlock'}"></i></button>` : ''}
                    <button class="btn btn-sm btn-outline-primary act-led" data-item="${x.ItemId}" data-lot="${x.LotId}" data-store="${x.StoreId}" title="Movements"><i class="bi bi-journal-text"></i></button></td></tr>`; }).join('');
        }
        foot.innerHTML = `<tr class="fw-bold"><td class="ps-3" colspan="${v === 'ITEM' ? 7 : 7}">${rows.length} row(s)</td><td class="qs-num">₹${QC.num(total)}</td><td colspan="2"></td></tr>`;
    }

    const led = new bootstrap.Modal(document.getElementById('ledModal'));
    let ledArgs = null;
    async function loadLedger() {
        const r = await QC.get('/QcStockEnquiry/Ledger', Object.assign({}, ledArgs, { from: document.getElementById('ledFrom').value, to: document.getElementById('ledTo').value }));
        const tb = document.getElementById('ledRows');
        if (!r.success) { tb.innerHTML = `<tr><td colspan="10" class="text-danger">${esc(r.message)}</td></tr>`; return; }
        const h = (r.data[0] || [])[0] || {}, list = r.data[1] || [];
        document.getElementById('ledTitle').textContent = `Movements - ${h.ItemName || ''} (${h.ConsumptionUnit || ''})`;
        tb.innerHTML = `<tr class="table-light"><td colspan="7">Opening balance</td><td class="qs-num fw-semibold">${qty(h.OpeningQty)}</td><td colspan="2"></td></tr>` +
            (list.map(m => `<tr><td>${QC.dateTime(m.TxnOn)}</td><td>${esc(m.MoveName)}${m.TestName ? '<div class="text-muted">' + esc(m.TestName) + '</div>' : ''}</td><td class="font-monospace">${esc(m.DocNo || '')}</td>
                <td>${esc(m.StoreName)}</td><td>${esc(m.LotNo === 'NA' ? '—' : m.LotNo)}</td><td class="qs-num text-success">${+m.QtyIn ? qty(m.QtyIn) : ''}</td><td class="qs-num text-danger">${+m.QtyOut ? qty(m.QtyOut) : ''}</td>
                <td class="qs-num fw-semibold">${qty(m.RunningQty)}</td><td class="qs-num">${QC.num(m.UnitCost, 4)}</td><td>${esc(m.UserName || '')}</td></tr>`).join('') || '<tr><td colspan="10" class="text-muted text-center">No movements in this period.</td></tr>');
    }
    document.getElementById('ledGo').addEventListener('click', loadLedger);

    document.getElementById('eRows').addEventListener('click', async e => {
        const l = e.target.closest('.act-led'), o = e.target.closest('.act-open');
        if (l) {
            ledArgs = { itemId: +l.dataset.item, lotId: l.dataset.lot || '', storeId: l.dataset.store || document.getElementById('eStore').value };
            const d = new Date(); document.getElementById('ledTo').value = d.toISOString().slice(0, 10); d.setMonth(d.getMonth() - 3); document.getElementById('ledFrom').value = d.toISOString().slice(0, 10);
            document.getElementById('ledRows').innerHTML = '<tr><td colspan="10" class="text-muted">Loading...</td></tr>';
            led.show(); loadLedger();
        }
        if (o) {
            if (o.dataset.opened === '1') {
                if (!(await QC.confirm('Clear the opened date?', 'Use this when the date was set by mistake.', 'Clear'))) return;
                const r = await QC.post('/QcStockEnquiry/MarkOpened', { storeId: +o.dataset.store, lotId: +o.dataset.lot, clear: true });
                if (!r.success) return QC.fail(r.message); return load();
            }
            const q = await Swal.fire({ title: 'Mark lot opened', text: 'The date the first container of this lot was opened in this store (starts the open-vial stability).', input: 'date',
                inputValue: new Date().toISOString().slice(0, 10), showCancelButton: true, confirmButtonText: 'Save' });
            if (!q.isConfirmed) return;
            const r = await QC.post('/QcStockEnquiry/MarkOpened', { storeId: +o.dataset.store, lotId: +o.dataset.lot, openedOn: q.value || null });
            if (!r.success) return QC.fail(r.message);
            QC.ok('Marked opened'); load();
        }
    });
    document.querySelectorAll('input[name=eView]').forEach(x => x.addEventListener('change', load));
    ['eStore', 'eFilter', 'eCategory'].forEach(id => document.getElementById(id).addEventListener('change', load));
    document.getElementById('eGo').addEventListener('click', load);
    document.getElementById('eSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    load();
})();
