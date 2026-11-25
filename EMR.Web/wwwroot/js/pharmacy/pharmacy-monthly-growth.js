// Reports > Pharmacy > Pharmacy Monthly Business Growth (SQLScripts/2548); same page as LAB / OPD monthly growth
(function () {
    const root = document.getElementById('mgRoot');
    if (!root) return;
    EmrExportLibs.guard('#btnExcel', 'excel'); EmrExportLibs.guard('#btnPdf', 'pdf');
    const dataUrl = root.dataset.url, branchName = root.dataset.branch || '';

    const C = { up: '#15803d', down: '#dc2626', last: '#94a3b8', avg: '#2563eb', b2c: '#0f766e', b2b: '#7c3aed', reg: '#0ea5e9', cost: '#f59e0b', margin: '#b45309' };
    let data = null, scope = 'branch', metric = 'NetRevenue', loadSeq = 0;
    const charts = {};

    const pad = n => String(n).padStart(2, '0');
    const ym = d => d.getFullYear() + '-' + pad(d.getMonth() + 1);
    const N = v => Number(v) || 0;
    const money0 = n => (Math.round(N(n)) < 0 ? '−₹' : '₹') + Math.abs(Math.round(N(n))).toLocaleString('en-IN');
    const short = n => { const a = Math.abs(N(n)), s = N(n) < 0 ? '−' : '';
        return a >= 1e7 ? s + '₹' + (a / 1e7).toFixed(2) + ' Cr' : a >= 1e5 ? s + '₹' + (a / 1e5).toFixed(2) + ' L' : a >= 1e3 ? s + '₹' + (a / 1e3).toFixed(1) + 'k' : s + '₹' + Math.round(a); };
    const num = n => N(n).toLocaleString('en-IN');
    const pct = (a, b) => N(b) > 0 ? N(a) * 100 / N(b) : null;
    const growth = (cur, prev) => N(prev) > 0 ? (N(cur) - N(prev)) * 100 / N(prev) : null;
    const pctText = v => v === null || v === undefined ? '—' : v.toFixed(1) + '%';
    const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const mLabel = k => new Date(k + '-01T00:00:00').toLocaleDateString('en-GB', { month: 'short', year: '2-digit' });
    const mLong = k => new Date(k + '-01T00:00:00').toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
    const sum = (list, k) => list.reduce((t, r) => t + N(r[k]), 0);
    const isMoney = k => !['Bills', 'Patients', 'NewPatients', 'Items', 'CancelledBills'].includes(k);
    const fmt = (k, v) => isMoney(k) ? money0(v) : num(v);

    function chip(g, title) {
        if (g === null) return '<span class="chip flat">—</span>';
        const cls = g > 0.05 ? 'up' : (g < -0.05 ? 'down' : 'flat');
        const ico = g > 0.05 ? 'bi-arrow-up-short' : (g < -0.05 ? 'bi-arrow-down-short' : 'bi-dash');
        return `<span class="chip ${cls}" title="${esc(title || '')}"><i class="bi ${ico}"></i>${Math.abs(g).toFixed(1)}%</span>`;
    }

    // ── range ──────────────────────────────────────────────────────────────
    function setRange(range) {
        const t = new Date(); let f, to = new Date(t.getFullYear(), t.getMonth(), 1);
        const fyStart = t.getMonth() >= 3 ? t.getFullYear() : t.getFullYear() - 1;
        if (range === '6m') f = new Date(t.getFullYear(), t.getMonth() - 5, 1);
        else if (range === '12m') f = new Date(t.getFullYear(), t.getMonth() - 11, 1);
        else if (range === 'fy') f = new Date(fyStart, 3, 1);
        else if (range === 'lfy') { f = new Date(fyStart - 1, 3, 1); to = new Date(fyStart, 2, 1); }
        $('#txtFrom').val(ym(f)); $('#txtTo').val(ym(to));
        $('.btn-quick').removeClass('active').filter(`[data-range="${range}"]`).addClass('active');
    }

    // ── load ───────────────────────────────────────────────────────────────
    function load() {
        const seq = ++loadSeq, from = $('#txtFrom').val(), to = $('#txtTo').val();
        if (!from || !to) return;
        $('#stateError').addClass('d-none');
        $('#mgBody').removeClass('d-none');
        const cards = Array.from(document.querySelectorAll('#mgBody .cr-card'));
        EmrShimmer.on(cards);
        $('#btnExcel, #btnPdf, #btnPrint').prop('disabled', true);
        $.get(dataUrl, { fromMonth: from, toMonth: to, scope: scope })
            .done(function (res) {
                if (seq !== loadSeq) return;
                EmrShimmer.off(cards);
                if (!res || !res.success) { fail(res?.message || 'Unable to load the report.'); return; }
                data = res.data || {};
                render();
                $('#btnExcel, #btnPdf, #btnPrint').prop('disabled', false);
            })
            .fail(function (xhr) {
                if (seq !== loadSeq) return;
                EmrShimmer.off(cards);
                fail(xhr.status === 403 ? 'You do not have access to this report.' : 'Server error while loading the report. Please try again.');
            });
    }
    function fail(msg) { $('#stateError').text(msg).removeClass('d-none'); if (!data) $('#mgBody').addClass('d-none'); }

    // months of the range, each with last year's same month and the previous month attached
    function months() {
        const all = data.months || [], byKey = {};
        all.forEach(r => byKey[r.Month] = r);
        const lastYearKey = k => { const [y, m] = k.split('-'); return (Number(y) - 1) + '-' + m; };
        const range = all.filter(r => r.InRange === true || r.InRange === 1);
        return range.map(r => {
            const idx = all.indexOf(r);
            return Object.assign({}, r, { prev: all[idx - 1] || null, ly: byKey[lastYearKey(r.Month)] || null,
                partial: N(r.DaysElapsed) > 0 && N(r.DaysElapsed) < N(r.DaysInMonth), future: N(r.DaysElapsed) === 0 });
        });
    }

    function render() {
        const ms = months(), meta = (data.meta && data.meta[0]) || {};
        $('#lblScope').text(scope === 'all' ? `All my branches (${num(meta.BranchCount)})` : (branchName ? 'Branch ' + branchName : 'This branch'));
        $('#lblRange').text(ms.length ? `${mLong(ms[0].Month)} – ${mLong(ms[ms.length - 1].Month)} (${ms.length} months)` : '');
        renderKpis(ms); renderVerdict(ms);
        renderMain(ms); renderGrowth(ms); renderCumul(ms); renderMix(ms); renderProfit(ms);
        renderTable(ms); renderDim();
    }

    // ── breakdown tabs: category / prescribing doctor / manufacturer / customer type / branch ──
    let dim = { sec: 'categories', key: 'Category' };
    function renderDim() {
        if (!data) return;
        const q = ($('#txtDimSearch').val() || '').trim().toLowerCase();
        const rows = (data[dim.sec] || []).filter(r => !q || String(r[dim.key] || '').toLowerCase().includes(q));
        renderHeat('#tblDim', rows, dim.key, months(), dim.sec === 'branches' && scope !== 'all'
            ? 'Only this branch is shown. Choose "All my branches" and Apply to compare branches.' : null);
    }
    $('#dimTabs').on('click', '.nav-link', function () {
        $('#dimTabs .nav-link').removeClass('active'); $(this).addClass('active');
        dim = { sec: $(this).data('dim'), key: $(this).data('key') };
        $('#lblDim').text($(this).data('label')); renderDim();
    });
    $('#txtDimSearch').on('input', renderDim);

    // ── KPIs and verdict ───────────────────────────────────────────────────
    function renderKpis(ms) {
        const done = ms.filter(r => !r.future);
        const net = sum(ms, 'NetRevenue'), lyNet = ms.reduce((t, r) => t + N(r.ly?.NetRevenue), 0);
        const profit = sum(ms, 'GrossProfit'), taxable = sum(ms, 'TaxableSales');
        $('#kNet').text(money0(net));
        $('#kNetSub').html(`${chip(growth(net, lyNet), 'Same months last year: ' + money0(lyNet))} vs last year ${money0(lyNet)}`);
        $('#kProfit').text(money0(profit)).toggleClass('text-danger', profit < 0);
        $('#kProfitSub').text(`${pctText(pct(profit, taxable))} margin on sales before GST · cost ${money0(sum(ms, 'CostOfGoods'))}`);
        const full = done.filter(r => !r.partial);
        const avg = full.length ? sum(full, 'NetRevenue') / full.length : 0;
        $('#kAvg').text(money0(avg)); $('#kAvgSub').text(`${full.length} complete month(s)`);
        const ranked = full.slice().sort((a, b) => N(b.NetRevenue) - N(a.NetRevenue));
        const best = ranked[0], worst = ranked[ranked.length - 1];
        $('#kBest').text(best ? money0(best.NetRevenue) : '—'); $('#kBestSub').text(best ? mLong(best.Month) : 'no complete month');
        $('#kWorst').text(worst ? money0(worst.NetRevenue) : '—'); $('#kWorstSub').text(worst ? mLong(worst.Month) : 'no complete month');
        const g = full.map(r => growth(r.NetRevenue, r.prev?.NetRevenue)).filter(v => v !== null);
        const up = g.filter(v => v > 0.05).length, down = g.filter(v => v < -0.05).length;
        $('#kUpDown').html(`<span class="pos">${up}</span> / <span class="neg">${down}</span>`);
        $('#kUpDownSub').text('vs the month before');
        $('#kPatients').text(num(sum(ms, 'Patients'))); $('#kPatientsSub').text(`${num(sum(ms, 'NewPatients'))} new · ${num(sum(ms, 'Bills'))} bills`);
    }

    function renderVerdict(ms) {
        const full = ms.filter(r => !r.future && !r.partial);
        const net = sum(ms, 'NetRevenue'), lyNet = ms.reduce((t, r) => t + N(r.ly?.NetRevenue), 0);
        const yoy = growth(net, lyNet);
        const last = full[full.length - 1], mom = last ? growth(last.NetRevenue, last.prev?.NetRevenue) : null;
        const cls = yoy === null ? 'flat' : (yoy > 0.05 ? 'up' : (yoy < -0.05 ? 'down' : 'flat'));
        const parts = [];
        if (yoy === null) parts.push(`<b>${money0(net)}</b> net revenue in the period; no business in the same months last year to compare with.`);
        else parts.push(`Business <b>${yoy >= 0 ? 'grew' : 'fell'} ${Math.abs(yoy).toFixed(1)}%</b> against the same months last year (${money0(net)} vs ${money0(lyNet)}, ${yoy >= 0 ? '+' : '−'}${money0(Math.abs(net - lyNet)).replace('−', '')}).`);
        if (last && mom !== null) parts.push(`${mLong(last.Month)}, the last complete month, was ${mom >= 0 ? 'up' : 'down'} ${Math.abs(mom).toFixed(1)}% on the month before.`);
        const lossMonths = full.filter(r => N(r.GrossProfit) < 0).length;
        if (lossMonths) parts.push(`<span class="neg">${lossMonths} month(s) sold below cost.</span>`);
        const cur = ms.find(r => r.partial);
        if (cur && N(cur.DaysElapsed) > 0) parts.push(`${mLong(cur.Month)} is running at ${money0(N(cur.NetRevenue) / N(cur.DaysElapsed) * N(cur.DaysInMonth))} for the month at the current daily pace.`);
        $('#verdict').attr('class', 'verdict mb-2 ' + cls)
            .html(`<i class="bi ${cls === 'down' ? 'bi-graph-down-arrow' : 'bi-graph-up-arrow'} me-2"></i>` + parts.join(' '));
    }

    // ── charts ─────────────────────────────────────────────────────────────
    function draw(id, cfg) { if (charts[id]) charts[id].destroy(); charts[id] = new Chart(document.getElementById(id), cfg); }
    const axisMoney = { ticks: { font: { size: 10 }, callback: v => short(v) }, grid: { color: '#f1f5f9' } };
    const axisX = { grid: { display: false }, ticks: { font: { size: 10 } } };

    function renderMain(ms) {
        const k = metric, labels = ms.map(r => mLabel(r.Month));
        const cur = ms.map(r => N(r[k])), ly = ms.map(r => r.ly ? N(r.ly[k]) : null);
        const colors = ms.map(r => { const g = growth(r[k], r.prev?.[k]); return g === null || g >= 0 ? C.up : C.down; });
        const avg3 = cur.map((v, i) => i < 2 ? null : (cur[i] + cur[i - 1] + cur[i - 2]) / 3);
        $('#lblMetric').text('(' + $(`.btn-metric[data-metric="${k}"]`).text().toLowerCase() + ')');
        const ticks = isMoney(k) ? axisMoney : { ticks: { font: { size: 10 } }, grid: { color: '#f1f5f9' } };
        draw('chMain', {
            type: 'bar',
            data: { labels, datasets: [
                { type: 'bar', label: 'This period', data: cur, backgroundColor: colors, borderRadius: 4, maxBarThickness: 42, order: 3 },
                { type: 'bar', label: 'Same month last year', data: ly, backgroundColor: C.last + '88', borderRadius: 4, maxBarThickness: 42, order: 4 },
                { type: 'line', label: '3-month average', data: avg3, borderColor: C.avg, backgroundColor: C.avg, borderWidth: 2, pointRadius: 2, tension: .35, order: 1, spanGaps: true }
            ] },
            options: { maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
                plugins: { legend: { display: false }, tooltip: { callbacks: {
                    label: c => `${c.dataset.label}: ${fmt(k, c.parsed.y)}`,
                    afterBody: items => { const r = ms[items[0].dataIndex];
                        const mom = growth(r[k], r.prev?.[k]), yoy = growth(r[k], r.ly?.[k]);
                        return [`vs previous month: ${pctText(mom)}`, `vs last year: ${pctText(yoy)}`].concat(r.partial ? ['(month to date)'] : []); } } } },
                scales: { x: axisX, y: ticks } }
        });
    }

    function renderGrowth(ms) {
        const mom = ms.map(r => growth(r.NetRevenue, r.prev?.NetRevenue)), yoy = ms.map(r => growth(r.NetRevenue, r.ly?.NetRevenue));
        draw('chGrowth', {
            type: 'bar',
            data: { labels: ms.map(r => mLabel(r.Month)), datasets: [
                { label: 'vs previous month', data: mom, backgroundColor: mom.map(v => (v ?? 0) >= 0 ? C.up : C.down), borderRadius: 3, maxBarThickness: 26 },
                { type: 'line', label: 'vs same month last year', data: yoy, borderColor: C.avg, backgroundColor: C.avg, pointRadius: 3, tension: .3, spanGaps: true }
            ] },
            options: { maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
                plugins: { legend: { labels: { boxWidth: 10, font: { size: 10 } } }, tooltip: { callbacks: { label: c => `${c.dataset.label}: ${pctText(c.parsed.y)}` } } },
                scales: { x: axisX, y: { ticks: { font: { size: 10 }, callback: v => v + '%' }, grid: { color: c => c.tick.value === 0 ? '#475569' : '#f1f5f9' } } } }
        });
    }

    function renderCumul(ms) {
        let a = 0, b = 0;
        const cur = ms.map(r => (a += N(r.NetRevenue))), ly = ms.map(r => (b += N(r.ly?.NetRevenue)));
        draw('chCumul', {
            type: 'line',
            data: { labels: ms.map(r => mLabel(r.Month)), datasets: [
                { label: 'This period', data: cur, borderColor: C.b2c, backgroundColor: C.b2c + '22', fill: true, tension: .3, pointRadius: 2 },
                { label: 'Last year', data: ly, borderColor: C.last, borderDash: [5, 4], pointRadius: 0, tension: .3 }
            ] },
            options: { maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
                plugins: { legend: { labels: { boxWidth: 10, font: { size: 10 } } }, tooltip: { callbacks: { label: c => `${c.dataset.label}: ${money0(c.parsed.y)}` } } },
                scales: { x: axisX, y: axisMoney } }
        });
    }

    function renderMix(ms) {
        draw('chMix', {
            type: 'bar',
            data: { labels: ms.map(r => mLabel(r.Month)), datasets: [
                { label: 'Walk-in', data: ms.map(r => N(r.WalkInRevenue)), backgroundColor: C.b2c, stack: 's', maxBarThickness: 34 },
                { label: 'Patient', data: ms.map(r => N(r.PatientRevenue)), backgroundColor: C.reg, stack: 's', maxBarThickness: 34 },
                { label: 'Credit customer', data: ms.map(r => N(r.CreditRevenue)), backgroundColor: C.b2b, stack: 's', borderRadius: 3, maxBarThickness: 34 }
            ] },
            options: { maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
                plugins: { legend: { labels: { boxWidth: 10, font: { size: 10 } } },
                    tooltip: { callbacks: { label: c => { const r = ms[c.dataIndex]; return `${c.dataset.label}: ${money0(c.parsed.y)} (${pctText(pct(c.parsed.y, r.NetRevenue))})`; } } } },
                scales: { x: { ...axisX, stacked: true }, y: { ...axisMoney, stacked: true } } }
        });
    }

    function renderProfit(ms) {
        draw('chProfit', {
            type: 'bar',
            data: { labels: ms.map(r => mLabel(r.Month)), datasets: [
                { label: 'Gross profit', data: ms.map(r => N(r.GrossProfit)), backgroundColor: ms.map(r => N(r.GrossProfit) >= 0 ? C.up : C.down), stack: 's', maxBarThickness: 34, yAxisID: 'y' },
                { label: 'Cost of goods', data: ms.map(r => N(r.CostOfGoods)), backgroundColor: C.cost, stack: 's', borderRadius: 3, maxBarThickness: 34, yAxisID: 'y' },
                { type: 'line', label: 'Margin %', data: ms.map(r => pct(r.GrossProfit, r.TaxableSales)), borderColor: C.margin, backgroundColor: C.margin, pointRadius: 2, tension: .3, yAxisID: 'y1', spanGaps: true }
            ] },
            options: { maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
                plugins: { legend: { labels: { boxWidth: 10, font: { size: 10 } } },
                    tooltip: { callbacks: { label: c => c.dataset.yAxisID === 'y1' ? `Margin: ${pctText(c.parsed.y)}` : `${c.dataset.label}: ${money0(c.parsed.y)}` } } },
                scales: { x: { ...axisX, stacked: true }, y: { ...axisMoney, stacked: true },
                          y1: { position: 'right', grid: { display: false }, ticks: { font: { size: 10 }, callback: v => v + '%' } } } }
        });
    }

    // ── month table ────────────────────────────────────────────────────────
    const cols = [
        { k: 'Bills', label: 'Bills' }, { k: 'Patients', label: 'Customers' }, { k: 'NewPatients', label: 'New customers' }, { k: 'Items', label: 'Qty sold' },
        { k: 'Mrp', label: 'MRP value' }, { k: 'Discount', label: 'Discount' }, { k: 'Returned', label: 'Returned' }, { k: 'Gst', label: 'GST' },
        { k: 'WalkInRevenue', label: 'Walk-in' }, { k: 'PatientRevenue', label: 'Patient' }, { k: 'CreditRevenue', label: 'Credit customer' },
        { k: 'NetRevenue', label: 'Net revenue' },
        { k: '_mom', label: 'vs prev. month', g: r => growth(r.NetRevenue, r.prev?.NetRevenue) },
        { k: 'LyNet', label: 'Last year', v: r => N(r.ly?.NetRevenue) },
        { k: '_yoy', label: 'vs last year', g: r => growth(r.NetRevenue, r.ly?.NetRevenue) },
        { k: 'TaxableSales', label: 'Sales before GST' }, { k: 'CostOfGoods', label: 'Cost of goods' }, { k: 'GrossProfit', label: 'Gross profit' },
        { k: '_gm', label: 'Margin %', p: r => pct(r.GrossProfit, r.TaxableSales) },
        { k: 'Collected', label: 'Collected' }, { k: 'DueOnBills', label: 'Due on bills' }, { k: 'CancelledBills', label: 'Cancelled bills' }, { k: 'Refunds', label: 'Refunds' }
    ];


    const cellVal = (c, r) => c.v ? c.v(r) : r[c.k];

    function renderTable(ms) {
        const $t = $('#tblMonths');
        $t.find('thead').html('<tr><th class="ps-3">Month</th>' + cols.map(c => `<th class="text-end">${c.label}</th>`).join('') + '</tr>');
        $t.find('tbody').html(ms.length ? ms.map(r => `<tr class="${r.partial ? 'partial' : ''}"><td class="ps-3 fw-semibold">${mLong(r.Month)}</td>` + cols.map(c => {
            if (c.g) return `<td class="text-end">${chip(c.g(r))}</td>`;
            if (c.p) { const v = c.p(r); return `<td class="text-end num ${v !== null && v < 0 ? 'neg' : ''}">${pctText(v)}</td>`; }
            const v = cellVal(c, r);
            return `<td class="text-end ${isMoney(c.k) ? 'amt' : 'num'} ${c.k === 'GrossProfit' && N(v) < 0 ? 'neg' : ''} ${c.k === 'NetRevenue' ? 'fw-bold' : ''}">${fmt(c.k, v)}</td>`;
        }).join('') + '</tr>').join('') : `<tr><td colspan="${cols.length + 1}" class="text-center text-muted py-4">Nothing for the selected months.</td></tr>`);
        const net = sum(ms, 'NetRevenue'), ly = ms.reduce((t, r) => t + N(r.ly?.NetRevenue), 0);
        $t.find('tfoot').html(ms.length ? '<tr><td class="ps-3">Total</td>' + cols.map(c => {
            if (c.k === '_yoy') return `<td class="text-end">${chip(growth(net, ly))}</td>`;
            if (c.k === '_gm') return `<td class="text-end num">${pctText(pct(sum(ms, 'GrossProfit'), sum(ms, 'TaxableSales')))}</td>`;
            if (c.g) return '<td></td>';
            const v = c.k === 'LyNet' ? ly : sum(ms, c.k);
            return `<td class="text-end ${isMoney(c.k) ? 'amt' : 'num'}">${fmt(c.k, v)}</td>`;
        }).join('') + '</tr>' : '');
    }

    // ── heatmaps (name x month) ────────────────────────────────────────────
    function renderHeat(sel, rows, key, ms, note) {
        const keys = ms.map(r => r.Month), names = {};
        rows.forEach(r => { names[r[key]] = (names[r[key]] || 0) + N(r.Net); });
        const order = Object.keys(names).sort((a, b) => names[b] - names[a]);
        const cell = {}; rows.forEach(r => cell[r[key] + '|' + r.Month] = N(r.Net));
        const max = Math.max(1, ...rows.map(r => N(r.Net)));
        const $t = $(sel);
        $t.find('thead').html(`<tr><th class="ps-3 sticky-col">${key}</th>` + keys.map(k => `<th class="text-end">${mLabel(k)}</th>`).join('') + '<th class="text-end pe-3">Total</th><th class="text-end pe-3">Trend</th></tr>');
        $t.find('tbody').html(order.length ? order.map(nm => {
            const vals = keys.map(k => cell[nm + '|' + k] || 0);
            const first = vals.find(v => v > 0) || 0, lastV = vals[vals.length - 1];
            return `<tr><td class="ps-3 fw-semibold sticky-col">${esc(nm)}</td>` + vals.map(v => {
                const a = v / max; return `<td class="h" style="background:rgba(15,118,110,${(a * .85).toFixed(3)});color:${a > .5 ? '#fff' : '#0f172a'}">${v ? short(v) : '·'}</td>`;
            }).join('') + `<td class="text-end amt fw-bold pe-3">${money0(names[nm])}</td><td class="text-end pe-3">${chip(growth(lastV, first), 'Last month vs first month with business')}</td></tr>`;
        }).join('') + (note ? `<tr><td colspan="${keys.length + 3}" class="text-muted fs-9 ps-3"><i class="bi bi-info-circle me-1"></i>${esc(note)}</td></tr>` : '') : `<tr><td colspan="${keys.length + 3}" class="text-center text-muted py-4">Nothing for the selected months.</td></tr>`);
    }

    // ── exports ────────────────────────────────────────────────────────────
    const fileBase = () => `Pharmacy_Monthly_Business_Growth_${$('#txtFrom').val()}_to_${$('#txtTo').val()}`;
    function exportRows() {
        return months().map(r => {
            const o = { Month: mLong(r.Month) + (r.partial ? ' (to date)' : '') };
            cols.forEach(c => {
                const v = c.g ? c.g(r) : c.p ? c.p(r) : cellVal(c, r);
                o[c.label] = (c.g || c.p) ? (v === null ? '' : Number(v.toFixed(1))) : N(v);
            });
            return o;
        });
    }
    const pivot = (rows, key) => {
        const ks = months().map(r => r.Month), out = {};
        rows.forEach(r => { (out[r[key]] = out[r[key]] || { [key]: r[key] })[mLabel(r.Month)] = N(r.Net); });
        return Object.values(out).map(o => { ks.forEach(k => { if (o[mLabel(k)] === undefined) o[mLabel(k)] = 0; }); return o; });
    };

    $('#btnExcel').on('click', function () {
        const wb = XLSX.utils.book_new();
        XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(exportRows()), 'Month-wise');
        [['categories', 'Category', 'By category'], ['doctors', 'Doctor', 'By prescribing doctor'], ['manufacturers', 'Manufacturer', 'By manufacturer'],
         ['customertypes', 'CustomerType', 'By customer type'], ['branches', 'Branch', 'By branch']].forEach(([sec, key, name]) => {
            const rows = pivot(data[sec] || [], key);
            if (rows.length) XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(rows), name);
        });
        XLSX.writeFile(wb, fileBase() + '.xlsx');
    });

    $('#btnPdf').on('click', function () {
        const { jsPDF } = window.jspdf; const doc = new jsPDF({ orientation: 'landscape', unit: 'pt', format: 'a4' });
        doc.setFontSize(14); doc.text('Pharmacy Monthly Business Growth', 40, 36);
        doc.setFontSize(9); doc.text(`${$('#lblScope').text()} · ${$('#lblRange').text()}`, 40, 50);
        doc.setFontSize(9); doc.text(doc.splitTextToSize($('#verdict').text(), 760), 40, 66);
        // the main chart as a picture, then the table
        try { doc.addImage(charts.chMain.toBase64Image(), 'PNG', 40, 90, 760, 200); } catch (e) { /* chart not ready */ }
        const rows = exportRows(), head = Object.keys(rows[0] || { Month: '' });
        doc.autoTable({ startY: 300, head: [head], body: rows.map(r => head.map(h => typeof r[h] === 'number' ? r[h].toLocaleString('en-IN') : r[h])),
            styles: { fontSize: 6.5, cellPadding: 2 }, headStyles: { fillColor: [15, 118, 110] }, margin: { left: 40, right: 40 } });
        doc.save(fileBase() + '.pdf');
    });
    $('#btnPrint').on('click', () => window.print());

    // ── filters ────────────────────────────────────────────────────────────
    $('.btn-quick').on('click', function () { setRange($(this).data('range')); load(); });
    $('.btn-scope').on('click', function () { scope = $(this).data('scope'); $('.btn-scope').removeClass('active'); $(this).addClass('active'); load(); });
    $('.btn-metric').on('click', function () { metric = $(this).data('metric'); $('.btn-metric').removeClass('active'); $(this).addClass('active'); if (data) renderMain(months()); });
    $('#txtFrom, #txtTo').on('change', () => $('.btn-quick').removeClass('active'));
    $('#btnApply').on('click', load);

    setRange('12m');
    load();
})();
