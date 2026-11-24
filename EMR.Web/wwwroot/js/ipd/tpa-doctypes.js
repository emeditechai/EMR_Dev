/* Master > IPD Master > TPA Document Checklist (Phase 6, SQLScripts/2539). Config: window.TpaDocPage */
(function () {
    'use strict';
    const P = window.TpaDocPage, $ = id => document.getElementById(id), esc = v => Ipd.esc(v);
    const STAGE = { PREAUTH: 'Pre-authorisation', CLAIM: 'Claim', BOTH: 'Pre-auth and claim' };
    let rows = [];

    async function load() {
        try { rows = await Ipd.get(P.base + 'DocTypesData'); render(); }
        catch (e) { $('rows').innerHTML = `<tr><td colspan="7" class="text-danger small p-3">${esc(e.message)}</td></tr>`; }
    }
    function render() {
        $('rows').innerHTML = rows.map((r, i) => `<tr class="${r.IsActive ? '' : 'text-muted'}"><td>${r.SortOrder}</td><td class="fw-semibold">${esc(r.Name)}</td><td>${esc(STAGE[r.Stage] || r.Stage)}</td>
            <td>${r.IsMandatory ? '<span class="ipd-pill alert">Mandatory</span>' : '<span class="ipd-pill muted">Optional</span>'}</td>
            <td>${r.IsActive ? '<span class="ipd-pill info">Active</span>' : '<span class="ipd-pill muted">Inactive</span>'}</td><td class="text-end">${r.TimesUsed}</td>
            <td class="text-end">${P.canEdit ? `<button type="button" class="btn btn-sm btn-light border py-0" data-i="${i}"><i class="bi bi-pencil"></i></button>` : ''}</td></tr>`).join('')
            || '<tr><td colspan="7" class="text-muted small p-3">No documents yet.</td></tr>';
        document.querySelectorAll('#rows [data-i]').forEach(b => b.addEventListener('click', () => edit(rows[+b.dataset.i])));
    }
    async function edit(r) {
        const res = await Swal.fire({
            title: r ? 'Edit document' : 'Add document', width: 560, showCancelButton: true, confirmButtonText: 'Save', focusConfirm: false,
            html: `<div class="text-start small">
                <label class="form-label fw-semibold">Document</label><input id="dName" class="form-control" maxlength="150" value="${esc(r ? r.Name : '')}">
                <div class="row g-2 mt-1"><div class="col-7"><label class="form-label fw-semibold">Needed at</label><select id="dStage" class="form-select">
                    ${Object.entries(STAGE).map(([k, v]) => `<option value="${k}" ${r && r.Stage === k ? 'selected' : (!r && k === 'CLAIM' ? 'selected' : '')}>${v}</option>`).join('')}</select></div>
                <div class="col-5"><label class="form-label fw-semibold">Order</label><input id="dSort" type="number" class="form-control" value="${r ? r.SortOrder : 100}"></div></div>
                <div class="form-check mt-2"><input id="dMand" type="checkbox" class="form-check-input" ${!r || r.IsMandatory ? 'checked' : ''}><label class="form-check-label" for="dMand">Mandatory (a claim cannot be submitted without it)</label></div>
                <div class="form-check"><input id="dAct" type="checkbox" class="form-check-input" ${!r || r.IsActive ? 'checked' : ''}><label class="form-check-label" for="dAct">Active</label></div></div>`,
            preConfirm: () => { const n = $('dName').value.trim(); if (!n) { Swal.showValidationMessage('Enter the document name.'); return false; }
                return { docTypeId: r ? r.DocTypeId : null, name: n, stage: $('dStage').value, sortOrder: Number($('dSort').value) || 100, isMandatory: $('dMand').checked, isActive: $('dAct').checked }; }
        });
        if (!res.isConfirmed) return;
        const x = await Ipd.post(P.base + 'SaveDocType', res.value);
        if (!x.success) return Ipd.error(x.error);
        Ipd.toast('Saved'); load();
    }
    $('add')?.addEventListener('click', () => edit(null));
    load();
})();
