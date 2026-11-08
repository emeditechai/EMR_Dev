/* IpdEstimation/Patient.cshtml (IPD, SQLScripts/2422+): page script, moved out of the view so it is not compiled into EMR.Web.dll. Server values come in window.IpdPage. */
(function () {
const C = window.IpdPage || {};
const id = C.id, base = C.base, E = Ipd.esc;
const expected = C.expected;
if (expected) projectTo.value = Ipd.local(expected);
let lines = [];
const tile = (l, v, s, c) => `<div class="col-6 col-lg-3"><div class="ipd-tile ${c}"><div class="lbl">${l}</div><div class="val">${v}</div><div class="sub">${s || ''}</div></div></div>`;
document.querySelectorAll('#printMenu [data-format]').forEach(a => a.addEventListener('click', () => {
    a.href = base + 'Print/' + id + '?format=' + a.dataset.format + (projectTo.value ? '&projectTo=' + encodeURIComponent(projectTo.value) : '');
}));
async function loadLive() {
    try {
        const d = await Ipd.get(base + 'LiveData?id=' + id + (projectTo.value ? '&projectTo=' + encodeURIComponent(projectTo.value) : ''));
        const t = (d.totals || [])[0] || {}, hd = (d.header || [])[0] || {};
        asOf.textContent = 'Live as of ' + Ipd.dt(hd.AsOf || new Date());
        warn.innerHTML = (t.NoTariff ? '<div class="alert alert-warning py-2 small"><i class="bi bi-exclamation-triangle-fill me-1"></i>A bed day has no rate for this tariff category: set it in Master &gt; IPD &gt; Bed/Room Tariff (it shows as ₹0 now).</div>' : '')
            + (t.UsedFallback ? '<div class="alert alert-info py-2 small">Some bed days use the default tariff category\'s rate (Hospital Settings &gt; IPD), as the patient\'s category has none.</div>' : '');
        tiles.innerHTML = tile('Bill if discharged now', Ipd.money(t.BillNow), (t.BedDays || 0) + ' bed day(s)', 'accent') + tile('Advance held', Ipd.money(t.NetAdvance), 'received ' + Ipd.money(t.AdvanceTotal) + ' · refunded ' + Ipd.money(t.RefundTotal), 'good')
            + tile(t.RefundDue > 0 ? 'Refundable' : 'Balance due', Ipd.money(t.RefundDue > 0 ? t.RefundDue : t.BalanceDue), t.DepositAlert ? '<span class="text-danger fw-semibold"><i class="bi bi-bell-fill"></i> Collect deposit</span>' : '', t.DepositAlert || t.BalanceDue > 0 ? 'bad' : 'good')
            + tile('Estimated till discharge', t.ProjectedTotal == null ? '—' : Ipd.money(t.ProjectedTotal), t.ProjectedTotal == null ? 'set the expected discharge' : (t.ProjectedDays || 0) + ' bed day(s) · balance ' + Ipd.money(t.ProjectedBalance), 'warn');
        const hs = d.heads || [];
        heads.innerHTML = hs.map(x => `<tr style="cursor:pointer" data-head="${E(x.Head)}" class="${Number(x.Lines) ? '' : 'text-muted'}"><td class="fw-semibold">${E(x.HeadName)}</td><td class="text-end">${x.Lines}</td>
            <td class="text-end num">${Ipd.num(x.Gross)}</td><td class="text-end num">${Ipd.num(x.Discount)}</td><td class="text-end num">${Ipd.num(x.Gst)}</td><td class="text-end num fw-semibold">${Ipd.num(x.Net)}</td>
            <td class="text-end num">${Ipd.num(x.PatientShare)}</td><td class="text-end num">${Ipd.num(x.PayerShare)}</td></tr>`).join('');
        headsFoot.innerHTML = `<tr class="fw-bold"><td>Total</td><td></td><td class="text-end num">${Ipd.num(t.Gross)}</td><td class="text-end num">${Ipd.num(t.Discount)}</td><td class="text-end num">${Ipd.num(t.Gst)}</td><td class="text-end num">${Ipd.num(t.BillNow)}</td><td class="text-end num">${Ipd.num(t.PatientShare)}</td><td class="text-end num">${Ipd.num(t.PayerShare)}</td></tr>`;
        const fh = document.getElementById('fHead'); if (fh.options.length === 1) hs.forEach(x => fh.append(new Option(x.HeadName, x.Head)));
        totals.innerHTML = `<dt>Gross</dt><dd class="num">${Ipd.money(t.Gross)}</dd><dt>Discount</dt><dd class="num">${Ipd.money(t.Discount)}</dd><dt>GST</dt><dd class="num">${Ipd.money(t.Gst)}</dd>
            <dt class="fw-bold">Bill if discharged now</dt><dd class="num fw-bold">${Ipd.money(t.BillNow)}</dd><dt>Advance received</dt><dd class="num">${Ipd.money(t.AdvanceTotal)}</dd><dt>Refunded</dt><dd class="num">${Ipd.money(t.RefundTotal)}</dd>
            <dt>TPA / corporate approved</dt><dd class="num">${Ipd.money(t.ApprovedAmount)} <span class="small text-muted">(Phase 6)</span></dd><dt>Patient share</dt><dd class="num">${Ipd.money(t.PatientShare)}</dd>
            <dt class="fw-bold">${t.RefundDue > 0 ? 'Refundable now' : 'Balance due now'}</dt><dd class="num fw-bold ${t.BalanceDue > 0 ? 'money-due' : 'money-ok'}">${Ipd.money(t.RefundDue > 0 ? t.RefundDue : t.BalanceDue)}</dd>
            <dt>Deposit alert</dt><dd>${t.DepositAlert ? '<span class="ipd-pill alert">Collect deposit</span>' : '<span class="ipd-pill muted">No</span>'} <span class="small text-muted">at ${t.DepositAlertPercent}% of advance</span></dd>`;
        projection.innerHTML = t.ProjectedTotal == null ? '<dt>Expected discharge</dt><dd class="text-muted">Not set</dd>'
            : `<dt>Bill at discharge</dt><dd class="num fw-bold">${Ipd.money(t.ProjectedTotal)}</dd><dt>Bed days then</dt><dd>${t.ProjectedDays}</dd><dt>More than now</dt><dd class="num">${Ipd.money(t.ProjectedExtra)}</dd>
               <dt>Balance then</dt><dd class="num ${t.ProjectedBalance > 0 ? 'money-due' : 'money-ok'}">${Ipd.money(t.ProjectedBalance)}</dd>`;
        const o = d.ordered || [];
        ordered.innerHTML = o.length ? o.map(x => `<div class="d-flex justify-content-between small"><span>${E(x.ItemName)}</span><span class="num">${Ipd.money(x.EstimatedAmount)}</span></div>`).join('')
            : '<div class="small text-muted">Nothing pending. LAB orders, pharmacy indents and OT bookings appear here as those phases arrive.</div>';
    } catch (e) { warn.innerHTML = `<div class="alert alert-danger">${E(e.message)}</div>`; }
}
async function loadLines() {
    const q = new URLSearchParams({ id, head: fHead.value, status: fStatus.value, fromDate: fFrom.value, toDate: fTo.value, search: fSearch.value.trim() });
    try { lines = await Ipd.get(base + 'LinesData?' + q) || []; renderLines(); } catch (e) { document.getElementById('lines').innerHTML = `<tr><td colspan="10" class="text-danger">${E(e.message)}</td></tr>`; }
}
function renderLines() {
    const byDate = grpDate.checked, groups = {};
    lines.forEach(l => { const k = byDate ? Ipd.date(l.ChargeAt) : l.HeadName; (groups[k] = groups[k] || { sort: byDate ? l.ChargeAt : l.HeadSort, rows: [] }).rows.push(l); });
    const keys = Object.keys(groups).sort((a, b) => groups[a].sort > groups[b].sort ? 1 : -1);
    document.getElementById('lines').innerHTML = keys.map(k => {
        const g = groups[k], sum = g.rows.reduce((s, r) => s + Number(r.Net), 0);
        return `<tr class="table-light"><td colspan="8" class="fw-bold">${E(k)}</td><td class="text-end fw-bold num">${Ipd.money(sum)}</td><td></td></tr>` + g.rows.map(l =>
            `<tr class="${l.NoTariff ? 'table-warning' : ''}"><td class="text-nowrap">${Ipd.date(l.ChargeAt)}</td><td>${E(l.ItemName)}${l.IsPackageItem ? ' <span class="ipd-pill info">package</span>' : ''}</td><td class="small text-muted">${E(l.Detail || '')}</td>
            <td>${E(l.DoctorName || '')}</td><td class="text-end num">${Number(l.Qty)}</td><td class="text-end num">${Ipd.num(l.Rate)}</td><td class="text-end num">${Ipd.num(l.Discount)}</td>
            <td class="text-end num">${Number(l.GstPercent) ? Ipd.num(l.GstAmount) + ' <span class="small text-muted">(' + Number(l.GstPercent) + '%)</span>' : ''}</td><td class="text-end num fw-semibold">${Ipd.num(l.Net)}</td>
            <td><span class="ipd-pill ${l.Status === 'POSTED' ? 'info' : 'muted'}">${l.Status === 'POSTED' ? 'Posted' : 'Accrued'}</span></td></tr>`).join('');
    }).join('') || '<tr><td colspan="10" class="text-center text-muted py-4">No line.</td></tr>';
}
heads.addEventListener('click', e => { const tr = e.target.closest('tr[data-head]'); if (!tr) return; fHead.value = tr.dataset.head; loadLines(); document.getElementById('detailCard').scrollIntoView({ behavior: 'smooth' }); });
[fHead, fStatus, fFrom, fTo].forEach(el => el.addEventListener('change', loadLines));
let t; fSearch.addEventListener('input', () => { clearTimeout(t); t = setTimeout(loadLines, 300); });
[grpHead, grpDate].forEach(el => el.addEventListener('change', renderLines));
btnProject.addEventListener('click', loadLive);
const all = () => { loadLive(); loadLines(); };
refresh.addEventListener('click', all);
all();
if (C.open) setInterval(all, 60000);
})();
