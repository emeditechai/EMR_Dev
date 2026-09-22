/*
 * Reports > LAB registers: one script for every page built on Views/Reports/_LabReportShell.cshtml.
 * A page calls LabReport.init(config); the server returns { success, scope, data: { summary, groups, rows, options } }
 * (see SQLScripts/2124). Visibility (branch / Administrator / own data) is decided on the server, never here.
 *
 * config = {
 *   report, dataUrl, title, defaultRange ('today' | 'month' ...), seeAll, branchName, searchPlaceholder,
 *   filters:   [{ id, label, options: [[value, text]], fromOptions: 'createdBy', allLabel, adminOnly }],
 *   kpis:      [{ label, color, value: (s, h) => html, sub: (s, h) => html }],
 *   groups:    [{ key, label, rowField, byId, name: (group, h) => html, adminOnly }],
 *   groupCols: [{ field, label, money, total: 'sum' | 'max' | 'none', fmt: (v, h) => html }],
 *   shareOf:   field used for the "share" bar in Summary,
 *   cols:      [{ label, cls, html: (row, h) => html, text: (row, h) => export value, sum: field, money }],
 *   rowClass:  row => css class
 * }
 */
window.LabReport = (function () {
    const h = {
        esc: s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
        money: n => '₹' + (Number(n) || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
        num: n => (Number(n) || 0).toLocaleString('en-IN'),
        fmtD: s => { if (!s) return ''; const d = new Date(s); return isNaN(d) ? '' : d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }); },
        fmtDT: s => { if (!s) return ''; const d = new Date(s); return isNaN(d) ? '' : d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) + ', ' + d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' }); },
        pill: (text, cls) => `<span class="badge border ${cls}">${String(text ?? '')}</span>`
    };
    const pad = n => String(n).padStart(2, '0');
    const iso = d => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());

    function init(cfg) {
        let data = null, view = 'summary', drill = null, seq = 0;
        const groups = cfg.groups.filter(g => !g.adminOnly || cfg.seeAll);
        const filters = (cfg.filters || []).filter(f => !f.adminOnly || cfg.seeAll);

        // report-specific filters, before the search box
        filters.forEach(f => {
            const opts = (f.options || []).map(o => `<option value="${h.esc(o[0])}">${h.esc(o[1])}</option>`).join('');
            $(`<div class="col-6 col-md-2"><label class="form-label fs-9 fw-bold text-muted text-uppercase mb-0" for="lrF_${f.id}">${h.esc(f.label)}</label>
                 <select id="lrF_${f.id}" class="form-select form-select-sm lr-filter" data-id="${f.id}" autocomplete="off"><option value="">${h.esc(f.allLabel || 'All')}</option>${opts}</select></div>`)
                .insertBefore('#lrSearchCol');
        });
        $('#lrSearch').attr('placeholder', cfg.searchPlaceholder || 'Search...');
        $('#lrGroup').html(groups.map(g => `<option value="${g.key}">${h.esc(g.label)}</option>`).join(''));
        $('#lrDetail thead').html('<tr><th class="ps-3">#</th>' + cfg.cols.map(c => `<th class="${c.cls || ''}">${h.esc(c.label)}</th>`).join('') + '</tr>');

        function setRange(r) {
            const t = new Date(); let f = new Date(t), to = new Date(t);
            if (r === 'yesterday') { f.setDate(t.getDate() - 1); to = new Date(f); }
            else if (r === 'week') f.setDate(t.getDate() - 6);
            else if (r === 'month') f = new Date(t.getFullYear(), t.getMonth(), 1);
            else if (r === 'lastmonth') { f = new Date(t.getFullYear(), t.getMonth() - 1, 1); to = new Date(t.getFullYear(), t.getMonth(), 0); }
            else if (r === 'year') f.setDate(t.getDate() - 364);   // default for dues: a year of bills
            $('#lrFrom').val(iso(f)); $('#lrTo').val(iso(to));
            $('.btn-quick').removeClass('active').filter(`[data-range="${r}"]`).addClass('active');
        }

        function load() {
            const my = ++seq, from = $('#lrFrom').val(), to = $('#lrTo').val();
            if (!from || !to) return;
            const q = { report: cfg.report, fromDate: from, toDate: to, search: $('#lrSearch').val() };
            $('.lr-filter').each(function () { q[$(this).data('id')] = $(this).val(); });
            $('#lrError').addClass('d-none'); $('#lrLoading').removeClass('d-none'); $('#lrEmpty').addClass('d-none');
            $('#lrSummary tbody, #lrDetail tbody, #lrSummary tfoot, #lrDetail tfoot').empty();
            $('#lrExcel, #lrPdf, #lrPrint').prop('disabled', true);
            $('#lrRange').text(h.fmtD(from) + (from === to ? '' : ' – ' + h.fmtD(to)));
            $.get(cfg.dataUrl, q).done(res => {
                if (my !== seq) return;
                $('#lrLoading').addClass('d-none');
                if (!res || !res.success) { $('#lrError').text(res?.message || 'Unable to load the report.').removeClass('d-none'); return; }
                data = res.data || {}; drill = null;
                fillOptions(); renderKpis(); render();
            }).fail(() => {
                if (my !== seq) return;
                $('#lrLoading').addClass('d-none');
                $('#lrError').text('Server error while loading the report. Please try again.').removeClass('d-none');
            });
        }

        function fillOptions() {
            filters.filter(f => f.fromOptions).forEach(f => {
                const $s = $('#lrF_' + f.id), have = new Set($s.find('option').map((_, o) => o.value).get());
                (data.options || []).filter(o => o.FilterKey === f.fromOptions && !have.has(String(o.Value)))
                    .forEach(o => $s.append(`<option value="${h.esc(o.Value)}">${h.esc(o.Text)}</option>`));
            });
        }

        function renderKpis() {
            const s = data.summary || {};
            $('#lrKpis').html(cfg.kpis.map(k => `<div class="col-6 col-lg"><div class="lr-card lr-kpi" style="--k:${k.color || 'var(--lr-accent)'}">
                <div class="k-label">${h.esc(k.label)}</div><div class="k-val">${k.value(s, h)}</div><div class="k-sub">${k.sub ? k.sub(s, h) : ''}</div></div></div>`).join(''));
        }

        const groupDef = () => groups.find(g => g.key === $('#lrGroup').val()) || groups[0];
        const groupRows = () => (data.groups || []).filter(r => r.GroupKey === groupDef().key);
        const detailRows = () => (data.rows || []).filter(r => !drill || String(r[drill.field] ?? '') === String(drill.value ?? ''));

        function render() {
            // summaryAlways: the Summary still makes sense with no detail rows (e.g. credit limits of partners with nothing due)
            const empty = !(data?.rows || []).length && !(cfg.summaryAlways && (data?.groups || []).length);
            $('#lrEmpty').toggleClass('d-none', !empty);
            $('#lrExcel, #lrPdf, #lrPrint').prop('disabled', empty);
            $('#lrSummary').toggleClass('d-none', view !== 'summary' || empty);
            $('#lrDetail').toggleClass('d-none', view !== 'detail' || empty || !(data?.rows || []).length);
            $('#lrGroupBox').toggleClass('d-none', view !== 'summary');
            $('#lrDrill').toggleClass('d-none', !(view === 'detail' && drill))
                .html(drill ? `${h.esc(drill.label)}: <strong>${drill.display}</strong> <a href="#" id="lrClearDrill" class="ms-1 text-reset" title="Show all">×</a>` : '');
            if (empty) { $('#lrCount').text(''); return; }
            view === 'summary' ? renderSummary() : renderDetail();
        }

        function renderSummary() {
            const g = groupDef(), rows = groupRows();
            const shareTotal = cfg.shareOf ? rows.reduce((a, r) => a + (Number(r[cfg.shareOf]) || 0), 0) : 0;
            $('#lrSummary thead').html(`<tr><th class="ps-3">${h.esc(g.label)}</th>` +
                cfg.groupCols.map(c => `<th class="${c.money || c.num ? 'text-end' : ''}">${h.esc(c.label)}</th>`).join('') +
                (cfg.shareOf ? '<th>Share</th>' : '') + '</tr>');
            $('#lrSummary tbody').html(rows.map((r, i) => {
                const name = g.name ? g.name(r, h) : h.esc(r.GroupName);
                return `<tr class="grp-row" data-i="${i}" title="Show the records in this group">
                    <td class="ps-3 fw-semibold">${name}</td>` +
                    cfg.groupCols.map(c => `<td class="${c.money || c.num ? 'text-end amt' : ''}">${c.fmt ? c.fmt(r[c.field], h) : (c.money ? h.money(r[c.field]) : h.esc(r[c.field] ?? ''))}</td>`).join('') +
                    (cfg.shareOf ? `<td><div class="lr-bar"><span style="width:${shareTotal ? ((Number(r[cfg.shareOf]) || 0) / shareTotal * 100).toFixed(1) : 0}%"></span></div></td>` : '') +
                    '</tr>';
            }).join(''));
            $('#lrSummary tfoot').html('<tr><td class="ps-3">Total</td>' + cfg.groupCols.map(c => {
                const vals = rows.map(r => Number(r[c.field]) || 0);
                if (c.total === 'none' || (!c.money && !c.num)) return '<td></td>';
                const v = c.total === 'max' ? Math.max(0, ...vals) : vals.reduce((a, b) => a + b, 0);
                return `<td class="text-end amt">${c.money ? h.money(v) : (c.fmt ? c.fmt(v, h) : h.num(v))}</td>`;
            }).join('') + (cfg.shareOf ? '<td></td>' : '') + '</tr>');
            $('#lrCount').text(`${rows.length} group(s) · click a line to see its records`);
        }

        function renderDetail() {
            const rows = detailRows();
            if (!rows.length) {
                $('#lrDetail tbody').html(`<tr><td colspan="${cfg.cols.length + 1}" class="text-center text-muted py-4">No records in this group for the selected period.</td></tr>`);
                $('#lrDetail tfoot').empty(); $('#lrCount').text('0 record(s)');
                return;
            }
            $('#lrDetail tbody').html(rows.map((r, i) => `<tr class="${cfg.rowClass ? cfg.rowClass(r) : ''}"><td class="ps-3 text-muted">${i + 1}</td>` +
                cfg.cols.map(c => `<td class="${c.cls || ''}">${c.html(r, h)}</td>`).join('') + '</tr>').join(''));
            const hasSums = cfg.cols.some(c => c.sum);
            $('#lrDetail tfoot').html(hasSums ? '<tr><td class="ps-3"></td>' + cfg.cols.map((c, i) => {
                if (c.sum) return `<td class="text-end amt">${h.money(rows.reduce((a, r) => a + (Number(r[c.sum]) || 0), 0))}</td>`;
                return i === 0 ? `<td>Total (${rows.length})</td>` : '<td></td>';
            }).join('') + '</tr>' : '');
            $('#lrCount').text(`${rows.length} record(s)`);
        }

        // ── export: whichever view is on screen ──
        function exportTable() {
            if (view === 'summary') {
                const g = groupDef();
                return { head: [g.label, ...cfg.groupCols.map(c => c.label)],
                         rows: groupRows().map(r => [$('<div>').html(g.name ? g.name(r, h) : h.esc(r.GroupName)).text(),
                                                     ...cfg.groupCols.map(c => c.money || c.num ? (Number(r[c.field]) || 0) : $('<div>').html(c.fmt ? c.fmt(r[c.field], h) : h.esc(r[c.field] ?? '')).text())]) };
            }
            const ec = cfg.cols.filter(c => !c.noExport);   // buttons / links are left out of exports
            return { head: ec.map(c => c.label),
                     rows: detailRows().map(r => ec.map(c => c.text ? c.text(r, h) : $('<div>').html(c.html(r, h)).text().trim())) };
        }
        const fileBase = () => `${cfg.title.replace(/[^A-Za-z0-9]+/g, '_')}_${view}_${$('#lrFrom').val()}_to_${$('#lrTo').val()}`;
        $('#lrExcel').on('click', () => {
            const t = exportTable(); const ws = XLSX.utils.aoa_to_sheet([t.head, ...t.rows]);
            const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, 'Report'); XLSX.writeFile(wb, fileBase() + '.xlsx');
        });
        $('#lrPdf').on('click', () => {
            const t = exportTable(); const { jsPDF } = window.jspdf; const doc = new jsPDF({ orientation: 'landscape', unit: 'pt', format: 'a4' });
            doc.setFontSize(13); doc.text(cfg.title, 40, 36);
            doc.setFontSize(9); doc.text(`${cfg.branchName ? 'Branch: ' + cfg.branchName + '   ' : ''}Period: ${$('#lrRange').text()}   View: ${view === 'summary' ? 'Summary by ' + groupDef().label : 'Detail'}`, 40, 52);
            doc.autoTable({ startY: 62, head: [t.head], body: t.rows.map(r => r.map(v => typeof v === 'number' ? v.toFixed(2) : String(v ?? ''))),
                            styles: { fontSize: 7, cellPadding: 3 }, headStyles: { fillColor: [15, 118, 110] } });
            doc.save(fileBase() + '.pdf');
        });
        $('#lrPrint').on('click', () => window.print());

        // ── events ──
        $('.btn-quick').on('click', function () { setRange($(this).data('range')); load(); });
        $('#lrFrom, #lrTo').on('change', () => { $('.btn-quick').removeClass('active'); load(); });
        $(document).on('change', '.lr-filter', load);
        $('#lrApply').on('click', load);
        $('#lrSearch').on('keydown', e => { if (e.key === 'Enter') load(); });
        $('#lrReset').on('click', () => { $('.lr-filter').val(''); $('#lrSearch').val(''); setRange(cfg.defaultRange || 'today'); load(); });
        $('.btn-view').on('click', function () { view = $(this).data('view'); $('.btn-view').removeClass('active'); $(this).addClass('active'); if (view === 'summary') drill = null; render(); });
        $('#lrGroup').on('change', render);
        $('#lrSummary tbody').on('click', 'tr.grp-row', function () {
            const g = groupDef(), r = groupRows()[parseInt($(this).data('i'))];
            drill = { field: g.rowField, value: g.byId ? r.GroupId : r.GroupName, label: g.label, display: g.name ? g.name(r, h) : h.esc(r.GroupName) };
            view = 'detail'; $('.btn-view').removeClass('active').filter('[data-view="detail"]').addClass('active'); render();
        });
        $(document).on('click', '#lrClearDrill', e => { e.preventDefault(); drill = null; render(); });
        window.addEventListener('pageshow', e => { if (e.persisted) { setRange(cfg.defaultRange || 'today'); load(); } });

        setRange(cfg.defaultRange || 'today');
        load();
    }

    return { init, helpers: h };
})();
