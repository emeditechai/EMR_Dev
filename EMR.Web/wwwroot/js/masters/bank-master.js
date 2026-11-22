/* Master > General > Bank Master (SQLScripts/2522): list, add, edit, view, activate / deactivate. The same rules are
   checked again in the stored procedure (IFSC, account no., MICR, SWIFT, UPI, one primary account, unique account). */
(function () {
    'use strict';
    const P = window.BkPage, $ = id => document.getElementById(id), E = Ipd.esc;
    const TYPE = { CURRENT: 'Current', SAVINGS: 'Savings', OD: 'Overdraft', CC: 'Cash Credit' };
    const modal = () => bootstrap.Modal.getOrCreateInstance($('bkModal'));
    const mask = a => a ? (a.length > 4 ? '•••• ' + a.slice(-4) : a) : '';
    let rows = [], timer;
    const initials = n => String(n || '?').split(/\s+/).filter(w => w && !/^(of|the|and|bank)$/i.test(w)).slice(0, 2).map(w => w[0]).join('').toUpperCase() || 'B';

    // live card preview + checklist
    function preview() {
        const v = id => $(id).value.trim();
        $('pvBank').textContent = v('bkBank') || 'Bank name';
        $('pvType').textContent = $('bkType').selectedOptions[0]?.text || '';
        const a = v('bkAcc');
        $('pvAcc').textContent = a ? a.replace(/(.{4})/g, '$1 ').trim() : '•••• •••• ••••';
        $('pvHolder').textContent = v('bkHolder') || '—';
        $('pvIfsc').textContent = v('bkIfsc').toUpperCase() || '—';
        $('pvBranch').textContent = [v('bkBranch'), v('bkCity')].filter(Boolean).join(', ') || '—';
        $('pvPrimary').classList.toggle('d-none', !$('bkPrimary').checked);
        const ok = { bank: rules.bkBank(v('bkBank')) && rules.bkHolder(v('bkHolder')), acc: rules.bkAcc(a) && rules.bkAcc2($('bkAcc2').value),
                     ifsc: rules.bkIfsc(v('bkIfsc')), branch: rules.bkBranch(v('bkBranch')) };
        document.querySelectorAll('#pvChecks li').forEach(li => li.classList.toggle('ok', !!ok[li.dataset.k]));
    }

    const rules = {
        bkBank: v => v.trim().length >= 2,
        bkHolder: v => v.trim().length >= 2,
        bkAcc: v => /^\d{6,20}$/.test(v.trim()),
        bkAcc2: v => v.trim() === $('bkAcc').value.trim() && v.trim() !== '',
        bkIfsc: v => /^[A-Z]{4}0[A-Z0-9]{6}$/.test(v.trim().toUpperCase()),
        bkMicr: v => !v.trim() || /^\d{9}$/.test(v.trim()),
        bkSwift: v => !v.trim() || /^[A-Z0-9]{8}([A-Z0-9]{3})?$/.test(v.trim().toUpperCase()),
        bkBranch: v => v.trim().length >= 2,
        bkUpi: v => !v.trim() || /^[\w.\-]{2,}@[a-zA-Z]{2,}$/.test(v.trim()),
        bkPhone: v => !v.trim() || /^\d{10,12}$/.test(v.trim()),
        bkEmail: v => !v.trim() || /^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$/.test(v.trim())
    };
    const check = id => { const ok = rules[id]($(id).value); $(id).classList.toggle('is-invalid', !ok); return ok; };
    // SQLScripts/2523: standard banks - the bank name list, the bank filled from a typed IFSC, and a check that the IFSC
    // belongs to the bank chosen (its first 4 letters are the bank's code)
    let directory = [];
    const CAT = { PUBLIC: 'Public sector', PRIVATE: 'Private', 'SMALL FINANCE': 'Small finance', PAYMENTS: 'Payments bank', FOREIGN: 'Foreign', COOPERATIVE: 'Co-operative' };
    (async () => {
        try { directory = await Ipd.get(P.base + 'Directory') || []; } catch { directory = []; }
        $('bkBankList').innerHTML = directory.map(d => `<option value="${E(d.BankName)}">${E(d.BankCode)} · ${E(CAT[d.Category] || d.Category)}</option>`).join('');
    })();
    const byName = n => directory.find(d => d.BankName.toLowerCase() === String(n || '').trim().toLowerCase());
    function ifscHint() {
        const ifsc = $('bkIfsc').value.trim().toUpperCase(), code = ifsc.slice(0, 4), bank = byName($('bkBank').value), hit = directory.find(d => d.BankCode === code);
        let h = '';
        if (bank && ifsc.length >= 4 && code !== bank.BankCode)
            h = `<span class="text-warning-emphasis"><i class="bi bi-exclamation-triangle me-1"></i>${E(bank.BankName)} IFSCs start with ${E(bank.BankCode)}${hit ? ` - ${E(code)} is ${E(hit.BankName)}` : ''}.</span>`;
        else if (hit && ifsc.length >= 4) h = `<span class="text-success"><i class="bi bi-check-circle me-1"></i>${E(hit.BankName)}</span>`;
        else if (bank) h = `IFSC starts with <b>${E(bank.BankCode)}</b>`;
        $('bkIfscHint').innerHTML = h;
    }
    $('bkIfsc').addEventListener('input', () => {
        const hit = directory.find(d => d.BankCode === $('bkIfsc').value.trim().toUpperCase().slice(0, 4));
        if (hit && !$('bkBank').value.trim()) $('bkBank').value = hit.BankName;     // bank filled from the IFSC
        ifscHint();
    });
    $('bkBank').addEventListener('input', ifscHint);
    $('bkForm').addEventListener('input', preview);
    $('bkForm').addEventListener('change', preview);
    Object.keys(rules).forEach(id => $(id).addEventListener('input', () => { if ($(id).classList.contains('is-invalid')) check(id); }));
    ['bkAcc', 'bkAcc2', 'bkMicr', 'bkPhone'].forEach(id => $(id).addEventListener('input', e => { e.target.value = e.target.value.replace(/\D/g, ''); }));
    ['bkIfsc', 'bkSwift'].forEach(id => $(id).addEventListener('input', e => { e.target.value = e.target.value.toUpperCase().replace(/\s/g, ''); }));

    function stats() {
        const act = rows.filter(r => r.IsActive), prim = rows.find(r => r.IsPrimary && r.IsActive);
        const card = (cls, icon, val, lbl) => `<div class="col-12 col-sm-6 col-lg-3"><div class="stat-card ${cls}"><div class="stat-icon"><i class="bi ${icon}"></i></div><div><div class="stat-value">${val}</div><div class="stat-label">${lbl}</div></div></div></div>`;
        $('stats').innerHTML = card('stat-blue', 'bi-bank', rows.length, 'Bank Accounts') + card('stat-green', 'bi-check-circle-fill', act.length, 'Active')
            + card('stat-purple', 'bi-star-fill', prim ? E(prim.BankName) : '—', 'Primary Account') + card('stat-amber', 'bi-safe2', rows.reduce((a, r) => a + Number(r.FundCount || 0), 0), 'Funds Linked');
    }

    async function load() {
        const q = new URLSearchParams({ search: $('fSearch').value.trim(), status: $('fStatus').value });
        try { rows = await Ipd.get(P.base + 'ListData?' + q) || []; }
        catch (e) { $('rows').innerHTML = `<tr><td colspan="10" class="text-center text-danger py-4">${E(e.message)}</td></tr>`; return; }
        stats();
        $('rows').innerHTML = rows.length ? rows.map((r, i) => `<tr>
            <td class="text-muted">${i + 1}</td>
            <td><div class="d-flex align-items-center gap-2"><div class="bf-avatar">${E(initials(r.BankName))}</div><div><div class="fw-semibold">${E(r.BankName)} ${r.IsPrimary ? '<span class="badge text-bg-warning ms-1" title="Primary account"><i class="bi bi-star-fill"></i> Primary</span>' : ''}</div><div class="small text-muted">${E(r.AccountHolderName || '')}</div></div></div></td>
            <td class="bf-mono">${E(mask(r.AccountNumber))}</td>
            <td><span class="badge bg-light text-dark border">${E(TYPE[r.AccountType] || r.AccountType)}</span></td>
            <td class="font-monospace">${E(r.IFSCCode)}</td>
            <td>${E(r.BranchName)}${r.City ? `<div class="small text-muted">${E(r.City)}</div>` : ''}</td>
            <td class="small">${E(r.UpiId || '—')}</td>
            <td class="text-center">${Number(r.FundCount) || '<span class="text-muted">—</span>'}</td>
            <td class="text-center">${r.IsActive ? '<span class="badge text-bg-success-subtle text-success border border-success-subtle">Active</span>' : '<span class="badge text-bg-secondary-subtle text-secondary border">Inactive</span>'}</td>
            <td class="text-end text-nowrap">
                ${P.can.details ? `<button type="button" class="btn btn-sm btn-outline-secondary bk-view" data-id="${r.BankId}" title="View"><i class="bi bi-eye"></i></button>` : ''}
                ${P.can.edit ? `<button type="button" class="btn btn-sm btn-outline-primary bk-edit" data-id="${r.BankId}" title="Edit"><i class="bi bi-pencil"></i></button>` : ''}
                ${P.can.status ? `<button type="button" class="btn btn-sm ${r.IsActive ? 'btn-outline-danger' : 'btn-outline-success'} bk-status" data-id="${r.BankId}" title="${r.IsActive ? 'Deactivate' : 'Activate'}"><i class="bi ${r.IsActive ? 'bi-toggle-on' : 'bi-toggle-off'}"></i></button>` : ''}</td></tr>`).join('')
            : '<tr><td colspan="10" class="text-center text-muted py-4"><i class="bi bi-inbox me-1"></i>No bank accounts yet.</td></tr>';
    }

    function open(r, readOnly) {
        $('bkForm').reset();
        Object.keys(rules).forEach(id => $(id).classList.remove('is-invalid'));
        $('bkTitle').textContent = !r ? 'Add Bank Account' : readOnly ? 'Bank Account' : 'Edit Bank Account';
        $('bkId').value = r ? r.BankId : '';
        const set = (id, v) => { $(id).value = v ?? ''; };
        set('bkBank', r?.BankName); set('bkHolder', r?.AccountHolderName); $('bkType').value = r?.AccountType || 'CURRENT';
        set('bkAcc', r?.AccountNumber); set('bkAcc2', r?.AccountNumber); set('bkIfsc', r?.IFSCCode); set('bkMicr', r?.MICRCode); set('bkSwift', r?.SwiftCode);
        set('bkBranch', r?.BranchName); set('bkCity', r?.City); set('bkAddr', r?.BranchAddress); set('bkUpi', r?.UpiId); set('bkUpiName', r?.UpiHolderName);
        set('bkContact', r?.ContactPerson); set('bkPhone', r?.ContactPhone); set('bkEmail', r?.ContactEmail); set('bkRemarks', r?.Remarks);
        $('bkPrimary').checked = !!r?.IsPrimary; $('bkActive').checked = r ? !!r.IsActive : true;
        preview();
        ifscHint();
        $('bkForm').querySelectorAll('input,select,textarea').forEach(el => el.disabled = !!readOnly);
        if (!readOnly) $('bkActive').disabled = !r || !P.can.status;
        $('bkAcc2').closest('.col-md-6').classList.toggle('d-none', !!readOnly);
        $('pvChecks').classList.toggle('d-none', !!readOnly);
        $('bkSave').classList.toggle('d-none', !!readOnly);
        $('bkSave').innerHTML = '<i class="bi bi-check2-circle me-1"></i>' + (r ? 'Save Changes' : 'Save Bank Account');
        $('bkAudit').classList.toggle('d-none', !r);
        if (r) $('bkAudit').innerHTML = `Added ${Ipd.dt(r.CreatedAt)}${r.CreatedByName ? ' by ' + E(r.CreatedByName) : ''}${r.ModifiedAt ? ` · last changed ${Ipd.dt(r.ModifiedAt)}${r.ModifiedByName ? ' by ' + E(r.ModifiedByName) : ''}` : ''}${Number(r.FundCount) ? ` · used by ${r.FundCount} fund(s)` : ''}`;
        modal().show();
        if (!readOnly) setTimeout(() => $('bkBank').focus(), 300);
    }

    $('btnAdd')?.addEventListener('click', () => open(null, false));
    $('rows').addEventListener('click', async e => {
        const b = e.target.closest('button'); if (!b) return;
        const r = rows.find(x => x.BankId === Number(b.dataset.id)); if (!r) return;
        if (b.classList.contains('bk-view')) open(r, true);
        else if (b.classList.contains('bk-edit')) open(r, false);
        else if (b.classList.contains('bk-status')) {
            if (!await Ipd.confirm(r.IsActive ? 'Deactivate this bank account?' : 'Activate this bank account?', `<b>${E(r.BankName)}</b> ${E(mask(r.AccountNumber))}`, r.IsActive ? 'Deactivate' : 'Activate')) return;
            const res = await Ipd.post(P.base + 'SetStatus', { id: r.BankId, isActive: !r.IsActive });
            if (!res.success) return Ipd.error(res.error);
            Ipd.toast(r.IsActive ? 'Deactivated' : 'Activated'); load();
        }
    });

    $('bkForm').addEventListener('submit', async e => {
        e.preventDefault();
        if (!Object.keys(rules).map(check).every(Boolean)) { $('bkForm').querySelector('.is-invalid')?.focus(); return; }
        const v = id => $(id).value.trim() || null;
        const body = {
            bankId: Number($('bkId').value) || null, bankName: v('bkBank'), accountHolderName: v('bkHolder'), accountNumber: v('bkAcc'), accountType: $('bkType').value,
            ifscCode: (v('bkIfsc') || '').toUpperCase(), micrCode: v('bkMicr'), swiftCode: v('bkSwift'), branchName: v('bkBranch'), branchAddress: v('bkAddr'), city: v('bkCity'),
            upiId: v('bkUpi'), upiHolderName: v('bkUpiName'), contactPerson: v('bkContact'), contactPhone: v('bkPhone'), contactEmail: v('bkEmail'), remarks: v('bkRemarks'),
            isPrimary: $('bkPrimary').checked, isActive: $('bkActive').checked
        };
        const btn = $('bkSave'); btn.disabled = true;
        try {
            const res = await Ipd.post(P.base + 'Save', body);
            if (!res.success) return Ipd.error(res.error);
            modal().hide();
            Ipd.toast(body.bankId ? 'Bank account updated' : 'Bank account added');
            load();
        } finally { btn.disabled = false; }
    });

    $('fStatus').addEventListener('change', load);
    $('fSearch').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(load, 300); });
    $('fReset').addEventListener('click', () => { $('fSearch').value = ''; $('fStatus').value = ''; load(); });
    load();
})();
