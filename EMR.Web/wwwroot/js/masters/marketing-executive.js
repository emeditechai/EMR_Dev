/* Master > General > Marketing Executive Master (SQLScripts/2440): list, add, edit, view, status, delete. The same rules
   are checked again in the stored procedure (unique code, 10-digit mobile, e-mail, target >= 0). */
(function () {
    'use strict';
    const P = window.MePage, $ = id => document.getElementById(id), E = Ipd.esc;
    const typeName = { OPD: 'OPD', LAB: 'LAB', IPD: 'IPD', MED: 'MED (Pharmacy)' };
    const typePill = t => `<span class="badge ${({ OPD: 'text-bg-primary', LAB: 'text-bg-info', IPD: 'text-bg-success', MED: 'text-bg-warning' })[t] || 'text-bg-secondary'}">${E(typeName[t] || t)}</span>`;
    const modal = () => bootstrap.Modal.getOrCreateInstance($('meModal'));
    let rows = [], timer, current = null, emailState = { value: '', ok: true };

    const rules = {
        meType: v => !!v,
        meName: v => v.trim().length >= 2 && !/\d/.test(v),
        meCode: v => /^[A-Za-z0-9_-]{1,20}$/.test(v.trim()),
        mePhone: v => /^[6-9]\d{9}$/.test(v.trim()),
        meEmail: v => !v.trim() || /^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$/.test(v.trim()),
        meTarget: v => v !== '' && !isNaN(Number(v)) && Number(v) >= 0,
        // the login's password, needed when an e-mail ID is given and the executive has no login yet (SQLScripts/2444)
        mePwd: v => !needsPassword() || v.length >= 6,
        mePwd2: v => !needsPassword() || v === $('mePwd').value
    };
    const emailOk = v => /^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$/.test(v.trim());
    function needsPassword() { return !(current && current.HasLogin) && emailOk($('meEmail').value); }
    function loginUi() {
        const has = !!(current && current.HasLogin), show = has || emailOk($('meEmail').value);
        $('meLoginBox').classList.toggle('d-none', !show);
        $('meLoginNew').classList.toggle('d-none', has);
        $('meLoginInfo').classList.toggle('d-none', !has);
        if (has) $('meLoginInfo').innerHTML = `<i class="bi bi-check-circle-fill text-success me-1"></i>Login <b>${E(current.LoginUsername)}</b> ${current.LoginActive ? '<span class="badge text-bg-success">Active</span>' : '<span class="badge text-bg-secondary">Inactive</span>'}
            <span class="text-muted">· follows this executive's e-mail, mobile and status · password is changed in User Master</span>`;
        $('meEmailHint').textContent = has ? 'This is the login (sign-in) of the executive.' : 'With an e-mail ID a login is created (sign-in = e-mail).';
    }
    // server-side availability of the e-mail for the login (checked again on save)
    async function checkEmail() {
        const v = $('meEmail').value.trim().toLowerCase();
        if (!v || !emailOk(v) || (current && current.HasLogin && v === (current.LoginUsername || '').toLowerCase())) { emailState = { value: v, ok: true }; return true; }
        if (emailState.value === v) return emailState.ok;
        $('meEmailHint').innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Checking availability…';
        try {
            const r = await (await fetch(P.base + 'CheckEmail?' + new URLSearchParams({ email: v, executiveId: current ? current.ExecutiveId : '' }),
                { headers: { 'X-Requested-With': 'XMLHttpRequest' }, signal: AbortSignal.timeout(8000) })).json();
            // anything but a clear answer does not block the save: the server checks the e-mail again when saving
            if (!r.success || !r.data || typeof r.data.Available !== 'boolean') { $('meEmailHint').textContent = (r && r.error) || 'Could not check the e-mail now; it is checked again on save.'; return true; }
            emailState = { value: v, ok: !!r.data.Available };
            $('meEmail').classList.toggle('is-invalid', !emailState.ok);
            $('meEmailMsg').textContent = emailState.ok ? 'Enter a valid e-mail ID.' : r.data.Message;
            if (emailState.ok) $('meEmailHint').innerHTML = '<span class="text-success"><i class="bi bi-check-circle me-1"></i>' + E(r.data.Message) + '</span>';
            return emailState.ok;
        } catch { $('meEmailHint').textContent = 'Could not check the e-mail now; it is checked again on save.'; return true; }
    }
    $('meEmail').addEventListener('input', () => { $('meEmailMsg').textContent = 'Enter a valid e-mail ID.'; $('meEmail').classList.remove('is-invalid'); loginUi(); });
    $('meEmail').addEventListener('blur', () => { if (check('meEmail')) checkEmail(); });
    function check(id) {
        const el = $(id), ok = rules[id](el.value);
        el.classList.toggle('is-invalid', !ok);
        return ok;
    }
    Object.keys(rules).forEach(id => $(id).addEventListener(id === 'meType' ? 'change' : 'input', () => { if ($(id).classList.contains('is-invalid') || id === 'mePhone') check(id); }));
    $('mePhone').addEventListener('input', e => { e.target.value = e.target.value.replace(/\D/g, '').slice(0, 10); });
    $('meCode').addEventListener('input', e => { e.target.value = e.target.value.toUpperCase().replace(/\s/g, ''); $('meCodeMsg').textContent = 'Up to 20 letters, digits, - or _ (no spaces).'; });
    // a code already taken (on this list) is flagged before saving; the server checks again
    $('meCode').addEventListener('blur', () => {
        const v = $('meCode').value.trim().toUpperCase(), id = Number($('meId').value) || 0;
        const other = rows.find(r => (r.ExecutiveCode || '').toUpperCase() === v && r.ExecutiveId !== id);
        if (v && other) { $('meCode').classList.add('is-invalid'); $('meCodeMsg').textContent = `Code already used by ${other.ExecutiveName}.`; }
    });

    function stats() {
        const act = rows.filter(r => r.IsActive), tgt = act.reduce((s, r) => s + Number(r.MonthlyTarget || 0), 0);
        const card = (cls, icon, val, lbl) => `<div class="col-12 col-sm-6 col-lg-3"><div class="stat-card ${cls}"><div class="stat-icon"><i class="bi ${icon}"></i></div><div><div class="stat-value">${val}</div><div class="stat-label">${lbl}</div></div></div></div>`;
        $('stats').innerHTML = card('stat-blue', 'bi-people-fill', rows.length, 'Total Executives') + card('stat-green', 'bi-check-circle-fill', act.length, 'Active')
            + card('stat-purple', 'bi-diagram-3-fill', new Set(act.map(r => r.ExecutiveType)).size, 'Business Lines Covered') + card('stat-amber', 'bi-bullseye', Ipd.money(tgt), 'Monthly Target (active)');
    }
    async function load() {
        const q = new URLSearchParams({ type: $('fType').value, search: $('fSearch').value.trim(), status: $('fStatus').value });
        try { rows = await Ipd.get(P.base + 'ListData?' + q) || []; }
        catch (e) { $('rows').innerHTML = `<tr><td colspan="9" class="text-center text-danger py-4">${E(e.message)}</td></tr>`; return; }
        stats();
        $('rows').innerHTML = rows.length ? rows.map((r, i) => `<tr>
            <td class="text-muted">${i + 1}</td>
            <td class="fw-semibold font-monospace">${E(r.ExecutiveCode)}</td>
            <td><div class="fw-semibold">${E(r.ExecutiveName)}</div>${r.Address ? `<div class="small text-muted text-truncate" style="max-width:260px">${E(r.Address)}</div>` : ''}</td>
            <td>${typePill(r.ExecutiveType)}</td>
            <td><a href="tel:+91${E(r.PhoneNumber)}" class="text-decoration-none">${E(r.PhoneNumber)}</a></td>
            <td>${r.EmailId ? `<a href="mailto:${E(r.EmailId)}" class="text-decoration-none">${E(r.EmailId)}</a>${r.HasLogin ? ` <i class="bi bi-key-fill ${r.LoginActive ? 'text-success' : 'text-secondary'}" title="Has a login${r.LoginActive ? '' : ' (inactive)'}"></i>` : ''}` : '<span class="text-muted">—</span>'}</td>
            <td class="text-end fw-semibold">${Ipd.money(r.MonthlyTarget)}</td>
            <td class="text-center">${r.IsActive ? '<span class="badge text-bg-success-subtle text-success border border-success-subtle">Active</span>' : '<span class="badge text-bg-secondary-subtle text-secondary border">Inactive</span>'}</td>
            <td class="text-end text-nowrap">
                <button type="button" class="btn btn-sm btn-outline-secondary me-view" data-id="${r.ExecutiveId}" title="View"><i class="bi bi-eye"></i></button>
                ${P.can.edit ? `<button type="button" class="btn btn-sm btn-outline-primary me-edit" data-id="${r.ExecutiveId}" title="Edit"><i class="bi bi-pencil"></i></button>` : ''}
                ${P.can.del ? `<button type="button" class="btn btn-sm btn-outline-danger me-del" data-id="${r.ExecutiveId}" title="Delete"><i class="bi bi-trash"></i></button>` : ''}</td></tr>`).join('')
            : '<tr><td colspan="9" class="text-center text-muted py-4"><i class="bi bi-inbox me-1"></i>No marketing executives found.</td></tr>';
    }

    function open(r, readOnly) {
        $('meForm').reset(); current = r; emailState = { value: '', ok: true };
        ['meType', 'meName', 'meCode', 'mePhone', 'meEmail', 'meTarget', 'mePwd', 'mePwd2'].forEach(id => $(id).classList.remove('is-invalid'));
        $('meTitle').textContent = !r ? 'Add Marketing Executive' : readOnly ? 'Marketing Executive' : 'Edit Marketing Executive';
        $('meId').value = r ? r.ExecutiveId : '';
        $('meType').value = r ? r.ExecutiveType : ''; $('meName').value = r ? r.ExecutiveName : ''; $('meCode').value = r ? r.ExecutiveCode : '';
        $('mePhone').value = r ? r.PhoneNumber : ''; $('meEmail').value = r ? (r.EmailId || '') : ''; $('meAddress').value = r ? (r.Address || '') : '';
        $('meTarget').value = r ? Number(r.MonthlyTarget) : 0; $('meActive').checked = r ? !!r.IsActive : true;
        $('meForm').querySelectorAll('input,select,textarea').forEach(el => el.disabled = !!readOnly);
        // status is changed here (not on the list), with the Status permission; a new executive starts active
        if (!readOnly) $('meActive').disabled = !r || !P.can.status;
        $('meSave').classList.toggle('d-none', !!readOnly);
        loginUi(); if (readOnly) $('meLoginNew').classList.add('d-none');
        $('meAudit').classList.toggle('d-none', !r);
        if (r) $('meAudit').innerHTML = `Created ${Ipd.dt(r.CreatedDate)}${r.CreatedByName ? ' by ' + E(r.CreatedByName) : ''}${r.ModifiedDate ? ` · last changed ${Ipd.dt(r.ModifiedDate)}${r.ModifiedByName ? ' by ' + E(r.ModifiedByName) : ''}` : ''}`;
        modal().show();
        if (!readOnly) setTimeout(() => $(r ? 'meName' : 'meType').focus(), 300);
    }
    $('btnAdd')?.addEventListener('click', () => open(null, false));
    $('rows').addEventListener('click', async e => {
        const b = e.target.closest('button'); if (!b) return;
        const r = rows.find(x => x.ExecutiveId === Number(b.dataset.id)); if (!r) return;
        if (b.classList.contains('me-view')) open(r, true);
        else if (b.classList.contains('me-edit')) open(r, false);
        else if (b.classList.contains('me-del')) {
            if (!await Ipd.confirm('Delete this marketing executive?', `<b>${E(r.ExecutiveName)}</b> (${E(r.ExecutiveCode)}) will be removed from the list.`, 'Delete')) return;
            const res = await Ipd.post(P.base + 'Delete?id=' + r.ExecutiveId, {});
            if (!res.success) return Ipd.error(res.error);
            Ipd.toast('Deleted'); load();
        }
    });

    $('meForm').addEventListener('submit', async e => {
        e.preventDefault();
        const ok = Object.keys(rules).map(check).every(Boolean);
        if (!ok) { $('meForm').querySelector('.is-invalid')?.focus(); return; }
        if (!await checkEmail()) { $('meEmail').focus(); return; }
        const body = {
            executiveId: Number($('meId').value) || null, executiveType: $('meType').value, executiveName: $('meName').value.trim(),
            executiveCode: $('meCode').value.trim().toUpperCase(), phoneNumber: $('mePhone').value.trim(), emailId: $('meEmail').value.trim() || null,
            address: $('meAddress').value.trim() || null, monthlyTarget: Number($('meTarget').value) || 0, isActive: $('meActive').checked,
            loginPassword: needsPassword() ? $('mePwd').value : null, loginConfirmPassword: needsPassword() ? $('mePwd2').value : null
        };
        const btn = $('meSave'); btn.disabled = true;
        try {
            const res = await Ipd.post(P.base + 'Save', body);
            if (!res.success) {
                if (/e-mail/i.test(res.error || '')) { $('meEmail').classList.add('is-invalid'); $('meEmailMsg').textContent = res.error; $('meEmail').focus(); return; }
                if (/password/i.test(res.error || '')) { $('mePwd').classList.add('is-invalid'); $('mePwd').focus(); return Ipd.error(res.error); }
                if (/code/i.test(res.error || '')) { $('meCode').classList.add('is-invalid'); $('meCodeMsg').textContent = res.error; $('meCode').focus(); return; }
                return Ipd.error(res.error);
            }
            modal().hide();
            Ipd.toast((body.executiveId ? 'Marketing executive updated' : 'Marketing executive added') + (res.data && res.data.LoginCreated ? ' · login created: ' + res.data.LoginUsername : ''));
            load();
        } finally { btn.disabled = false; }
    });

    ['fType', 'fStatus'].forEach(id => $(id).addEventListener('change', load));
    $('fSearch').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(load, 300); });
    $('fReset').addEventListener('click', () => { $('fSearch').value = ''; $('fType').value = ''; $('fStatus').value = ''; load(); });
    load();
})();
