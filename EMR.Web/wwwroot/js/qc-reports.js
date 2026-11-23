/* Reports > LAB > BOM & costing (SQLScripts/2248): formatting shared by the twelve pages built on lab-report.js. */
window.QcRep = (function () {
    const pct = (v, d = 1) => (v === null || v === undefined) ? '—' : Number(v).toFixed(d) + '%';
    const qty = n => (n === null || n === undefined) ? '' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: 4 });
    const unitCost = n => (n === null || n === undefined) ? '—' : '₹' + Number(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 4 });
    const money = (v, h) => (v === null || v === undefined) ? '<span class="text-muted">—</span>' : h.money(v);
    // margin colour: loss red, below 30% amber, otherwise green
    const marginCls = p => (p === null || p === undefined) ? 'text-muted' : p < 0 ? 'text-danger fw-bold' : p < 30 ? 'text-warning-emphasis fw-semibold' : 'text-success';
    const margin = (m, p, h) => (m === null || m === undefined) ? '<span class="text-muted">—</span>' : `<span class="${marginCls(p)}">${h.money(m)}</span>`;
    const marginPct = p => `<span class="${marginCls(p)}">${pct(p)}</span>`;
    const kindCls = { Test: 'bg-light text-dark border', Profile: 'bg-info-subtle text-info-emphasis border-info-subtle', Package: 'bg-primary-subtle text-primary border-primary-subtle' };
    const kind = (k, h) => h.pill(k, kindCls[k] || 'bg-light text-dark border');
    const name = (n, code, h, extra) => `<div class="fw-semibold">${h.esc(n)}</div>` + (code ? `<div class="text-muted fs-9 font-monospace">${h.esc(code)}</div>` : '') + (extra || '');
    const pill = (text, tone, h) => h.pill(h.esc(text), {
        good: 'bg-success-subtle text-success border-success-subtle', warn: 'bg-warning-subtle text-warning-emphasis border-warning-subtle',
        bad: 'bg-danger-subtle text-danger border-danger-subtle', info: 'bg-info-subtle text-info-emphasis border-info-subtle', muted: 'bg-light text-muted border'
    }[tone] || 'bg-light text-dark border');

    /** a sub-table of lines under an opened row: cols = [{ label, cls, html: line => html }] */
    function lines(rows, cols, foot) {
        if (!rows.length) return '<div class="text-muted fs-8 py-1">No lines.</div>';
        return `<table class="lr-sub"><thead><tr>${cols.map(c => `<th class="${c.cls || ''}">${c.label}</th>`).join('')}</tr></thead>
            <tbody>${rows.map(l => `<tr>${cols.map(c => `<td class="${c.cls || ''}">${c.html(l)}</td>`).join('')}</tr>`).join('')}</tbody>
            ${foot ? `<tfoot><tr>${foot}</tr></tfoot>` : ''}</table>`;
    }

    return { pct, qty, unitCost, money, margin, marginPct, kind, name, pill, lines };
})();
