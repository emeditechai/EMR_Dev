// Reports > LAB > Marketing Executive Business. Data: GetLabReportData?report=marketing-business (SQLScripts/2443; targets 2447).
(function () {
    'use strict';
    const P = window.MbPage || {}, $ = id => document.getElementById(id);
    const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const n = v => Number(v || 0), money = v => '₹' + n(v).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const int = v => n(v).toLocaleString('en-IN'), iso = d => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    const fmtDate = v => v ? new Date(v).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '';
    const typeColor = { OPD: '#2563eb', LAB: '#7c3aed', IPD: '#0891b2', MED: '#16a34a' };
    const pill = t => t ? `<span class="mb-pill" style="background:${typeColor[t] || '#64748b'}1a;color:${typeColor[t] || '#64748b'}">${esc(t)}</span>` : '';
    let data = null, optionsLoaded = false;
    const FREQ = { MONTHLY: 'Monthly', QUARTERLY: 'Quarterly', HALFYEARLY: 'Half-yearly', YEARLY: 'Yearly' };   // 2447

    function setRange(kind) {
        const t = new Date(); let f = new Date(t), to = new Date(t);
        if (kind === 'month') f = new Date(t.getFullYear(), t.getMonth(), 1);
        else if (kind === 'last') { f = new Date(t.getFullYear(), t.getMonth() - 1, 1); to = new Date(t.getFullYear(), t.getMonth(), 0); }
        else if (kind === 'quarter') f = new Date(t.getFullYear(), t.getMonth() - 2, 1);
        $('mbFrom').value = iso(f); $('mbTo').value = iso(to);
    }

    async function load() {
        const q = new URLSearchParams({ report: 'marketing-business', fromDate: $('mbFrom').value, toDate: $('mbTo').value,
            search: $('mbSearch').value.trim(), executiveIds: $('mbExec').value, billingType: $('mbBilling').value });
        ['tblExec', 'tblBill'].forEach(id => $(id).innerHTML = '<tbody><tr><td class="text-center text-muted py-4">Loading…</td></tr></tbody>');
        $('docWrap').innerHTML = '<div class="text-center text-muted py-4">Loading…</div>';
        try {
            const r = await fetch(P.dataUrl + '?' + q, { headers: { 'X-Requested-With': 'XMLHttpRequest' } });
            const j = await r.json();
            if (!j.success) throw new Error(j.message || 'Could not load the report.');
            data = j.data || {};
            $('mbScope').textContent = (P.branch ? P.branch + ' · ' : '') + fmtDate($('mbFrom').value) + ' – ' + fmtDate($('mbTo').value) + (j.scope === 'SELF' ? ' · your bills only' : '');
            if (!optionsLoaded) fillOptions();
            render();
        } catch (e) {
            const msg = `<div class="alert alert-danger m-3 mb-0">${esc(e.message)}</div>`;
            $('tblExec').innerHTML = $('tblBill').innerHTML = `<tbody><tr><td>${msg}</td></tr></tbody>`; $('docWrap').innerHTML = msg;
        }
    }

    function fillOptions() {
        const sel = $('mbExec');
        (data.options || []).filter(o => o.FilterKey === 'executive').forEach(o => sel.add(new Option(o.Text, o.Value)));
        optionsLoaded = true;
    }

    function achBar(pct) {
        if (pct == null) return '<span class="text-muted small">No target</span>';
        const c = pct >= 100 ? '#16a34a' : pct >= 60 ? '#d97706' : '#dc2626';
        return `<div class="d-flex align-items-center gap-2"><div class="mb-bar flex-fill"><i style="width:${Math.min(100, pct)}%;background:${c}"></i></div><b style="color:${c}">${n(pct).toFixed(1)}%</b></div>`;
    }

    function render() {
        const s = data.summary || {}, groups = data.groups || [], rows = data.rows || [];
        const ach = n(s.PeriodTarget) > 0 ? n(s.TaggedNetAmount) * 100 / n(s.PeriodTarget) : null;
        const k = (c, label, val, sub) => `<div class="col-6 col-lg"><div class="mb-kpi" style="--c:${c}"><small>${label}</small><b>${val}</b><span>${sub}</span></div></div>`;
        $('mbKpis').innerHTML =
            k('#c2410c', 'Executive business', money(s.TaggedNetAmount), `${int(s.ExecutivesWithBusiness)} of ${int(s.ExecutiveCount)} executives`) +
            k('#7c3aed', 'Period target', money(s.PeriodTarget), 'from Sales Target setup (pro-rated)') +
            k(ach == null ? '#94a3b8' : ach >= 100 ? '#16a34a' : '#dc2626', 'Achievement', ach == null ? '—' : ach.toFixed(1) + '%', 'executive business ÷ target') +
            k('#2563eb', 'All LAB net', money(s.NetAmount), `${int(s.BillCount)} bills · ${int(s.PatientCount)} patients`) +
            k('#0891b2', 'Doctor visits', int(s.VisitCount) + (n(s.VisitTarget) > 0 ? ' / ' + n(s.VisitTarget).toFixed(0) : ''), n(s.VisitTarget) > 0 ? (n(s.VisitCount) * 100 / n(s.VisitTarget)).toFixed(1) + '% of visit target' : 'no visit target') +
            k('#16a34a', 'Collected', money(s.PaidAmount), 'Due ' + money(s.DueAmount)) +
            k('#64748b', 'Not tagged', int(s.UntaggedBills) + ' bills', 'doctor has no LAB executive');
        renderExec(groups.filter(g => g.GroupKey === 'byExecutive'));
        renderDoc(groups.filter(g => g.GroupKey === 'byDoctor'), rows);
        renderBills(rows);
    }

    function renderExec(list) {
        let t = { d: 0, b: 0, p: 0, ba: 0, di: 0, ne: 0, pa: 0, du: 0, pt: 0, vt: 0, vc: 0 };
        const body = list.map(g => {
            t.d += n(g.DoctorCount); t.b += n(g.BillCount); t.p += n(g.PatientCount); t.ba += n(g.BillAmount); t.di += n(g.DiscountAmount);
            t.ne += n(g.NetAmount); t.pa += n(g.PaidAmount); t.du += n(g.DueAmount); t.pt += n(g.PeriodTarget); t.vt += n(g.VisitTarget); t.vc += n(g.VisitCount);
            const none = g.ExecKey === 'NONE';
            return `<tr${n(g.BillCount) === 0 ? ' class="text-muted"' : ''}>
                <td><div class="fw-semibold">${esc(g.ExecutiveName)}${!none && !g.IsActive ? ' <span class="badge bg-secondary-subtle text-secondary">Inactive</span>' : ''}</div><small class="text-muted">${esc(g.ExecutiveCode || '')}</small></td>
                <td>${pill(g.ExecutiveType)}</td><td class="mb-num">${int(g.DoctorCount)}</td><td class="mb-num">${int(g.BillCount)}</td><td class="mb-num">${int(g.PatientCount)}</td>
                <td class="mb-num">${money(g.BillAmount)}</td><td class="mb-num text-danger">${money(g.DiscountAmount)}</td><td class="mb-num fw-bold">${money(g.NetAmount)}</td>
                <td class="mb-num text-success">${money(g.PaidAmount)}</td><td class="mb-num text-danger">${money(g.DueAmount)}</td>
                <td>${none ? '—' : g.Frequency ? FREQ[g.Frequency] || esc(g.Frequency) : '<span class="text-warning-emphasis small">Not set</span>'}</td><td class="mb-num">${none ? '—' : money(g.PeriodTarget)}</td>
                <td style="min-width:150px">${none ? '' : achBar(g.AchievementPct)}</td>
                <td class="mb-num">${none ? '—' : n(g.VisitTarget).toFixed(0)}</td><td class="mb-num">${none ? '—' : int(g.VisitCount)}</td>
                <td style="min-width:130px">${none ? '' : achBar(g.VisitAchievementPct)}</td></tr>`;
        }).join('');
        $('tblExec').innerHTML = `<thead><tr><th>Marketing executive</th><th>Type</th><th class="mb-num">Doctors</th><th class="mb-num">Bills</th><th class="mb-num">Patients</th>
            <th class="mb-num">Bill amt</th><th class="mb-num">Discount</th><th class="mb-num">Net</th><th class="mb-num">Paid</th><th class="mb-num">Due</th>
            <th>Target frequency</th><th class="mb-num">Sales target</th><th>Sales achieved</th><th class="mb-num">Visit target</th><th class="mb-num">Visits done</th><th>Visits achieved</th></tr></thead>
            <tbody>${body || '<tr><td colspan="16" class="text-center text-muted py-4">No marketing executives found.</td></tr>'}</tbody>
            ${list.length ? `<tfoot class="fw-bold table-light"><tr><td colspan="2">Total</td><td class="mb-num">${int(t.d)}</td><td class="mb-num">${int(t.b)}</td><td class="mb-num">${int(t.p)}</td>
            <td class="mb-num">${money(t.ba)}</td><td class="mb-num">${money(t.di)}</td><td class="mb-num">${money(t.ne)}</td><td class="mb-num">${money(t.pa)}</td><td class="mb-num">${money(t.du)}</td>
            <td></td><td class="mb-num">${money(t.pt)}</td><td></td><td class="mb-num">${t.vt.toFixed(0)}</td><td class="mb-num">${int(t.vc)}</td><td></td></tr></tfoot>` : ''}`;
    }

    const billLink = r => `<a href="${P.billUrl}?labOrderId=${r.LabOrderId}" target="_blank" class="fw-semibold text-decoration-none">${esc(r.BillNo)}</a>`;
    const linesOf = id => (data.lines || []).filter(l => l.LabOrderId === id);

    function renderDoc(docs, rows) {
        if (!docs.length) { $('docWrap').innerHTML = '<div class="text-center text-muted py-4">No bills in this period.</div>'; return; }
        const byExec = {};
        docs.forEach(d => (byExec[d.ExecKey] = byExec[d.ExecKey] || { name: d.ExecutiveName, code: d.ExecutiveCode, type: d.ExecutiveType, docs: [] }).docs.push(d));
        $('docWrap').innerHTML = Object.entries(byExec).map(([ek, e], ei) => {
            const net = e.docs.reduce((a, d) => a + n(d.NetAmount), 0), bills = e.docs.reduce((a, d) => a + n(d.BillCount), 0);
            const docRows = e.docs.map((d, di) => {
                const bl = rows.filter(r => r.ExecKey === ek && r.DoctorKey === d.DoctorKey);
                const id = `mbd${ei}_${di}`;
                return `<tr class="mb-doc-row" data-bs-toggle="collapse" data-bs-target="#${id}"><td><i class="bi bi-chevron-right me-1 small"></i><span class="fw-semibold">${esc(d.DoctorName)}</span></td>
                    <td class="mb-num">${int(d.BillCount)}</td><td class="mb-num">${int(d.PatientCount)}</td><td class="mb-num">${int(d.TestCount)}</td><td class="mb-num">${money(d.BillAmount)}</td>
                    <td class="mb-num text-danger">${money(d.DiscountAmount)}</td><td class="mb-num fw-bold">${money(d.NetAmount)}</td><td class="mb-num text-success">${money(d.PaidAmount)}</td><td class="mb-num text-danger">${money(d.DueAmount)}</td></tr>
                    <tr class="mb-sub"><td colspan="9" class="p-0"><div class="collapse" id="${id}"><table class="table table-sm mb-0 mb-table"><thead><tr><th class="ps-4">Bill</th><th>Date</th><th>Patient</th><th>Mobile</th><th>Type</th><th>Tests</th><th class="mb-num">Net</th><th class="mb-num">Paid</th><th class="mb-num">Due</th></tr></thead><tbody>
                    ${bl.map(r => `<tr${r.IsCancelled ? ' class="text-muted text-decoration-line-through"' : ''}><td class="ps-4">${billLink(r)}</td><td>${fmtDate(r.BillDate)}</td><td>${esc(r.PatientName)} <small class="text-muted">${esc(r.PatientCode)}</small></td><td>${esc(r.PhoneNumber)}</td>
                        <td>${esc(r.BillingType)}${r.PartnerName ? ' · ' + esc(r.PartnerName) : ''}</td><td class="small">${linesOf(r.LabOrderId).map(l => esc(l.TestName)).join(', ')}</td>
                        <td class="mb-num">${money(r.NetAmount)}</td><td class="mb-num">${money(r.PaidAmount)}</td><td class="mb-num">${money(r.DueAmount)}</td></tr>`).join('')}</tbody></table></div></td></tr>`;
            }).join('');
            return `<div class="mb-3"><div class="mb-exec-head d-flex justify-content-between flex-wrap gap-2" data-bs-toggle="collapse" data-bs-target="#mbe${ei}">
                <div><i class="bi bi-person-badge me-1" style="color:#c2410c"></i><b>${esc(e.name)}</b> ${e.code ? `<small class="text-muted">(${esc(e.code)})</small>` : ''} ${pill(e.type)}</div>
                <div class="small"><b>${e.docs.length}</b> doctor(s) · <b>${int(bills)}</b> bills · Net <b>${money(net)}</b></div></div>
                <div class="collapse show" id="mbe${ei}"><div class="table-responsive"><table class="table mb-0 mb-table"><thead><tr><th>Referral doctor</th><th class="mb-num">Bills</th><th class="mb-num">Patients</th><th class="mb-num">Tests</th><th class="mb-num">Bill amt</th><th class="mb-num">Discount</th><th class="mb-num">Net</th><th class="mb-num">Paid</th><th class="mb-num">Due</th></tr></thead>
                <tbody>${docRows}</tbody></table></div></div></div>`;
        }).join('');
    }

    function renderBills(rows) {
        const sorted = rows.slice().sort((a, b) => (a.ExecKey === 'NONE') - (b.ExecKey === 'NONE') || String(a.ExecutiveName).localeCompare(b.ExecutiveName) || new Date(a.BillDate) - new Date(b.BillDate));
        let cur = null, html = '';
        sorted.forEach((r, i) => {
            if (r.ExecKey !== cur) {
                cur = r.ExecKey;
                const grp = sorted.filter(x => x.ExecKey === cur && !x.IsCancelled);
                html += `<tr class="table-warning"><td colspan="11" class="fw-bold"><i class="bi bi-person-badge me-1"></i>${esc(r.ExecutiveName)} ${r.ExecutiveCode ? `<small class="text-muted">(${esc(r.ExecutiveCode)})</small>` : ''} ${pill(r.ExecutiveType)}
                    <span class="float-end small">${grp.length} bills · Net ${money(grp.reduce((a, x) => a + n(x.NetAmount), 0))}</span></td></tr>`;
            }
            const lines = linesOf(r.LabOrderId);
            html += `<tr${r.IsCancelled ? ' class="text-muted"' : ''}><td>${billLink(r)}${r.IsCancelled ? ' <span class="badge bg-danger-subtle text-danger">Cancelled</span>' : ''}<br><small class="text-muted">Token ${esc(r.TokenNo || '—')}</small></td>
                <td>${fmtDate(r.BillDate)}</td><td>${esc(r.BillingType)}${r.PartnerName ? '<br><small class="text-muted">' + esc(r.PartnerName) + '</small>' : ''}</td><td>${esc(r.RefDoctorName || '—')}</td>
                <td>${esc(r.PatientName)}<br><small class="text-muted">${esc(r.PatientCode)} · ${esc(r.PhoneNumber || '')}</small></td>
                <td><a class="small text-decoration-none" data-bs-toggle="collapse" href="#mbl${i}">${int(r.TestCount)} test(s)</a><div class="collapse" id="mbl${i}"><table class="mb-lines">${lines.map(l => `<tr><td class="${l.IsCancelled ? 'cx' : ''}">${esc(l.TestName)}</td><td class="mb-num ps-2">${money(l.Rate)}</td></tr>`).join('')}</table></div></td>
                <td class="mb-num">${money(r.BillAmount)}</td><td class="mb-num text-danger">${money(r.DiscountAmount)}</td><td class="mb-num fw-bold">${money(r.NetAmount)}</td>
                <td class="mb-num text-success">${money(r.PaidAmount)}</td><td class="mb-num text-danger">${money(r.DueAmount)}</td></tr>`;
        });
        $('tblBill').innerHTML = `<thead><tr><th>Bill</th><th>Date</th><th>Billing</th><th>Referral doctor</th><th>Patient</th><th>Tests</th><th class="mb-num">Bill amt</th><th class="mb-num">Discount</th><th class="mb-num">Net</th><th class="mb-num">Paid</th><th class="mb-num">Due</th></tr></thead>
            <tbody>${html || '<tr><td colspan="11" class="text-center text-muted py-4">No bills in this period.</td></tr>'}</tbody>`;
    }

    function csv() {
        if (!data) return;
        const active = document.querySelector('.tab-pane.active').id, q = v => '"' + String(v ?? '').replace(/"/g, '""') + '"';
        let head, body;
        if (active === 'tExec') {
            head = ['Executive', 'Code', 'Type', 'Doctors', 'Bills', 'Patients', 'Bill amount', 'Discount', 'Net', 'Paid', 'Due', 'Target frequency', 'Sales target', 'Sales achievement %', 'Visit target', 'Visits done', 'Visit achievement %'];
            body = (data.groups || []).filter(g => g.GroupKey === 'byExecutive').map(g => [g.ExecutiveName, g.ExecutiveCode, g.ExecutiveType, g.DoctorCount, g.BillCount, g.PatientCount, g.BillAmount, g.DiscountAmount, g.NetAmount, g.PaidAmount, g.DueAmount, g.Frequency, g.PeriodTarget, g.AchievementPct, g.VisitTarget, g.VisitCount, g.VisitAchievementPct]);
        } else {
            head = ['Executive', 'Code', 'Type', 'Referral doctor', 'Bill no', 'Token', 'Date', 'Billing', 'Partner', 'Patient code', 'Patient', 'Mobile', 'Tests', 'Bill amount', 'Discount', 'Net', 'Paid', 'Due', 'Status'];
            body = (data.rows || []).map(r => [r.ExecutiveName, r.ExecutiveCode, r.ExecutiveType, r.RefDoctorName, r.BillNo, r.TokenNo, fmtDate(r.BillDate), r.BillingType, r.PartnerName, r.PatientCode, r.PatientName, r.PhoneNumber,
                linesOf(r.LabOrderId).map(l => l.TestName).join('; '), r.BillAmount, r.DiscountAmount, r.NetAmount, r.PaidAmount, r.DueAmount, r.IsCancelled ? 'Cancelled' : r.PaymentStatus]);
        }
        const blob = new Blob(['﻿' + [head, ...body].map(r => r.map(q).join(',')).join('\r\n')], { type: 'text/csv;charset=utf-8' });
        const a = document.createElement('a'); a.href = URL.createObjectURL(blob);
        a.download = `marketing-executive-business-${active === 'tExec' ? 'summary' : 'bills'}-${$('mbFrom').value}-to-${$('mbTo').value}.csv`; a.click();
    }

    $('mbRange').addEventListener('change', e => { if (e.target.value) { setRange(e.target.value); load(); } });
    ['mbFrom', 'mbTo'].forEach(id => $(id).addEventListener('change', () => $('mbRange').value = ''));
    ['mbExec', 'mbBilling'].forEach(id => $(id).addEventListener('change', load));
    $('mbSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    $('mbApply').addEventListener('click', load);
    $('mbReset').addEventListener('click', () => { $('mbRange').value = 'month'; setRange('month'); ['mbExec', 'mbBilling', 'mbSearch'].forEach(id => $(id).value = ''); load(); });
    $('mbCsv').addEventListener('click', csv);
    setRange('month'); load();
})();
