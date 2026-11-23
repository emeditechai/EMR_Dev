/* Quality & Compliance > Stock Management > Stock Reports (SQLScripts/2498-2500). window.QcStockRpt = { reports, perms, lookups, report }.
   Every report is one result set; its column names are the headings. Numbers are totalled where it makes sense. */
(function () {
    'use strict';
    const C = window.QcStockRpt || {}, L = C.lookups || {}, P = C.perms || {};
    const esc = QC.esc;
    const reports = C.reports || [];
    const $ = id => document.getElementById(id);
    $('rReport').innerHTML = reports.map(r => `<option value="${r.key}">${esc(r.title)}</option>`).join('');
    if (C.report && reports.some(r => r.key === C.report)) $('rReport').value = C.report;
    $('rStore').innerHTML = QC.options((L.stores || []).filter(s => s.IsMine).map(s => ({ Id: s.StoreId, Name: s.StoreName })), '', 'All stores');
    $('rItem').innerHTML = QC.options((L.items || []).map(i => ({ Id: i.ItemId, Name: i.ItemName + ' (' + i.ItemCode + ')' })), '', 'All items');
    $('rSupplier').innerHTML = QC.options((L.suppliers || []).map(s => ({ Id: s.SupplierId, Name: s.SupplierName })), '', 'All suppliers');
    $('rCategory').innerHTML = QC.options(L.categories || [], '', 'All categories');
    const d = new Date(); $('rTo').value = d.toISOString().slice(0, 10); $('rFrom').value = new Date(d.getFullYear(), d.getMonth(), 1, 12).toISOString().slice(0, 10);
    if (P.EXPORT) $('rExport').classList.remove('d-none');

    const SUM_ONLY = /^(value|book value|amount|taxable|cgst|sgst|igst|gst|discount|purchases|returns|net|closing value|stock value)$/i;

    function shape() {
        const r = reports.find(x => x.key === $('rReport').value) || { filters: [] }, f = r.filters;
        document.querySelectorAll('#rFilters .rf').forEach(el => el.classList.add('d-none'));
        f.forEach(k => document.querySelectorAll('#rFilters .rf-' + k).forEach(el => el.classList.remove('d-none')));
        $('rToLabel').textContent = f.includes('asOn') ? 'As on' : 'To';
        return f;
    }
    function params() {
        const f = shape(), p = { report: $('rReport').value };
        if (f.includes('dates')) { p.from = $('rFrom').value; p.to = $('rTo').value; }
        if (f.includes('asOn')) p.to = $('rTo').value;
        if (f.includes('days')) p.days = $('rDays').value;
        if (f.includes('store')) p.storeId = $('rStore').value;
        if (f.includes('item')) p.itemId = $('rItem').value;
        if (f.includes('supplier')) p.supplierId = $('rSupplier').value;
        if (f.includes('category')) p.categoryId = $('rCategory').value;
        if (f.includes('lot')) p.search = $('rLot').value;
        return p;
    }
    const isDate = v => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v);
    function cell(v) {
        if (v === null || v === undefined) return '';
        if (typeof v === 'number') return QC.num(v, Number.isInteger(v) ? 0 : (Math.abs(v) < 100 && String(v).split('.')[1]?.length > 2 ? 4 : 2));
        if (typeof v === 'boolean') return v ? 'Yes' : 'No';
        if (isDate(v)) return v.slice(11, 19) === '00:00:00' ? QC.date(v) : QC.dateTime(v);
        return esc(v);
    }

    async function run() {
        const p = params();
        if (p.report === 'TRACE' && !p.search && !p.itemId) return QC.fail('Enter a lot number (or pick an item) to trace.');
        $('rRows').innerHTML = '<tr><td class="text-center text-muted py-4">Running...</td></tr>'; $('rHead').innerHTML = ''; $('rFoot').innerHTML = '';
        const r = await QC.get('/QcStockReports/Data', p);
        if (!r.success) { $('rRows').innerHTML = `<tr><td class="text-danger text-center py-4">${esc(r.message)}</td></tr>`; return; }
        const rows = r.data || [];
        $('rInfo').textContent = `${rows.length} row(s)`;
        if (!rows.length) { $('rRows').innerHTML = '<tr><td class="text-center text-muted py-4">No rows for these filters.</td></tr>'; return; }
        const cols = Object.keys(rows[0]);
        const numeric = cols.filter(c => rows.some(x => typeof x[c] === 'number'));
        $('rHead').innerHTML = cols.map(c => `<th class="${numeric.includes(c) ? 'text-end' : ''} text-nowrap">${esc(c)}</th>`).join('');
        $('rRows').innerHTML = rows.map(x => `<tr>${cols.map(c => `<td class="${numeric.includes(c) ? 'qs-num' : ''} small">${cell(x[c])}</td>`).join('')}</tr>`).join('');
        // money columns only: quantities of different items are in different units
        const sums = cols.map(c => numeric.includes(c) && SUM_ONLY.test(c) ? rows.reduce((s, x) => s + (+x[c] || 0), 0) : null);
        if (sums.some(s => s !== null)) $('rFoot').innerHTML = `<tr class="fw-bold">${cols.map((c, i) => `<td class="${sums[i] !== null ? 'qs-num' : ''}">${i === 0 ? 'Total' : sums[i] !== null ? QC.num(sums[i]) : ''}</td>`).join('')}</tr>`;
    }

    $('rReport').addEventListener('change', () => { shape(); $('rRows').innerHTML = ''; $('rHead').innerHTML = ''; $('rFoot').innerHTML = ''; $('rInfo').textContent = ''; });
    $('rGo').addEventListener('click', run);
    $('rExport').addEventListener('click', () => {
        const p = params(), q = new URLSearchParams();
        Object.entries(p).forEach(([k, v]) => { if (v !== null && v !== undefined && v !== '') q.append(k, v); });
        window.location.href = '/QcStockReports/Export?' + q.toString();
    });
    shape();
    if (C.report) run();
})();
