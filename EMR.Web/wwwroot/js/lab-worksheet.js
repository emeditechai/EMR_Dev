/* LAB > Work Sheet (SQLScripts/2477): filters, preview grid, print / PDF of the same filter. */
(function () {
    'use strict';
    const C = window.LabWs; if (!C) return;
    const $ = id => document.getElementById(id);
    const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const fmt = (v, withTime) => {
        if (!v) return ''; const d = new Date(v); if (isNaN(d)) return '';
        const day = d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: '2-digit' });
        return withTime ? day + ' ' + d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' }) : day;
    };
    const val = name => document.querySelector(`input[name="${name}"]:checked`)?.value;
    const query = () => new URLSearchParams({ dateType: val('wsType'), date: $('wsDate').value, channel: val('wsCh'), values: val('wsVal') }).toString();
    let loaded = false;

    async function load() {
        if (!$('wsDate').value) { $('wsRows').innerHTML = '<tr><td colspan="8" class="text-danger small p-3">Choose the date.</td></tr>'; return; }
        $('wsRows').innerHTML = '<tr><td colspan="8" class="text-muted small p-3">Loading…</td></tr>';
        let r;
        try { r = await (await fetch(C.base + 'Data?' + query(), { headers: { 'X-Requested-With': 'XMLHttpRequest' } })).json(); }
        catch { r = { success: false, error: 'The server did not answer.' }; }
        if (!r || !r.success) { $('wsRows').innerHTML = `<tr><td colspan="8" class="text-danger small p-3">${esc(r && r.error)}</td></tr>`; setButtons(false); return; }
        const d = r.data, bills = d.bills || [];
        $('wsSummary').textContent = d.subtitle + (d.tests ? ` · ${d.filled} value(s) already entered` : '');
        if (!bills.length) { $('wsRows').innerHTML = '<tr><td colspan="8" class="text-muted small p-3">No numeric tests for this filter.</td></tr>'; setButtons(false); return; }
        let html = '';
        bills.forEach((b, i) => {
            const rows = b.groups.reduce((s, g) => s + g.tests.length + (g.profileName ? 1 : 0), 0);
            const lead = `<td rowspan="${rows}" class="c b">${i + 1}</td><td rowspan="${rows}" class="sm">${esc(fmt(b.billDate, true))}</td>
                <td rowspan="${rows}"><div class="b sm">${esc(b.billNo)}</div>${b.tokenNo ? `<div class="sm">Token ${esc(b.tokenNo)}</div>` : ''}<div class="mut">${esc(b.channel)}</div></td>
                <td rowspan="${rows}"><div class="b">${esc(b.patientName)}</div><div class="sm">${esc(b.ageSex)}</div><div class="mut">${esc(b.patientCode)}</div></td>`;
            let first = true, body = '';
            b.groups.forEach(g => {
                if (g.profileName) { body += `<tr>${first ? lead : ''}<td colspan="4" class="ws-profile">${esc(g.profileName)}</td></tr>`; first = false; }
                g.tests.forEach(t => {
                    body += `<tr>${first ? lead : ''}<td class="${g.profileName ? 'ind' : ''}">${esc(t.testName)}</td><td class="sm">${esc(t.unit)}</td>
                        <td class="sm">${t.collectedAt ? esc(fmt(t.collectedAt, true)) : '—'}</td>
                        <td class="ws-val"><div class="box ${t.flag ? 'flag-' + esc(String(t.flag).charAt(0).toUpperCase()) : ''}">${esc(t.value || '')}</div></td></tr>`;
                    first = false;
                });
            });
            html += `<tbody class="ws-bill ${i % 2 ? 'alt' : ''}">${body}</tbody>`;
        });
        $('wsRows').outerHTML = `<tbody id="wsRows" class="d-none"></tbody>` + html;
        loaded = true; setButtons(true);
    }
    function setButtons(on) { ['wsPrint', 'wsPdf'].forEach(id => { if ($(id)) $(id).disabled = !on; }); }
    function reset() {   // a changed filter: the grid shows the new filter before printing
        document.querySelectorAll('.ws-grid tbody.ws-bill').forEach(t => t.remove());
        if (loaded) { $('wsRows').classList.remove('d-none'); $('wsRows').innerHTML = '<tr><td colspan="8" class="text-muted small p-3">Filter changed: click Show.</td></tr>'; $('wsSummary').textContent = ''; }
        setButtons(false);
    }
    $('wsLoad').addEventListener('click', () => { reset(); load(); });
    document.querySelectorAll('input[name="wsType"], input[name="wsCh"], input[name="wsVal"], #wsDate').forEach(el => el.addEventListener('change', reset));
    $('wsPrint')?.addEventListener('click', () => window.open(C.base + 'Print?' + query(), '_blank'));
    $('wsPdf')?.addEventListener('click', () => { window.location.href = C.base + 'Pdf?' + query(); });
    load();
})();
