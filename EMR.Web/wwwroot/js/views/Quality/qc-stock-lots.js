/* Quality & Compliance > Stock Management > Lot Acceptance (SQLScripts/2498-2500). window.QcStockLots = { perms } */
(function () {
    'use strict';
    const P = (window.QcStockLots || {}).perms || {};
    const esc = QC.esc, qty = QC.qty;
    let status = 'QUARANTINE', rows = [];
    const badge = s => `<span class="qs-badge qs-st-${esc(s)}">${esc({ QUARANTINE: 'Quarantine', ACCEPTED: 'Accepted', REJECTED: 'Rejected', BLOCKED: 'Blocked' }[s] || s)}</span>`;

    async function load() {
        const tb = document.getElementById('lRows');
        tb.innerHTML = '<tr><td colspan="9" class="text-center text-muted py-4">Loading...</td></tr>';
        const r = await QC.get('/QcLotAcceptance/List', { status, search: document.getElementById('lSearch').value });
        if (!r.success) { tb.innerHTML = `<tr><td colspan="9" class="text-danger text-center py-4">${esc(r.message)}</td></tr>`; return; }
        rows = r.data || [];
        tb.innerHTML = rows.length ? rows.map(x => {
            const b = [];
            if (x.Status === 'QUARANTINE' && P.ACCEPT) b.push(`<button class="btn btn-sm btn-success act" data-a="Accept" data-id="${x.LotId}"><i class="bi bi-check2"></i> Accept</button>`);
            if (['QUARANTINE', 'BLOCKED'].includes(x.Status) && P.REJECT) b.push(`<button class="btn btn-sm btn-outline-danger act" data-a="Reject" data-id="${x.LotId}">Reject</button>`);
            if (x.Status === 'ACCEPTED' && P.BLOCK) b.push(`<button class="btn btn-sm btn-outline-warning act" data-a="Block" data-id="${x.LotId}">Block</button>`);
            if (x.Status === 'BLOCKED' && P.BLOCK) b.push(`<button class="btn btn-sm btn-outline-success act" data-a="Unblock" data-id="${x.LotId}">Unblock</button>`);
            return `<tr>
                <td class="ps-3"><div class="fw-semibold">${esc(x.ItemName)}</div><div class="small text-muted">${esc(x.ItemCode)} · ${esc(x.CategoryName)}${x.Manufacturer ? ' · ' + esc(x.Manufacturer) : ''}</div></td>
                <td class="font-monospace">${esc(x.LotNo)}</td>
                <td class="small">${QC.date(x.ExpiryDate)}${x.DaysToExpiry != null ? `<div class="${x.DaysToExpiry < 0 ? 'text-danger' : 'text-muted'}">${x.DaysToExpiry < 0 ? 'expired' : x.DaysToExpiry + ' days'}</div>` : ''}</td>
                <td class="small">${esc(x.SupplierName || '—')}<div class="text-muted">${esc(x.FirstDocNo || '')} · ${QC.date(x.CreatedOn)}</div></td>
                <td class="qs-num">${qty(x.BranchQty)} <span class="small text-muted">${esc(x.ConsumptionUnit)}</span>${+x.TotalQty !== +x.BranchQty ? `<div class="small text-muted">${qty(x.TotalQty)} in all branches</div>` : ''}</td>
                <td class="small font-monospace">${esc(x.PreviousLotNo || '—')}</td>
                <td>${badge(x.Status)}</td>
                <td class="small" style="max-width:320px">${x.DecisionNote ? esc(x.DecisionNote) + `<div class="text-muted">${esc(x.DecisionByName || '')}</div>` : '—'}</td>
                <td class="text-end pe-3 text-nowrap">${b.join(' ')}</td></tr>`;
        }).join('') : '<tr><td colspan="9" class="text-center text-muted py-4">No lots here.</td></tr>';
    }

    document.getElementById('lRows').addEventListener('click', async e => {
        const b = e.target.closest('.act'); if (!b) return;
        const x = rows.find(r => r.LotId === +b.dataset.id), a = b.dataset.a;
        const title = { Accept: 'Accept lot ' + x.LotNo, Reject: 'Reject lot ' + x.LotNo, Block: 'Block lot ' + x.LotNo, Unblock: 'Unblock lot ' + x.LotNo }[a];
        const ph = { Accept: `Lot-to-lot verification result, e.g. "5 patient samples and 2 QC levels run on ${x.LotNo} vs ${x.PreviousLotNo || 'previous lot'}: all within 5%"`,
                     Reject: 'Why the lot is rejected (it can then be returned to the supplier or written off)', Block: 'Why the lot is put on hold (recall, temperature excursion, QC failure...)',
                     Unblock: 'Why the lot can be used again' }[a];
        const q = await Swal.fire({ title, input: 'textarea', inputPlaceholder: ph, showCancelButton: true, confirmButtonText: a,
            confirmButtonColor: a === 'Accept' || a === 'Unblock' ? '#198754' : '#dc3545', inputValidator: v => !String(v || '').trim() ? 'This note is required.' : undefined });
        if (!q.isConfirmed) return;
        const r = await QC.post('/QcLotAcceptance/' + a, { lotId: x.LotId, note: q.value });
        if (!r.success) return QC.fail(r.message);
        QC.ok('Lot ' + x.LotNo + ' ' + (r.data.Status || '').toLowerCase()); load();
    });
    document.getElementById('lTabs').addEventListener('click', e => {
        const a = e.target.closest('[data-st]'); if (!a) return; e.preventDefault();
        document.querySelectorAll('#lTabs .nav-link').forEach(x => x.classList.toggle('active', x === a)); status = a.dataset.st; load();
    });
    document.getElementById('lGo').addEventListener('click', load);
    document.getElementById('lSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    load();
})();
