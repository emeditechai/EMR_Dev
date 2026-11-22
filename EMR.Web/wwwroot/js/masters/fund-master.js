/* Utility > Accounts > Fund Master (SQLScripts/2522): funds (Wallet / Bank), opening balance, top-ups and history.
   The same rules are checked again in the stored procedures. */
(function () {
    'use strict';
    const P = window.FdPage, $ = id => document.getElementById(id), E = Ipd.esc, M = Ipd.money;
    const today = () => { const d = new Date(), p = n => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`; };
    const iso = v => v ? String(v).slice(0, 10) : '';
    const mask = a => a ? (a.length > 4 ? '•••• ' + a.slice(-4) : a) : '';
    const typePill = t => t === 'BANK' ? '<span class="badge text-bg-primary"><i class="bi bi-bank me-1"></i>Bank</span>' : '<span class="badge text-bg-info"><i class="bi bi-wallet2 me-1"></i>Wallet</span>';
    const TX = { OPENING: ['Opening', 'text-bg-secondary'], TOPUP: ['Top-up', 'text-bg-success'], PAYOUT: ['Payout', 'text-bg-danger'] };
    const modal = id => bootstrap.Modal.getOrCreateInstance($(id));
    let rows = [], timer, current = null, banks = [];

    // ── list ──
    function stats() {
        const act = rows.filter(r => r.IsActive), sum = l => l.reduce((a, r) => a + Number(r.CurrentBalance || 0), 0);
        const card = (cls, icon, val, lbl) => `<div class="col-12 col-sm-6 col-lg-3"><div class="stat-card ${cls}"><div class="stat-icon"><i class="bi ${icon}"></i></div><div><div class="stat-value">${val}</div><div class="stat-label">${lbl}</div></div></div></div>`;
        $('stats').innerHTML = card('stat-blue', 'bi-safe2', act.length + ' / ' + rows.length, 'Active Funds') + card('stat-green', 'bi-cash-stack', M(sum(act)), 'Total Balance (active)')
            + card('stat-purple', 'bi-bank', M(sum(act.filter(r => r.FundType === 'BANK'))), 'In Bank Funds') + card('stat-amber', 'bi-wallet2', M(sum(act.filter(r => r.FundType === 'WALLET'))), 'In Wallets');
    }
    async function load() {
        const q = new URLSearchParams({ search: $('fSearch').value.trim(), type: $('fType').value, status: $('fStatus').value });
        try { rows = await Ipd.get(P.base + 'ListData?' + q) || []; }
        catch (e) { $('rows').innerHTML = `<tr><td colspan="9" class="text-center text-danger py-4">${E(e.message)}</td></tr>`; return; }
        stats();
        $('rows').innerHTML = rows.length ? rows.map((r, i) => `<tr>
            <td class="text-muted">${i + 1}</td>
            <td><div class="d-flex align-items-center gap-2"><div class="bf-avatar ${r.FundType === 'WALLET' ? 'wallet' : ''}"><i class="bi ${r.FundType === 'WALLET' ? 'bi-wallet2' : 'bi-bank'}"></i></div><div><div class="fw-semibold">${E(r.FundName)}</div><div class="small text-muted bf-mono">${E(r.FundCode)}</div></div></div></td>
            <td>${typePill(r.FundType)}</td>
            <td>${r.FundType === 'BANK' ? `${E(r.BankName || '')}<div class="small text-muted font-monospace">${E(mask(r.AccountNumber))} · ${E(r.IFSCCode || '')}</div>` : '<span class="text-muted">—</span>'}</td>
            <td class="text-end">${M(r.OpeningBalance)}<div class="small text-muted">${Ipd.date(r.OpeningDate)}</div></td>
            <td class="text-end fw-bold ${Number(r.CurrentBalance) < 0 ? 'text-danger' : 'text-success'}">${M(r.CurrentBalance)}</td>
            <td class="small">${r.LastTopUpDate ? Ipd.date(r.LastTopUpDate) : '<span class="text-muted">—</span>'}</td>
            <td class="text-center">${r.IsActive ? '<span class="badge text-bg-success-subtle text-success border border-success-subtle">Active</span>' : '<span class="badge text-bg-secondary-subtle text-secondary border">Inactive</span>'}</td>
            <td class="text-end text-nowrap">
                ${P.can.details ? `<button type="button" class="btn btn-sm btn-outline-secondary fd-view" data-id="${r.FundId}" title="View"><i class="bi bi-eye"></i></button>` : ''}
                ${P.can.history ? `<button type="button" class="btn btn-sm btn-outline-secondary fd-hist" data-id="${r.FundId}" title="History"><i class="bi bi-clock-history"></i></button>` : ''}
                ${P.can.topup && r.IsActive ? `<button type="button" class="btn btn-sm btn-success fd-topup" data-id="${r.FundId}" title="Top up"><i class="bi bi-plus-circle"></i></button>` : ''}
                ${P.can.edit ? `<button type="button" class="btn btn-sm btn-outline-primary fd-edit" data-id="${r.FundId}" title="Edit"><i class="bi bi-pencil"></i></button>` : ''}
                ${P.can.status ? `<button type="button" class="btn btn-sm ${r.IsActive ? 'btn-outline-danger' : 'btn-outline-success'} fd-status" data-id="${r.FundId}" title="${r.IsActive ? 'Deactivate' : 'Activate'}"><i class="bi ${r.IsActive ? 'bi-toggle-on' : 'bi-toggle-off'}"></i></button>` : ''}</td></tr>`).join('')
            : '<tr><td colspan="9" class="text-center text-muted py-4"><i class="bi bi-inbox me-1"></i>No funds yet.</td></tr>';
    }

    // ── add / edit / view ──
    const fdType = () => document.querySelector('input[name="fdType"]:checked').value;
    function typeUi() { $('fdBankBox').classList.toggle('d-none', fdType() !== 'BANK'); }
    document.querySelectorAll('input[name="fdType"]').forEach(r => r.addEventListener('change', typeUi));

    async function loadBanks(fundId, selected) {
        $('fdBank').innerHTML = '<option value="">Loading…</option>';
        try { banks = await Ipd.get(P.base + 'BankOptions' + (fundId ? '?fundId=' + fundId : '')) || []; } catch (e) { banks = []; }
        $('fdBank').innerHTML = '<option value="">-- Choose a bank account --</option>' + banks.map(b =>
            `<option value="${b.BankId}" ${b.UsedByOtherFund ? 'disabled' : ''} ${b.BankId === selected ? 'selected' : ''}>${E(b.BankName)} · ${E(mask(b.AccountNumber))} · ${E(b.IFSCCode)} · ${E(b.BranchName)}${b.UsedByOtherFund ? ' (has a fund)' : ''}${b.IsActive ? '' : ' (inactive)'}</option>`).join('');
        if (!banks.length) $('fdBank').innerHTML = '<option value="">No active bank account - add one in Master > General > Bank Master</option>';
    }

    const rules = {
        fdCode: v => /^[A-Za-z0-9_-]{1,20}$/.test(v.trim()),
        fdName: v => v.trim().length >= 2,
        fdOpening: v => v !== '' && !isNaN(Number(v)) && Number(v) >= 0,
        fdOpeningDate: v => !!v && v <= today(),
        fdBank: v => fdType() !== 'BANK' || !!v
    };
    const check = id => { const ok = rules[id]($(id).value); $(id).classList.toggle('is-invalid', !ok); return ok; };
    Object.keys(rules).forEach(id => $(id).addEventListener('input', () => { if ($(id).classList.contains('is-invalid')) check(id); }));
    $('fdCode').addEventListener('input', e => { e.target.value = e.target.value.toUpperCase().replace(/\s/g, ''); });

    async function open(r, readOnly) {
        $('fdForm').reset(); Object.keys(rules).forEach(id => $(id).classList.remove('is-invalid'));
        current = r;
        $('fdTitle').textContent = !r ? 'Add Fund' : readOnly ? 'Fund' : 'Edit Fund';
        $('fdId').value = r ? r.FundId : '';
        $('fdCode').value = r?.FundCode || ''; $('fdName').value = r?.FundName || '';
        (r?.FundType === 'BANK' ? $('fdTypeBank') : $('fdTypeWallet')).checked = true;
        $('fdOpening').value = r ? Number(r.OpeningBalance) : 0; $('fdOpeningDate').value = r ? iso(r.OpeningDate) : today(); $('fdOpeningDate').max = today();
        $('fdRemarks').value = r?.Remarks || ''; $('fdActive').checked = r ? !!r.IsActive : true;
        const moved = r && Number(r.MovementCount) > 0;
        $('fdOpeningHint').textContent = moved ? 'Fixed: the fund already has top-ups. Use Top up to add money.' : r ? 'Can be corrected while the fund has no top-ups.' : 'Booked as the first entry of the fund history.';
        typeUi();
        await loadBanks(r?.FundId, r?.BankId);
        $('fdForm').querySelectorAll('input,select,textarea').forEach(el => el.disabled = !!readOnly);
        if (!readOnly) {
            $('fdActive').disabled = !r || !P.can.status;
            $('fdOpening').disabled = $('fdOpeningDate').disabled = !!moved;
        }
        $('fdSave').classList.toggle('d-none', !!readOnly);
        $('fdAudit').classList.toggle('d-none', !r);
        if (r) $('fdAudit').innerHTML = `Balance <b>${M(r.CurrentBalance)}</b> · created ${Ipd.dt(r.CreatedDate)}${r.CreatedByName ? ' by ' + E(r.CreatedByName) : ''}${r.ModifiedDate ? ` · last changed ${Ipd.dt(r.ModifiedDate)}${r.ModifiedByName ? ' by ' + E(r.ModifiedByName) : ''}` : ''}`;
        modal('fdModal').show();
        if (!readOnly) setTimeout(() => $(r ? 'fdName' : 'fdCode').focus(), 300);
    }

    $('fdForm').addEventListener('submit', async e => {
        e.preventDefault();
        if (!Object.keys(rules).map(check).every(Boolean)) { $('fdForm').querySelector('.is-invalid')?.focus(); return; }
        const body = {
            fundId: Number($('fdId').value) || null, fundCode: $('fdCode').value.trim().toUpperCase(), fundName: $('fdName').value.trim(), fundType: fdType(),
            bankId: fdType() === 'BANK' ? Number($('fdBank').value) || null : null, openingBalance: Number($('fdOpening').value) || 0,
            openingDate: $('fdOpeningDate').value || null, remarks: $('fdRemarks').value.trim() || null, isActive: $('fdActive').checked
        };
        const btn = $('fdSave'); btn.disabled = true;
        try {
            const res = await Ipd.post(P.base + 'Save', body);
            if (!res.success) return Ipd.error(res.error);
            modal('fdModal').hide(); Ipd.toast(body.fundId ? 'Fund updated' : 'Fund added'); load();
        } finally { btn.disabled = false; }
    });

    // ── top-up ──
    const refNeeded = () => $('tuMode').value !== 'CASH';
    function tuPreview() {
        const amt = Number($('tuAmount').value) || 0;
        $('tuAfter').textContent = M(Number(current?.CurrentBalance || 0) + (amt > 0 ? amt : 0));
        $('tuRefReq').classList.toggle('d-none', !refNeeded());
    }
    ['tuAmount', 'tuMode'].forEach(id => $(id).addEventListener('input', tuPreview));
    $('tuMode').addEventListener('change', tuPreview);
    function openTopUp(r) {
        current = r; $('tuForm').reset(); ['tuAmount', 'tuDate', 'tuRef'].forEach(id => $(id).classList.remove('is-invalid'));
        $('tuId').value = r.FundId; $('tuFund').textContent = r.FundName + ' (' + r.FundCode + ')';
        $('tuFundSub').innerHTML = r.FundType === 'BANK' ? `${E(r.BankName || '')} ${E(mask(r.AccountNumber))}` : 'Wallet';
        $('tuBal').textContent = M(r.CurrentBalance); $('tuDate').value = today(); $('tuDate').max = today(); $('tuDate').min = iso(r.OpeningDate);
        $('tuMode').value = r.FundType === 'BANK' ? 'NEFT' : 'CASH'; tuPreview();
        modal('tuModal').show(); setTimeout(() => $('tuAmount').focus(), 300);
    }
    $('tuForm').addEventListener('submit', async e => {
        e.preventDefault();
        const okAmt = Number($('tuAmount').value) > 0, okDate = !!$('tuDate').value && $('tuDate').value <= today() && $('tuDate').value >= iso(current.OpeningDate),
              okRef = !refNeeded() || $('tuRef').value.trim() !== '';
        $('tuAmount').classList.toggle('is-invalid', !okAmt); $('tuDate').classList.toggle('is-invalid', !okDate); $('tuRef').classList.toggle('is-invalid', !okRef);
        if (!okAmt || !okDate || !okRef) return;
        const amt = Number($('tuAmount').value);
        if (!await Ipd.confirm('Top up this fund?', `${M(amt)} to <b>${E(current.FundName)}</b> by ${E($('tuMode').selectedOptions[0].text)}.<br>New balance: <b>${M(Number(current.CurrentBalance) + amt)}</b>`, 'Top up')) return;
        const btn = $('tuSave'); btn.disabled = true;
        try {
            const res = await Ipd.post(P.base + 'TopUp', { fundId: current.FundId, amount: amt, txnDate: $('tuDate').value, paymentMode: $('tuMode').value,
                referenceNo: $('tuRef').value.trim() || null, remarks: $('tuRemarks').value.trim() || null });
            if (!res.success) return Ipd.error(res.error);
            modal('tuModal').hide(); Ipd.toast('Topped up · balance ' + M(res.data && res.data.Balance)); load();
        } finally { btn.disabled = false; }
    });

    // ── history ──
    async function loadHistory() {
        $('hiRows').innerHTML = '<tr><td colspan="8" class="text-center text-muted py-3"><span class="spinner-border spinner-border-sm me-1"></span>Loading…</td></tr>';
        const q = new URLSearchParams({ id: current.FundId, fromDate: $('hiFrom').value, toDate: $('hiTo').value });
        let h;
        try { h = await Ipd.get(P.base + 'History?' + q) || []; }
        catch (e) { $('hiRows').innerHTML = `<tr><td colspan="8" class="text-center text-danger py-3">${E(e.message)}</td></tr>`; return; }
        const inSum = h.filter(t => Number(t.Amount) > 0).reduce((a, t) => a + Number(t.Amount), 0), outSum = h.filter(t => Number(t.Amount) < 0).reduce((a, t) => a + Number(t.Amount), 0);
        $('hiTotals').innerHTML = `In <b class="text-success">${M(inSum)}</b> · Out <b class="text-danger">${M(-outSum)}</b> · ${h.length} entr${h.length === 1 ? 'y' : 'ies'}`;
        $('hiRows').innerHTML = h.length ? h.map(t => { const k = TX[t.TxnType] || [t.TxnType, 'text-bg-light']; return `<tr>
            <td class="text-nowrap">${Ipd.date(t.TxnDate)}<div class="small text-muted">${Ipd.dt(t.CreatedDate)}</div></td>
            <td><span class="badge ${k[1]}">${E(k[0])}</span></td><td>${E(t.PaymentMode || '—')}</td><td class="font-monospace small">${E(t.ReferenceNo || '')}</td>
            <td class="small">${E(t.Remarks || '')}</td>
            <td class="text-end fw-semibold ${Number(t.Amount) < 0 ? 'text-danger' : 'text-success'}">${Number(t.Amount) < 0 ? '-' : '+'}${M(Math.abs(Number(t.Amount)))}</td>
            <td class="text-end fw-bold">${M(t.BalanceAfter)}</td><td class="small">${E(t.CreatedByName || '')}${t.BranchName ? `<div class="text-muted">${E(t.BranchName)}</div>` : ''}</td></tr>`; }).join('')
            : '<tr><td colspan="8" class="text-center text-muted py-3">No entries in this period.</td></tr>';
    }
    function openHistory(r) {
        current = r; $('hiTitle').textContent = r.FundName + ' - History';
        $('hiSub').innerHTML = `${E(r.FundCode)} · ${r.FundType === 'BANK' ? E((r.BankName || '') + ' ' + mask(r.AccountNumber)) : 'Wallet'} · balance <b>${M(r.CurrentBalance)}</b>`;
        $('hiFrom').value = ''; $('hiTo').value = ''; modal('hiModal').show(); loadHistory();
    }
    $('hiApply').addEventListener('click', loadHistory);

    // ── list actions ──
    $('btnAdd')?.addEventListener('click', () => open(null, false));
    $('rows').addEventListener('click', async e => {
        const b = e.target.closest('button'); if (!b) return;
        const r = rows.find(x => x.FundId === Number(b.dataset.id)); if (!r) return;
        if (b.classList.contains('fd-view')) open(r, true);
        else if (b.classList.contains('fd-edit')) open(r, false);
        else if (b.classList.contains('fd-topup')) openTopUp(r);
        else if (b.classList.contains('fd-hist')) openHistory(r);
        else if (b.classList.contains('fd-status')) {
            if (!await Ipd.confirm(r.IsActive ? 'Deactivate this fund?' : 'Activate this fund?', `<b>${E(r.FundName)}</b> (${E(r.FundCode)}) · balance ${M(r.CurrentBalance)}`, r.IsActive ? 'Deactivate' : 'Activate')) return;
            const res = await Ipd.post(P.base + 'SetStatus', { id: r.FundId, isActive: !r.IsActive });
            if (!res.success) return Ipd.error(res.error);
            Ipd.toast(r.IsActive ? 'Deactivated' : 'Activated'); load();
        }
    });
    ['fType', 'fStatus'].forEach(id => $(id).addEventListener('change', load));
    $('fSearch').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(load, 300); });
    $('fReset').addEventListener('click', () => { $('fSearch').value = ''; $('fType').value = ''; $('fStatus').value = ''; load(); });
    load();
})();
