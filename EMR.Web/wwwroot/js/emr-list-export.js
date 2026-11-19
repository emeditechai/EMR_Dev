/* Excel / CSV / PDF download of a list page's table, as it is filtered on the screen (every page of it, not only
 * the rows shown). Needs emr-export-libs.js (loads SheetJS / jsPDF only when a download is asked for).
 *
 *   EmrListExport.bind({ table: '#tblRateCards', title: 'Rate List - B2C', file: 'RateList_B2C' });
 *
 * Buttons: any element with data-list-export="excel" | "csv" | "pdf" (the page shows them by permission).
 * Columns: every header except an empty one, "Action(s)", or a <th data-export="false">.
 * Rows: a DataTables table gives its rows after the search / order in use; a plain table gives every body row
 * (also those hidden by client-side paging), except a "no records" row (a single cell spanning the table).
 */
window.EmrListExport = (function () {
    const clean = s => String(s ?? '').replace(/\s+/g, ' ').trim();

    // the text of a cell: badges and lines kept apart by a space; hidden bits, buttons and forms left out
    function cellText(node) {
        const el = node.cloneNode(true);
        el.querySelectorAll('.d-none, .visually-hidden, script, style, button, form, .modal, input, select, textarea').forEach(e => e.remove());
        el.querySelectorAll('*').forEach(e => e.append(' '));
        return clean(el.textContent);
    }
    const htmlText = html => { const d = document.createElement('div'); d.innerHTML = html ?? ''; return cellText(d); };

    function read(tableSel) {
        const table = document.querySelector(tableSel);
        if (!table) throw new Error('The list was not found on the page.');
        const ths = Array.from(table.tHead ? table.tHead.rows[table.tHead.rows.length - 1].cells : []);
        const cols = ths.map((th, i) => ({ i, name: clean(th.textContent) }))
            .filter(c => c.name && !/^actions?$/i.test(c.name) && ths[c.i].dataset.export !== 'false');
        const head = cols.map(c => c.name);
        let body = [];
        if (window.jQuery && jQuery.fn.dataTable && jQuery.fn.dataTable.isDataTable(table)) {
            const dt = jQuery(table).DataTable();
            dt.rows({ search: 'applied', order: 'applied' }).indexes().each(r => {
                body.push(cols.map(c => {
                    const v = dt.cell(r, c.i).render('display');
                    return typeof v === 'string' ? htmlText(v) : clean(v);
                }));
            });
        } else {
            Array.from(table.tBodies[0] ? table.tBodies[0].rows : []).forEach(tr => {
                if (tr.cells.length === 1 && tr.cells[0].colSpan > 1) return;   // "no records" row
                body.push(cols.map(c => tr.cells[c.i] ? cellText(tr.cells[c.i]) : ''));
            });
        }
        return { head, body };
    }

    const stamp = () => { const d = new Date(), p = n => String(n).padStart(2, '0'); return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}`; };
    const printedOn = () => new Date().toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });

    function save(blob, name) {
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob); a.download = name;
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    }

    // a number in a cell ("1,250.00", "₹ 400") is written as a number to Excel; codes / phone numbers stay text
    const asNumber = (head, v) => {
        if (!/^[-₹\s]*[\d,]+(\.\d+)?$/.test(v) || /code|phone|mobile|no\.?$|gst|pin/i.test(head)) return v;
        const n = Number(v.replace(/[₹,\s]/g, ''));
        return Number.isFinite(n) ? n : v;
    };

    function excel(o, d) {
        const rows = d.body.map(r => r.map((v, i) => asNumber(d.head[i], v)));
        const ws = XLSX.utils.aoa_to_sheet([d.head, ...rows]);
        ws['!cols'] = d.head.map((h, i) => ({ wch: Math.min(60, Math.max(h.length, ...d.body.map(r => (r[i] || '').length)) + 2) }));
        const wb = XLSX.utils.book_new();
        XLSX.utils.book_append_sheet(wb, ws, (o.sheet || o.title).replace(/[\\/?*[\]:]/g, ' ').slice(0, 31));
        XLSX.writeFile(wb, `${o.file}_${stamp()}.xlsx`);
    }

    function csv(o, d) {
        const q = v => /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
        const text = [d.head, ...d.body].map(r => r.map(v => q(String(v ?? ''))).join(',')).join('\r\n');
        save(new Blob(['﻿' + text], { type: 'text/csv;charset=utf-8' }), `${o.file}_${stamp()}.csv`);   // BOM: Excel reads ₹ correctly
    }

    function pdf(o, d) {
        const { jsPDF } = window.jspdf;
        const doc = new jsPDF({ orientation: d.head.length > 5 ? 'landscape' : 'portrait', unit: 'pt', format: 'a4' });
        const rs = v => String(v ?? '').replace(/₹/g, 'Rs.');   // the PDF's built-in font has no rupee sign
        doc.setFontSize(13); doc.text(o.title, 40, 36);
        doc.setFontSize(8); doc.setTextColor(100);
        doc.text(`${d.body.length} record(s) - printed on ${printedOn()}`, 40, 50);
        doc.autoTable({
            head: [d.head.map(rs)], body: d.body.map(r => r.map(rs)), startY: 60,
            styles: { fontSize: 7.5, cellPadding: 3, overflow: 'linebreak' },
            headStyles: { fillColor: [30, 64, 175], textColor: 255 },
            margin: { left: 40, right: 40 },
            didDrawPage: () => {
                const h = doc.internal.pageSize.getHeight(), w = doc.internal.pageSize.getWidth();
                doc.setFontSize(7); doc.setTextColor(120);
                doc.text(`Page ${doc.internal.getNumberOfPages()}`, w - 40, h - 20, { align: 'right' });
            }
        });
        doc.save(`${o.file}_${stamp()}.pdf`);
    }

    function bind(o) {
        document.querySelectorAll('[data-list-export]').forEach(btn => btn.addEventListener('click', () => {
            const kind = btn.dataset.listExport;
            let d;
            try { d = read(o.table); } catch (e) { return Swal.fire({ icon: 'error', text: e.message }); }
            if (!d.body.length) return Swal.fire({ icon: 'info', text: 'There is nothing in the list to download.' });
            if (kind === 'csv') return csv(o, d);
            EmrExportLibs.run(btn, kind === 'pdf' ? 'pdf' : 'excel', () => (kind === 'pdf' ? pdf : excel)(o, d));
        }));
    }

    return { bind };
})();
