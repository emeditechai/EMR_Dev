/* Quality & Compliance > Stock Management > Pending Consumption (SQLScripts/2498-2500). window.QcStockPending = { perms } */
(function () {
    'use strict';
    const P = (window.QcStockPending || {}).perms || {};
    const esc = QC.esc, qty = QC.qty;
    let rows = [];
    const sel = () => [...document.querySelectorAll('#pRows .p-sel:checked')].map(x => +x.value);

    async function load() {
        const st = document.getElementById('pStatus').value, pending = st === 'PENDING';
        document.getElementById('pRetry').classList.toggle('d-none', !(pending && P.RETRY));
        document.getElementById('pSkip').classList.toggle('d-none', !(pending && P.SKIP));
        const tb = document.getElementById('pRows');
        tb.innerHTML = '<tr><td colspan="9" class="text-center text-muted py-4">Loading...</td></tr>';
        const r = await QC.get('/QcPendingConsumption/List', { status: st, from: document.getElementById('pFrom').value, to: document.getElementById('pTo').value });
        if (!r.success) { tb.innerHTML = `<tr><td colspan="9" class="text-danger text-center py-4">${esc(r.message)}</td></tr>`; return; }
        rows = r.data || [];
        document.getElementById('pAll').checked = false;
        tb.innerHTML = rows.length ? rows.map(x => `<tr class="${pending && +x.AvailableNow >= +x.Qty ? 'table-success' : ''}">
            <td class="ps-3">${pending ? `<input type="checkbox" class="form-check-input p-sel" value="${x.LineId}" aria-label="Select" />` : ''}</td>
            <td class="small">${QC.dateTime(x.ConsumedOn)}${x.RunNo > 1 ? `<div class="text-muted">run ${x.RunNo}</div>` : ''}</td>
            <td class="small font-monospace">${esc(x.BillNo || '')}</td><td class="small">${esc(x.TestName || '')}</td>
            <td class="small"><div class="fw-semibold">${esc(x.ItemName)}</div><div class="text-muted">${esc(x.ItemCode)}</div></td>
            <td class="qs-num">${qty(x.Qty)} <span class="small text-muted">${esc(x.ConsumptionUnit)}</span></td>
            <td class="small">${esc(x.StoreName || '—')}</td>
            <td class="qs-num ${+x.AvailableNow >= +x.Qty ? 'text-success fw-semibold' : 'text-danger'}">${qty(x.AvailableNow)}</td>
            <td class="small text-muted">${esc(x.StockNote || '')}</td></tr>`).join('')
            : `<tr><td colspan="9" class="text-center text-muted py-4">${pending ? 'Nothing pending - every test run has been taken out of stock.' : 'Nothing here.'}</td></tr>`;
    }

    document.getElementById('pAll').addEventListener('change', function () { document.querySelectorAll('#pRows .p-sel').forEach(x => x.checked = this.checked); });
    document.getElementById('pRetry').addEventListener('click', async () => {
        const ids = sel(); if (!ids.length) return QC.fail('Select the lines to take out of stock.');
        const r = await QC.post('/QcPendingConsumption/Retry', { lineIds: ids });
        if (!r.success) return QC.fail(r.message);
        QC.ok(`${r.data.Posted || 0} taken out of stock${r.data.StillPending ? ', ' + r.data.StillPending + ' still short' : ''}`); load();
    });
    document.getElementById('pSkip').addEventListener('click', async () => {
        const ids = sel(); if (!ids.length) return QC.fail('Select the lines to skip.');
        const q = await Swal.fire({ title: `Skip ${ids.length} line(s)?`, text: 'They will not be taken out of stock (e.g. the reagent was already written off).', input: 'textarea',
            inputPlaceholder: 'Reason', showCancelButton: true, confirmButtonText: 'Skip', confirmButtonColor: '#dc3545', inputValidator: v => !String(v || '').trim() ? 'Please give a reason.' : undefined });
        if (!q.isConfirmed) return;
        const r = await QC.post('/QcPendingConsumption/Skip', { lineIds: ids, reason: q.value });
        if (!r.success) return QC.fail(r.message);
        QC.ok('Skipped'); load();
    });
    document.getElementById('pGo').addEventListener('click', load);
    document.getElementById('pStatus').addEventListener('change', load);
    load();
})();
