/* Settings > Payment QR Configuration (SQLScripts/2452). The same rules are checked again in usp_Api_PaymentQr_Save. */
(function () {
    'use strict';
    const P = window.PqPage, $ = id => document.getElementById(id), E = Ipd.esc;
    const modal = () => bootstrap.Modal.getOrCreateInstance($('pqModal'));
    const upiOk = v => /^[a-z0-9._-]{2,256}@[a-z]{2,64}$/i.test(v.trim());
    const payeeOk = v => v.trim().length >= 2 && v.trim().length <= 60 && !/[&=?#%]/.test(v);
    const mccOk = v => !v.trim() || /^\d{4}$/.test(v.trim());
    let rows = [], timer;

    async function load() {
        try { rows = await Ipd.get(P.base + 'ListData') || []; }
        catch (e) { $('pqRows').innerHTML = `<tr><td colspan="8" class="text-danger text-center py-4">${E(e.message)}</td></tr>`; return; }
        $('pqRows').innerHTML = rows.map(r => `<tr>
            <td><div class="fw-semibold">${E(r.BranchName)}</div><small class="text-muted">${E(r.BranchCode || '')}</small></td>
            <td class="font-monospace">${r.ConfigId ? E(r.UpiId) : '<span class="text-muted">Not set</span>'}</td><td>${E(r.PayeeName || '')}</td>
            <td>${r.ConfigId ? (r.AmountMode === 'OPEN' ? 'Payer enters' : 'Amount due') : ''}</td>
            <td>${r.ConfigId ? (r.IsActive ? '<span class="badge text-bg-success">In use</span>' : '<span class="badge text-bg-secondary">Off</span>') : ''}</td>
            <td>${r.ShowQrOnB2BInvoice ? '<span class="badge text-bg-primary">Yes</span>' : `<span class="badge text-bg-light border">No</span>`}</td>
            <td class="small text-muted">${r.LastChanged ? Ipd.dt(r.LastChanged) + (r.LastChangedBy ? ' · ' + E(r.LastChangedBy) : '') : ''}</td>
            <td class="text-end text-nowrap">
                ${P.canStatus && r.ConfigId ? `<button type="button" class="btn btn-sm btn-outline-${r.IsActive ? 'secondary' : 'success'} me-1" data-st="${r.BranchId}">${r.IsActive ? 'Turn off' : 'Turn on'}</button>` : ''}
                <button type="button" class="btn btn-sm ${P.canEdit ? 'btn-outline-primary' : 'btn-outline-secondary'}" data-ed="${r.BranchId}"><i class="bi ${P.canEdit ? 'bi-pencil' : 'bi-eye'} me-1"></i>${P.canEdit ? (r.ConfigId ? 'Change' : 'Set up') : 'View'}</button></td></tr>`).join('')
            || '<tr><td colspan="8" class="text-center text-muted py-4">No branches.</td></tr>';
    }

    function open(r) {
        $('pqTitle').textContent = 'Payment QR · ' + r.BranchName;
        $('pqBranch').value = r.BranchId; $('pqUpi').value = r.UpiId || ''; $('pqPayee').value = r.PayeeName || ''; $('pqMcc').value = r.MerchantCode || '';
        (r.AmountMode === 'OPEN' ? $('pqModeOpen') : $('pqModeDue')).checked = true;
        $('pqRef').checked = r.ConfigId ? !!r.IncludeReference : true; $('pqCaption').value = r.Caption || ''; $('pqActive').checked = r.ConfigId ? !!r.IsActive : true;
        ['pqUpi', 'pqPayee', 'pqMcc'].forEach(id => $(id).classList.remove('is-invalid'));
        $('pqForm').querySelectorAll('input').forEach(el => el.disabled = !P.canEdit);
        $('pqActive').disabled = !P.canEdit || !P.canStatus;
        $('pqSave').classList.toggle('d-none', !P.canEdit);
        if (!r.ShowQrOnB2BInvoice) $('pqCap').innerHTML = `<span class="text-warning-emphasis">This branch does not print the QR on B2B invoices yet: turn on <a href="${P.hs}">Hospital Settings &gt; OPD &gt; Show QR on B2B Invoice</a>.</span>`;
        modal().show(); preview();
    }

    async function preview() {
        const upi = $('pqUpi').value, payee = $('pqPayee').value;
        if (!upiOk(upi) || !payeeOk(payee)) { $('pqImg').innerHTML = '<span class="text-muted small">Enter a valid UPI ID and payee</span>'; $('pqLink').textContent = ''; return; }
        const r = await Ipd.post(P.base + 'Preview', body());
        if (!r.success) return;
        $('pqImg').innerHTML = `<img src="${r.data.image}" alt="UPI QR preview" />`; $('pqLink').textContent = r.data.link;
        const rec = rows.find(x => String(x.BranchId) === $('pqBranch').value);
        if (rec && rec.ShowQrOnB2BInvoice) $('pqCap').textContent = $('pqCaption').value || 'Scan with any UPI app to pay';
    }
    const body = () => ({ branchId: +$('pqBranch').value, upiId: $('pqUpi').value.trim(), payeeName: $('pqPayee').value.trim(), merchantCode: $('pqMcc').value.trim() || null,
        amountMode: document.querySelector('input[name="pqMode"]:checked').value, includeReference: $('pqRef').checked, caption: $('pqCaption').value.trim() || null, isActive: $('pqActive').checked });

    $('pqForm').addEventListener('input', e => { e.target.classList.remove('is-invalid'); clearTimeout(timer); timer = setTimeout(preview, 300); });
    $('pqForm').addEventListener('change', () => { clearTimeout(timer); timer = setTimeout(preview, 100); });
    $('pqMcc').addEventListener('input', e => e.target.value = e.target.value.replace(/\D/g, '').slice(0, 4));
    $('pqForm').addEventListener('submit', async e => {
        e.preventDefault();
        const bad = [['pqUpi', upiOk], ['pqPayee', payeeOk], ['pqMcc', mccOk]].filter(([id, f]) => !f($(id).value)).map(([id]) => id);
        bad.forEach(id => $(id).classList.add('is-invalid'));
        if (bad.length) return $(bad[0]).focus();
        $('pqSave').disabled = true;
        try {
            const r = await Ipd.post(P.base + 'Save', body());
            if (!r.success) return Ipd.error(r.error);
            modal().hide(); Ipd.toast('Payment QR saved'); load();
        } finally { $('pqSave').disabled = false; }
    });
    $('pqRows').addEventListener('click', async e => {
        const ed = e.target.closest('[data-ed]'), st = e.target.closest('[data-st]');
        if (ed) open(rows.find(r => r.BranchId === +ed.dataset.ed));
        if (st) {
            const r = rows.find(x => x.BranchId === +st.dataset.st), on = !r.IsActive;
            if (!await Ipd.confirm(on ? 'Turn the QR on?' : 'Turn the QR off?', `${E(r.BranchName)}: ${on ? 'documents will show this QR again.' : 'documents stop showing the QR.'}`, on ? 'Turn on' : 'Turn off')) return;
            const res = await Ipd.post(P.base + 'SetStatus', { branchId: r.BranchId, isActive: on });
            if (!res.success) return Ipd.error(res.error);
            Ipd.toast(on ? 'QR turned on' : 'QR turned off'); load();
        }
    });
    load();
})();
