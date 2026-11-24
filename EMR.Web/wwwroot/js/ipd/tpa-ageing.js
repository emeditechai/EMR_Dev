/* IPD > TPA Receivable & Ageing (Phase 6, SQLScripts/2539-2542). Config: window.AgeingPage */
(function () {
    'use strict';
    const P = window.AgeingPage, $ = id => document.getElementById(id), esc = v => Ipd.esc(v), money = v => Ipd.money(v);
    let tpas = [], claims = [], pick = null, stRows = [], stHead = null, stTpa = null;
    const today = () => Ipd.local().substring(0, 10);

    function csv(name, head, rows) {
        const q = v => `"${String(v ?? '').replace(/"/g, '""')}"`;
        const blob = new Blob(['﻿' + [head, ...rows].map(r => r.map(q).join(',')).join('\r\n')], { type: 'text/csv' });
        const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    }

    async function load() {
        const q = new URLSearchParams({ basis: $('fBasis').value });
        if ($('fAsOf').value) q.set('asOf', $('fAsOf').value);
        if ($('fTpa').value) q.set('insuranceTpaId', $('fTpa').value);
        try {
            const d = await Ipd.get(P.base + 'AgeingData?' + q);
            tpas = d.tpas || []; claims = d.claims || []; pick = null; render();
        } catch (e) { $('tpaRows').innerHTML = `<tr><td colspan="11" class="text-danger small p-3">${esc(e.message)}</td></tr>`; }
    }

    function render() {
        if (!tpas.length) { $('tpaRows').innerHTML = '<tr><td colspan="11" class="text-muted small p-3">Nothing outstanding from TPAs.</td></tr>'; $('tpaFoot').innerHTML = ''; }
        else {
            $('tpaRows').innerHTML = tpas.map(t => `<tr class="tpa-row-click ${pick === t.InsuranceTpaId ? 'table-primary' : ''}" data-id="${t.InsuranceTpaId}">
                <td class="fw-semibold">${esc(t.PayerName)}</td><td class="text-end">${t.Claims}</td>
                <td class="text-end tpa-age-30">${money(t.D0_30)}</td><td class="text-end tpa-age-60">${money(t.D31_60)}</td><td class="text-end tpa-age-90">${money(t.D61_90)}</td>
                <td class="text-end tpa-age-old">${money(t.D91_180)}</td><td class="text-end tpa-age-old">${money(t.D180Plus)}</td><td class="text-end fw-bold">${money(t.Outstanding)}</td>
                <td class="text-end">${t.PendingWriteOff ? money(t.PendingWriteOff) : ''}</td><td class="text-end">${t.OldestDays} d</td>
                <td class="text-end no-print"><button type="button" class="btn btn-sm btn-light border py-0" data-st="${t.InsuranceTpaId}" data-name="${esc(t.PayerName)}"><i class="bi bi-journal-text me-1"></i>Statement</button></td></tr>`).join('');
            const s = k => tpas.reduce((a, t) => a + (Number(t[k]) || 0), 0);
            $('tpaFoot').innerHTML = `<tr class="fw-bold"><td>Total</td><td class="text-end">${s('Claims')}</td><td class="text-end">${money(s('D0_30'))}</td><td class="text-end">${money(s('D31_60'))}</td>
                <td class="text-end">${money(s('D61_90'))}</td><td class="text-end">${money(s('D91_180'))}</td><td class="text-end">${money(s('D180Plus'))}</td><td class="text-end">${money(s('Outstanding'))}</td>
                <td class="text-end">${money(s('PendingWriteOff'))}</td><td></td><td></td></tr>`;
        }
        const list = pick ? claims.filter(c => c.InsuranceTpaId === pick) : claims;
        $('clTitle').textContent = pick ? `Outstanding claims · ${(tpas.find(t => t.InsuranceTpaId === pick) || {}).PayerName || ''}` : 'Outstanding claims (all TPAs)';
        $('clRows').innerHTML = list.map(c => `<tr><td class="fw-semibold">${esc(c.ClaimNo)}</td><td>${esc(c.PatientName)}<div class="small text-muted">${esc(c.IpNo)}</div></td><td>${esc(c.PayerName || '')}</td>
            <td>${esc(c.BillNo)}<div class="small text-muted">${Ipd.date(c.BillAt)}</div></td><td>${c.SubmittedAt ? Ipd.date(c.SubmittedAt) : '<span class="text-danger small">not submitted</span>'}</td>
            <td>${Tpa.pill(c.Status)}</td><td class="text-end">${money(c.ClaimAmount)}</td><td class="text-end fw-semibold">${money(c.Outstanding)}</td><td class="text-end">${c.AgeDays} d</td><td>${esc(c.Bucket)}</td></tr>`).join('')
            || '<tr><td colspan="10" class="text-muted small p-3">No claims.</td></tr>';
        document.querySelectorAll('#tpaRows tr[data-id]').forEach(tr => tr.addEventListener('click', e => {
            if (e.target.closest('[data-st]')) return;
            pick = pick === +tr.dataset.id ? null : +tr.dataset.id; render();
        }));
        document.querySelectorAll('#tpaRows [data-st]').forEach(b => b.addEventListener('click', () => statement(+b.dataset.st, b.dataset.name)));
    }

    async function statement(id, name) {
        stTpa = { id, name };
        $('stTitle').textContent = 'Statement · ' + name;
        if (!$('stTo').value) $('stTo').value = today();
        if (!$('stFrom').value) { const d = new Date(); d.setMonth(d.getMonth() - 3); $('stFrom').value = Ipd.local(d).substring(0, 10); }
        bootstrap.Modal.getOrCreateInstance($('stModal')).show();
        await loadStatement();
    }
    async function loadStatement() {
        try {
            const d = await Ipd.get(P.base + 'StatementData?' + new URLSearchParams({ insuranceTpaId: stTpa.id, fromDate: $('stFrom').value, toDate: $('stTo').value }));
            stHead = d.head || {}; stRows = d.rows || [];
            const kind = { CLAIM: 'Claim', SETTLEMENT: 'Received', TDS: 'TDS', TO_PATIENT: 'To patient', WRITE_OFF: 'Written off' };
            $('stBody').innerHTML = `<table class="table table-sm ipd-table mb-0"><thead><tr><th>Date</th><th>Entry</th><th>Doc</th><th>Claim / bill</th><th>Patient</th><th>Narration</th><th class="text-end">Debit</th><th class="text-end">Credit</th><th class="text-end">Balance</th></tr></thead><tbody>
                <tr class="fw-semibold"><td colspan="8">Opening balance</td><td class="text-end">${money(stHead.Opening)}</td></tr>
                ${stRows.map(r => `<tr><td>${Ipd.date(r.EntryDate)}</td><td>${esc(kind[r.Kind] || r.Kind)}</td><td>${esc(r.DocNo)}</td><td>${esc(r.ClaimNo)}<div class="small text-muted">${esc(r.BillNo)}</div></td>
                    <td>${esc(r.PatientName)}<div class="small text-muted">${esc(r.IpNo)}</div></td><td class="small">${esc(r.Narration)}</td>
                    <td class="text-end">${r.Debit ? money(r.Debit) : ''}</td><td class="text-end">${r.Credit ? money(r.Credit) : ''}</td><td class="text-end">${money(r.Balance)}</td></tr>`).join('')}
                <tr class="fw-bold"><td colspan="6">Closing balance</td><td class="text-end">${money(stHead.Debits)}</td><td class="text-end">${money(stHead.Credits)}</td><td class="text-end">${money(stHead.Closing)}</td></tr></tbody></table>`;
        } catch (e) { $('stBody').innerHTML = `<div class="alert alert-danger small">${esc(e.message)}</div>`; }
    }

    $('csv').addEventListener('click', () => csv(`TPA_ageing_${$('fAsOf').value || today()}.csv`,
        ['Claim', 'Patient', 'IP no.', 'Insurer / TPA', 'Bill', 'Bill date', 'Submitted', 'Status', 'Claim amount', 'Outstanding', 'Age (days)', 'Bucket'],
        claims.map(c => [c.ClaimNo, c.PatientName, c.IpNo, c.PayerName, c.BillNo, Ipd.date(c.BillAt), c.SubmittedAt ? Ipd.date(c.SubmittedAt) : '', c.Status, c.ClaimAmount, c.Outstanding, c.AgeDays, c.Bucket])));
    $('stCsv').addEventListener('click', () => stTpa && csv(`TPA_statement_${stTpa.name.replace(/\W+/g, '_')}.csv`,
        ['Date', 'Entry', 'Doc', 'Claim', 'Bill', 'Patient', 'IP no.', 'Narration', 'Debit', 'Credit', 'Balance'],
        [['', 'Opening', '', '', '', '', '', '', '', '', stHead?.Opening ?? 0], ...stRows.map(r => [Ipd.date(r.EntryDate), r.Kind, r.DocNo, r.ClaimNo, r.BillNo, r.PatientName, r.IpNo, r.Narration, r.Debit, r.Credit, r.Balance])]));
    $('stLoad').addEventListener('click', loadStatement);
    ['fAsOf', 'fBasis', 'fTpa'].forEach(id => $(id).addEventListener('change', load));
    $('reload').addEventListener('click', load);
    Ipd.get(P.base + 'AgeingLookups').then(l => $('fTpa').insertAdjacentHTML('beforeend', (l.tpas || []).map(t => `<option value="${t.InsuranceTpaId}">${esc(t.Name)}</option>`).join(''))).catch(() => { });
    $('fAsOf').value = today();
    load();
})();
