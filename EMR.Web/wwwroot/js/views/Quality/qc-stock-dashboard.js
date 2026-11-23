/* Quality & Compliance > Stock Management > Stock Dashboard (SQLScripts/2498-2500). window.QcStockDash = { perms, me } */
(function () {
    'use strict';
    const C = window.QcStockDash || {}, P = C.perms || {};
    const esc = QC.esc, qty = QC.qty, money = QC.money;
    let settings = null;
    if (P.SETTINGS) document.getElementById('btnSettings').classList.remove('d-none');
    if (P.POST_ACCOUNTS) document.getElementById('btnPostCons').classList.remove('d-none');

    function tile(cls, n, label, href, sub) {
        return `<div class="col-6 col-md-4 col-xl-2"><div class="card qs-tile ${cls}"><div class="card-body py-2">${href ? `<a href="${href}">` : ''}
            <div class="n">${n}</div><div class="l">${label}</div>${sub ? `<div class="small text-muted">${sub}</div>` : ''}${href ? '</a>' : ''}</div></div></div>`;
    }

    async function load() {
        const r = await QC.get('/QcStockDashboard/Data');
        if (!r.success) { document.getElementById('dbTiles').innerHTML = `<div class="col-12 text-danger">${esc(r.message)}</div>`; return; }
        const s = r.data || [], k = (s[0] || [])[0] || {};
        settings = (s[5] || [])[0] || null;
        document.getElementById('dbTiles').innerHTML =
            tile('info', money(k.StockValue), 'Stock value', '/QcStockEnquiry/Index', `${k.ItemsInStock || 0} items in stock`) +
            tile(k.BelowReorder ? 'warn' : 'ok', k.BelowReorder || 0, 'Below reorder level', '/QcStockEnquiry/Index?filter=LOW') +
            tile(k.NearExpiryLots ? 'warn' : 'ok', k.NearExpiryLots || 0, `Lots expiring in ${settings ? settings.NearExpiryDays : 60} days`, '/QcStockEnquiry/Index?filter=NEAR', money(k.NearExpiryValue)) +
            tile(k.ExpiredLots ? 'bad' : 'ok', k.ExpiredLots || 0, 'Expired lots in stock', '/QcStockEnquiry/Index?filter=EXPIRED', money(k.ExpiredValue)) +
            tile(k.QuarantineLots ? 'warn' : 'ok', k.QuarantineLots || 0, 'Lots in quarantine', '/QcLotAcceptance/Index') +
            tile(k.PendingConsumption ? 'bad' : 'ok', k.PendingConsumption || 0, 'Test consumption short of stock', '/QcPendingConsumption/Index') +
            tile('info', money(k.Consumption30), 'Used by tests, 30 days', '/QcStockReports/Index?report=CONSUMPTION') +
            tile('info', money(k.PurchaseThisMonth), 'Purchases this month', '/QcStockReports/Index?report=PURCHASE') +
            tile(k.OpenedPastStability ? 'bad' : 'ok', k.OpenedPastStability || 0, 'Opened lots past stability', '/QcStockEnquiry/Index?filter=OPENED');
        const task = (n, label, href) => n ? `<div class="col-md-4 col-xl-2"><a class="btn btn-light border w-100 text-start" href="${href}"><span class="badge bg-primary me-2">${n}</span>${label}</a></div>` : '';
        document.getElementById('dbTasks').innerHTML =
            task(k.PoToApprove, 'POs to approve', '/QcPurchaseOrders/Index') + task(k.PoOpen, 'POs to receive', '/QcGoodsReceipts/Index') +
            task(k.AdjToApprove, 'Adjustments / counts to approve', '/QcStockAdjustments/Index') + task(k.IndentsToIssue, 'Indents to issue', '/QcIndents/Index') +
            task(k.IssuesToReceive, 'Transfers to receive', '/QcStockIssues/Index') + task(k.Drafts, 'Drafts', '/QcGoodsReceipts/Index');
        const st = document.getElementById('dbStart');
        if (k.StoresNotStarted) { st.innerHTML = `<i class="bi bi-info-circle me-1"></i>${k.StoresNotStarted} store(s) of this branch have no stock yet. Stock tracking of a store starts with its <a href="/QcOpeningStock/Index">opening stock</a> or first <a href="/QcGoodsReceipts/Index">goods receipt</a>; until then test consumption is not taken from it.`; st.classList.remove('d-none'); }
        else st.classList.add('d-none');

        const ex = s[1] || [];
        document.getElementById('dbExpiry').innerHTML = ex.length ? ex.map(x => `<tr class="${x.DaysToExpiry < 0 ? 'table-danger' : ''}"><td class="small">${esc(x.ItemName)}</td><td class="small">${esc(x.LotNo)}</td><td class="small">${esc(x.StoreName)}</td>
            <td class="small">${QC.date(x.ExpiryDate)}<div class="text-muted">${x.DaysToExpiry < 0 ? 'expired' : x.DaysToExpiry + ' days'}</div></td><td class="qs-num small">${qty(x.Qty)} ${esc(x.ConsumptionUnit)}</td><td class="qs-num small">${QC.num(x.Value)}</td></tr>`).join('')
            : '<tr><td colspan="6" class="text-muted small text-center py-3">Nothing expiring soon.</td></tr>';
        const ro = s[2] || [];
        document.getElementById('dbReorder').innerHTML = ro.length ? ro.map(x => `<tr><td class="small">${esc(x.ItemName)}</td><td class="qs-num small">${qty(x.StockPacks)} ${esc(x.PurchaseUnit)}</td><td class="qs-num small">${qty(x.ReorderLevel)}</td></tr>`).join('')
            : '<tr><td colspan="3" class="text-muted small text-center py-3">Nothing below reorder level.</td></tr>';

        const days = s[3] || [], byDay = {};
        days.forEach(d => byDay[String(d.Day).slice(0, 10)] = d);
        const list = [];
        for (let i = 29; i >= 0; i--) { const d = new Date(); d.setDate(d.getDate() - i); const key = d.toISOString().slice(0, 10); list.push({ key, t: +(byDay[key]?.Tests || 0), q: +(byDay[key]?.QcUse || 0) }); }
        const max = Math.max(1, ...list.map(x => x.t + x.q));
        document.getElementById('dbBars').innerHTML = list.map(x => `<div class="b" style="height:${(x.t + x.q) / max * 100}%" title="${x.key}: tests ₹${QC.num(x.t)}, QC use ₹${QC.num(x.q)}"><div class="q" style="height:${x.t + x.q ? x.q / (x.t + x.q) * 100 : 0}%"></div></div>`).join('');
        document.getElementById('dbBarsAxis').innerHTML = `<span>${QC.date(list[0].key)}</span><span>max ₹${QC.num(max, 0)} a day</span><span>${QC.date(list[29].key)}</span>`;

        const stores = s[4] || [];
        document.getElementById('dbStores').innerHTML = stores.map(x => `<tr><td class="small">${esc(x.StoreName)} <span class="text-muted">· ${esc(x.StoreType)}</span>${x.Started ? '' : ' <span class="badge bg-secondary-subtle text-secondary border">not started</span>'}</td>
            <td class="qs-num small">${x.Items}</td><td class="qs-num small">${QC.num(x.Value)}</td></tr>`).join('') || '<tr><td colspan="3" class="text-muted small">No stores. Add them in Masters &gt; Store / Location.</td></tr>';
    }

    const setModal = new bootstrap.Modal(document.getElementById('setModal'));
    document.getElementById('btnSettings').addEventListener('click', () => {
        const s = settings || {};
        document.getElementById('sPo').checked = !!s.PoApprovalRequired; document.getElementById('sAdj').checked = !!s.AdjApprovalRequired;
        document.getElementById('sCnt').checked = !!s.CountApprovalRequired; document.getElementById('sLot').checked = !!s.LotAcceptanceRequired;
        document.getElementById('sDed').checked = !!s.DeductOnConsumption; document.getElementById('sNear').value = s.NearExpiryDays || 60;
        setModal.show();
    });
    document.getElementById('sSave').addEventListener('click', async () => {
        const r = await QC.post('/QcStockDashboard/SaveSettings', {
            poApprovalRequired: document.getElementById('sPo').checked, adjApprovalRequired: document.getElementById('sAdj').checked,
            countApprovalRequired: document.getElementById('sCnt').checked, lotAcceptanceRequired: document.getElementById('sLot').checked,
            deductOnConsumption: document.getElementById('sDed').checked, nearExpiryDays: +document.getElementById('sNear').value || 0 });
        if (!r.success) return QC.fail(r.message);
        setModal.hide(); QC.ok('Settings saved'); load();
    });
    document.getElementById('btnPostCons').addEventListener('click', async () => {
        if (!(await QC.confirm('Post consumption to accounts?', 'One journal per day up to yesterday (reagents used by tests). Days already posted are skipped.', 'Post'))) return;
        const r = await QC.post('/QcStockDashboard/PostConsumption', {});
        if (!r.success) return QC.fail(r.message);
        QC.ok(r.data.DaysPosted ? `${r.data.DaysPosted} day(s) posted` : 'Nothing new to post');
    });
    document.getElementById('btnRefresh').addEventListener('click', load);
    load();
})();
