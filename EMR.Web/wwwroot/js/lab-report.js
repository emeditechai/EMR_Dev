/*
 * Reports > LAB registers: one script for every page built on Views/Reports/_LabReportShell.cshtml.
 * A page calls LabReport.init(config); the server returns { success, scope, data: { summary, groups, rows, options } }
 * (see SQLScripts/2124). Visibility (branch / Administrator / own data) is decided on the server, never here.
 *
 * config = {
 *   report, dataUrl, title, defaultRange ('today' | 'month' ...), seeAll, branchName, searchPlaceholder,
 *   filters:   [{ id, label, options: [[value, text]], fromOptions: 'createdBy', allLabel, adminOnly }],
 *   kpis:      [{ label, color, value: (s, h) => html, sub: (s, h) => html }],
 *   groups:    [{ key, label, rowField, byId, name: (group, h) => html, adminOnly, noDrill }],   noDrill: its lines don't open the Detail
 *   groupCols: [{ field, label, money, total: 'sum' | 'max' | 'none', fmt: (v, h) => html }],
 *   shareOf:   field used for the "share" bar in Summary,
 *   cols:      [{ label, cls, html: (row, h) => html, text: (row, h) => export value, sum: field, money }],
 *   rowClass:  row => css class,
 *   afterLoad: (data, h) => void   optional: draws the page's own panel (#lrExtra) after each load
 *   params:    () => ({ key: value })   optional: extra query values sent with every load (e.g. a page tab)
 *   startView: 'detail'   optional: the page opens on the Detail view instead of the Summary
 *   noDates:   true   optional: a snapshot "as on today" (master data); the date filters are hidden
 *   cols[].when / groups[].when: () => bool   optional: the column / group is shown only while it returns true
 *   expand:    { has: (row, data) => bool, html: (row, data, h) => html }   optional: rows open to show their lines
 *   exportExtra: (rows, data, h) => ({ sheet, title, head, rows })   optional: an extra Excel sheet / PDF page (Detail view)
 *   expandOpen: true   optional: with expand, every row starts open (its lines shown) after each load
 *   exportGrouped: (rows, data, h) => ({ head, left, sections: [{ title, bills: [{ cells, lines: [[...]], total: { label, values } }],
 *                  subtotal: { label, values } }], grand: { label, values }, valueAt, right })   optional: Detail exports as a grouped register -
 *                section header rows, each bill's first `left` columns spanning its line rows, bill totals, subtotals and a
 *                grand total (values = the numeric columns at the end, or from column `valueAt`; `right` bill cells
 *                given as b.after follow the line cells and span them too). Used instead of the plain Detail table.
 *   exportLines: (row, data, h) => [[...cells]]   optional: Detail exports write these line rows right under each row
 *                (one array per line, same columns as the export); PDF shows them indented and lighter
 * }
 * init returns { reload } so a page can reload after changing what params() returns.
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
        let data = null, view = cfg.startView === 'detail' ? 'detail' : 'summary', drill = null, seq = 0;
        if (view === 'detail') $('.btn-view').removeClass('active').filter('[data-view="detail"]').addClass('active');
        const allGroups = cfg.groups.filter(g => !g.adminOnly || cfg.seeAll);
        let groups = allGroups.filter(g => !g.when || g.when());
        const cols = () => cfg.cols.filter(c => !c.when || c.when());
        const open = new Set();   // expanded rows (expand option)
        let autoOpen = false;     // expandOpen option: every row starts open after each load (Collapse All still works)
        const filters = (cfg.filters || []).filter(f => !f.adminOnly || cfg.seeAll);

        // report-specific filters, before the search box
        filters.forEach(f => {
            const opts = (f.options || []).map(o => `<option value="${h.esc(o[0])}">${h.esc(o[1])}</option>`).join('');
            $(`<div class="col-6 col-md-2"><label class="form-label fs-9 fw-bold text-muted text-uppercase mb-0" for="lrF_${f.id}">${h.esc(f.label)}</label>
                 <select id="lrF_${f.id}" class="form-select form-select-sm lr-filter" data-id="${f.id}" autocomplete="off"><option value="">${h.esc(f.allLabel || 'All')}</option>${opts}</select></div>`)
                .insertBefore('#lrSearchCol');
        });
        $('#lrSearch').attr('placeholder', cfg.searchPlaceholder || 'Search...');
        if (cfg.noDates) $('#lrFrom, #lrTo, .btn-quick').closest('#lrFilterRow > div').addClass('d-none');
        function buildChrome() {
            const keep = $('#lrGroup').val();
            groups = allGroups.filter(g => !g.when || g.when());
            $('#lrGroup').html(groups.map(g => `<option value="${g.key}">${h.esc(g.label)}</option>`).join(''));
            if (keep && groups.some(g => g.key === keep)) $('#lrGroup').val(keep);
            $('#lrDetail thead').html('<tr><th class="ps-3">#</th>' + cols().map(c => `<th class="${c.cls || ''}">${h.esc(c.label)}</th>`).join('') + '</tr>');
        }
        buildChrome();

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
            if (cfg.params) Object.assign(q, cfg.params() || {});
            buildChrome(); open.clear(); autoOpen = !!cfg.expandOpen;
            $('#lrError').addClass('d-none'); $('#lrEmpty').addClass('d-none');
            // shimmer placeholders in the three zones: widgets, graphs (pages that draw one), list
            $('#lrKpis').html(EmrShimmer.kpiCards(cfg.kpis.length));
            if (cfg.afterLoad) $('#lrExtra').html(EmrShimmer.chartBlock(220));
            $('#lrLoading').html(EmrShimmer.listBlock(8, 6)).removeClass('d-none');
            $('#lrSummary tbody, #lrDetail tbody, #lrSummary tfoot, #lrDetail tfoot').empty();
            $('#lrExcel, #lrPdf, #lrPrint').prop('disabled', true);
            $('#lrRange').text(cfg.noDates ? 'As on ' + h.fmtD(iso(new Date())) : h.fmtD(from) + (from === to ? '' : ' – ' + h.fmtD(to)));
            $.get(cfg.dataUrl, q).done(res => {
                if (my !== seq) return;
                if (!res || !res.success) { clearShimmer(); $('#lrError').text(res?.message || 'Unable to load the report.').removeClass('d-none'); return; }
                data = res.data || {}; drill = null;
                // one paint each, in reading order: widgets, then the graphs, then the list
                EmrShimmer.stage([
                    () => { fillOptions(); renderKpis(); },
                    () => { if (cfg.afterLoad) cfg.afterLoad(data, h); },
                    () => { $('#lrLoading').addClass('d-none').empty(); render(); }
                ], () => my === seq);
            }).fail(() => {
                if (my !== seq) return;
                clearShimmer();
                $('#lrError').text('Server error while loading the report. Please try again.').removeClass('d-none');
            });
        }

        function clearShimmer() { $('#lrKpis, #lrExtra').empty(); $('#lrLoading').addClass('d-none').empty(); }

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
            $('#lrCount').text(`${rows.length} group(s)${groupDef().noDrill ? '' : ' · click a line to see its records'}`);
        }

        function renderDetail() {
            const rows = detailRows();
            if (!rows.length) {
                $('#lrDetail tbody').html(`<tr><td colspan="${cols().length + 1}" class="text-center text-muted py-4">No records in this group for the selected period.</td></tr>`);
                $('#lrDetail tfoot').empty(); $('#lrCount').text('0 record(s)');
                return;
            }
            const cc = cols(), ex = cfg.expand;
            if (autoOpen && ex) { rows.forEach((r, i) => { if (ex.has(r, data)) open.add(i); }); autoOpen = false; }
            $('#lrDetail tbody').html(rows.map((r, i) => {
                const can = ex && ex.has(r, data), isOpen = can && open.has(i);
                return `<tr class="${cfg.rowClass ? cfg.rowClass(r) : ''} ${can ? 'lr-has-lines' : ''} ${isOpen ? 'lr-open' : ''}" data-i="${i}">
                    <td class="ps-3 text-muted text-nowrap">${can ? '<button type="button" class="lr-tog" title="Show the lines" aria-label="Show the lines"><i class="bi bi-chevron-right"></i></button>' : ''}${i + 1}</td>` +
                    cc.map(c => `<td class="${c.cls || ''}">${c.html(r, h)}</td>`).join('') + '</tr>' +
                    (can ? `<tr class="lr-lines ${isOpen ? '' : 'd-none'}" data-for="${i}"><td colspan="${cc.length + 1}">${ex.html(r, data, h)}</td></tr>` : '');
            }).join(''));
            $('#lrExpandBox').toggleClass('d-none', !(ex && rows.some(r => ex.has(r, data))));
            const hasSums = cc.some(c => c.sum);
            $('#lrDetail tfoot').html(hasSums ? '<tr><td class="ps-3"></td>' + cc.map((c, i) => {
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
            const ec = cols().filter(c => !c.noExport);   // buttons / links are left out of exports
            const lineRows = [];   // indexes of line rows (exportLines), styled lighter in the PDF
            const rows = [];
            detailRows().forEach(r => {
                rows.push(ec.map(c => c.text ? c.text(r, h) : $('<div>').html(c.html(r, h)).text().trim()));
                if (cfg.exportLines) (cfg.exportLines(r, data, h) || []).forEach(l => { lineRows.push(rows.length); rows.push(l); });
            });
            return { head: ec.map(c => c.label), rows, lineRows };
        }
        // ── grouped register export (exportGrouped) ──
        function groupedModel() {
            if (view !== 'detail' || !cfg.exportGrouped) return null;
            const g = cfg.exportGrouped(detailRows(), data, h);
            const n = g.head.length, nv = (g.grand?.values || []).length;   // numeric columns (at the end, or from valueAt)
            const right = g.right || 0, va = g.valueAt ?? n - nv;           // right: bill cells after the line cells (b.after)
            const out = [];   // { kind: 'section'|'line'|'total'|'subtotal'|'grand', cells, first, span }
            const totalRow = (kind, t) => ({ kind, cells: [t.label, ...t.values] });
            g.sections.forEach(s => {
                out.push({ kind: 'section', cells: [s.title] });
                s.bills.forEach(b => {
                    const after = b.after || [];
                    b.lines.forEach((l, i) => out.push({ kind: 'line', first: i === 0, span: b.lines.length,
                        cells: i === 0 ? [...b.cells, ...l, ...after] : [...b.cells.map(() => ''), ...l, ...after.map(() => '')] }));
                    if (b.total) out.push(totalRow('total', b.total));
                });
                if (s.subtotal) out.push(totalRow('subtotal', s.subtotal));
            });
            if (g.grand) out.push(totalRow('grand', g.grand));
            return { head: g.head, n, nv, va, right, left: g.left, out };
        }
        function groupedSheet(m) {
            const aoa = [m.head], merges = [];
            m.out.forEach(r => {
                const ri = aoa.length;
                if (r.kind === 'section') { aoa.push([r.cells[0], ...Array(m.n - 1).fill('')]); merges.push({ s: { r: ri, c: 0 }, e: { r: ri, c: m.n - 1 } }); }
                else if (r.kind === 'line') {
                    aoa.push(r.cells);
                    if (r.first && r.span > 1) for (let c = 0; c < m.n; c++) if (c < m.left || c >= m.n - m.right) merges.push({ s: { r: ri, c }, e: { r: ri + r.span - 1, c } });
                } else {
                    aoa.push([...Array(m.va - 1).fill(''), r.cells[0], ...r.cells.slice(1), ...Array(m.n - m.va - m.nv).fill('')]);
                }
            });
            const ws = XLSX.utils.aoa_to_sheet(aoa); ws['!merges'] = merges;
            ws['!cols'] = m.head.map((x, i) => ({ wch: i === 0 ? 5 : i >= m.va && i < m.va + m.nv ? 13 : 28 }));
            return ws;
        }
        function groupedPdfBody(m) {
            // the PDF's built-in font has no rupee sign
            const money = v => typeof v === 'number' ? v.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : String(v ?? '').replace(/₹/g, 'Rs.');
            const num = { halign: 'right' };
            return m.out.map(r => {
                if (r.kind === 'section') return [{ content: r.cells[0], colSpan: m.n, styles: { fillColor: [241, 245, 249], fontStyle: 'bold', textColor: [15, 23, 42] } }];
                if (r.kind === 'line') {
                    const cells = r.cells.map((v, c) => ({ content: money(v), styles: c >= m.va && c < m.va + m.nv ? num : {} }));
                    if (r.first) { cells.forEach((x, c) => { if (c < m.left || c >= m.n - m.right) x.rowSpan = r.span; }); return cells; }
                    return cells.slice(m.left, m.n - m.right);   // the spanning cells of the bill cover these rows
                }
                const style = r.kind === 'grand' ? { fontStyle: 'bold', fillColor: [226, 232, 240] } : r.kind === 'subtotal' ? { fontStyle: 'bold' } : { textColor: [71, 85, 105], fillColor: [248, 250, 252] };
                const tail = m.n - m.va - m.nv;
                return [{ content: r.cells[0], colSpan: m.va, styles: { ...style, halign: 'right' } },
                        ...r.cells.slice(1).map(v => ({ content: money(v), styles: { ...style, halign: 'right' } })),
                        ...(tail > 0 ? [{ content: '', colSpan: tail, styles: style }] : [])];
            });
        }
        const fileBase = () => `${cfg.title.replace(/[^A-Za-z0-9]+/g, '_')}_${view}_` + (cfg.noDates ? iso(new Date()) : `${$('#lrFrom').val()}_to_${$('#lrTo').val()}`);
        // the export libraries are fetched on the first Excel / PDF click, not with the page
        $('#lrExcel').on('click', function () { EmrExportLibs.run(this, 'excel', () => {
            const gm = groupedModel();
            const t = gm ? null : exportTable(); const ws = gm ? groupedSheet(gm) : XLSX.utils.aoa_to_sheet([t.head, ...t.rows]);
            const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, 'Report');
            const extra = view === 'detail' && cfg.exportExtra ? cfg.exportExtra(detailRows(), data, h) : null;
            if (extra && extra.rows.length) XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([extra.head, ...extra.rows]), extra.sheet || 'Lines');
            XLSX.writeFile(wb, fileBase() + '.xlsx');
        }); });
        $('#lrPdf').on('click', function () { EmrExportLibs.run(this, 'pdf', () => {
            const gm = groupedModel();
            const t = gm ? { head: gm.head, rows: [] } : exportTable(); const { jsPDF } = window.jspdf; const doc = new jsPDF({ orientation: 'landscape', unit: 'pt', format: 'a4' });
            doc.setFontSize(13); doc.text(cfg.title, 40, 36);
            doc.setFontSize(9); doc.text(`${cfg.branchName ? 'Branch: ' + cfg.branchName + '   ' : ''}${cfg.noDates ? '' : 'Period: '}${$('#lrRange').text()}   View: ${view === 'summary' ? 'Summary by ' + groupDef().label : 'Detail'}`, 40, 52);
            const lines = new Set(t.lineRows || []), hasLines = lines.size > 0;
            if (gm) doc.autoTable({ startY: 62, head: [gm.head.map((x, i) => ({ content: String(x).replace(/₹/g, 'Rs.'), styles: i >= gm.va && i < gm.va + gm.nv ? { halign: 'right' } : {} }))], body: groupedPdfBody(gm),
                                    theme: 'grid', styles: { fontSize: 7.5, cellPadding: 4, valign: 'top', lineColor: [226, 232, 240], lineWidth: 0.5 },
                                    headStyles: { fillColor: [36, 59, 97], textColor: 255, fontStyle: 'bold' } });
            else doc.autoTable({ startY: 62, head: [t.head], body: t.rows.map(r => r.map(v => typeof v === 'number' ? v.toFixed(2) : String(v ?? ''))),
                            styles: { fontSize: 7, cellPadding: 3 }, headStyles: { fillColor: [15, 118, 110] },
                            didParseCell: d => {
                                if (d.section !== 'body' || !hasLines) return;
                                if (lines.has(d.row.index)) { d.cell.styles.fillColor = [255, 255, 255]; d.cell.styles.textColor = [71, 85, 105]; d.cell.styles.fontSize = 6.5; }
                                else { d.cell.styles.fontStyle = 'bold'; d.cell.styles.fillColor = [236, 244, 243]; }
                            } });
            const extra = view === 'detail' && cfg.exportExtra ? cfg.exportExtra(detailRows(), data, h) : null;
            if (extra && extra.rows.length) {
                doc.addPage(); doc.setFontSize(12); doc.text(extra.title || extra.sheet || 'Lines', 40, 36);
                doc.autoTable({ startY: 46, head: [extra.head], body: extra.rows.map(r => r.map(v => typeof v === 'number' ? v.toFixed(2) : String(v ?? ''))),
                                styles: { fontSize: 7, cellPadding: 3 }, headStyles: { fillColor: [15, 118, 110] } });
            }
            doc.save(fileBase() + '.pdf');
        }); });
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
            if (g.noDrill) return;
            drill = { field: g.rowField, value: g.byId ? r.GroupId : r.GroupName, label: g.label, display: g.name ? g.name(r, h) : h.esc(r.GroupName) };
            view = 'detail'; $('.btn-view').removeClass('active').filter('[data-view="detail"]').addClass('active'); render();
        });
        $(document).on('click', '#lrClearDrill', e => { e.preventDefault(); drill = null; render(); });
        function toggleRow(i, show) {
            const on = show ?? !open.has(i);
            if (on) open.add(i); else open.delete(i);
            $(`#lrDetail tr.lr-has-lines[data-i="${i}"]`).toggleClass('lr-open', on);
            $(`#lrDetail tr.lr-lines[data-for="${i}"]`).toggleClass('d-none', !on);
        }
        $('#lrDetail').on('click', 'tr.lr-has-lines', function (e) {
            if ($(e.target).closest('a').length) return;   // links in the row keep working
            toggleRow(parseInt($(this).data('i')));
        });
        $(document).on('click', '#lrExpandAll', () => $('#lrDetail tr.lr-has-lines').each(function () { toggleRow(parseInt($(this).data('i')), true); }));
        $(document).on('click', '#lrCollapseAll', () => $('#lrDetail tr.lr-has-lines').each(function () { toggleRow(parseInt($(this).data('i')), false); }));
        window.addEventListener('pageshow', e => { if (e.persisted) { setRange(cfg.defaultRange || 'today'); load(); } });

        setRange(cfg.defaultRange || 'today');
        load();
        return { reload: load };
    }

    return { init, helpers: h };
})();
