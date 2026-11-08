/* IPD bed transfer dialog (Phase 2, SQLScripts/2431), shared by the Bed Board and the IPD Patient screen.
   Ipd.transferDialog({ admissionId, who, transferUrl, bedsUrl, onDone }) */
(function () {
    'use strict';
    const E = s => Ipd.esc(s);
    let modal, state = {};
    function build() {
        if (modal) return;
        const div = document.createElement('div');
        div.innerHTML = `<div class="modal fade" id="ipdTransferModal" tabindex="-1" aria-hidden="true"><div class="modal-dialog modal-lg modal-dialog-scrollable"><div class="modal-content">
            <div class="modal-header"><h6 class="modal-title fw-bold"><i class="bi bi-arrow-left-right me-1"></i>Transfer <span data-x="who"></span></h6><button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button></div>
            <div class="modal-body">
                <div class="row g-2 mb-2">
                    <div class="col-md-5"><label class="form-label small fw-semibold" for="ipdTrReason">Reason</label>
                        <input id="ipdTrReason" class="form-control" list="ipdTrReasons" maxlength="300" placeholder="Why the patient moves" />
                        <datalist id="ipdTrReasons"><option>Needs ICU care</option><option>Step-down from ICU</option><option>Patient / family request (room upgrade)</option><option>Room downgrade</option><option>Isolation needed</option><option>Gender / ward allocation</option><option>Bed maintenance</option></datalist></div>
                    <div class="col-md-4"><label class="form-label small fw-semibold" for="ipdTrAt">Transfer time</label><input type="datetime-local" id="ipdTrAt" class="form-control" /></div>
                    <div class="col-md-3 d-flex align-items-end"><div class="form-check"><input class="form-check-input" type="checkbox" id="ipdTrDept" /><label class="form-check-label small" for="ipdTrDept">Department = new ward's</label></div></div>
                </div>
                <div class="d-flex gap-2 align-items-center mb-2 flex-wrap"><input id="ipdTrFind" class="form-control form-control-sm" style="max-width:220px" placeholder="Find bed / ward" />
                    <div class="form-check form-switch small mb-0"><input class="form-check-input" type="checkbox" id="ipdTrFree" checked /><label class="form-check-label" for="ipdTrFree">Free beds only</label></div>
                    <span class="small text-muted ms-auto">Bed charges follow the bed held at the end of each day.</span></div>
                <div data-x="beds"></div>
            </div>
            <div class="modal-footer"><span class="me-auto small" data-x="sel"></span><button type="button" class="btn btn-light border" data-bs-dismiss="modal">Close</button><button type="button" class="btn btn-primary" data-x="save" disabled>Transfer</button></div>
        </div></div></div>`;
        document.body.appendChild(div.firstElementChild);
        modal = document.getElementById('ipdTransferModal');
        const q = x => modal.querySelector(`[data-x="${x}"]`);
        ['ipdTrFind', 'ipdTrFree'].forEach(id => document.getElementById(id).addEventListener('input', render));
        document.getElementById('ipdTrFree').addEventListener('change', render);
        q('beds').addEventListener('click', e => {
            const t = e.target.closest('.bed-tile'); if (!t || t.disabled) return;
            state.bed = state.beds.find(b => b.BedId === Number(t.dataset.bed)); render();
        });
        q('save').addEventListener('click', save);
    }
    function render() {
        const q = x => modal.querySelector(`[data-x="${x}"]`);
        const f = document.getElementById('ipdTrFind').value.trim().toLowerCase(), free = document.getElementById('ipdTrFree').checked;
        const list = (state.beds || []).filter(b => (!free || b.Selectable || b.Status === 'Current') && (!f || [b.BedNumber, b.WardName, b.RoomNumber, b.BedCategoryName].join(' ').toLowerCase().includes(f)));
        const groups = {};
        list.forEach(b => (groups[b.WardId] = groups[b.WardId] || { name: b.WardName, dept: b.WardDepartment, gender: b.WardGender, beds: [] }).beds.push(b));
        q('beds').innerHTML = Object.values(groups).map(g => `<div class="bed-ward"><div class="bed-ward-title">${E(g.name)} <span class="ipd-pill muted">${E(g.dept || '')}</span>${g.gender && !/unisex/i.test(g.gender) ? `<span class="ipd-pill info">${E(g.gender)}</span>` : ''}</div>
            <div class="bed-grid">${g.beds.map(b => {
                const st = b.Status === 'Current' ? 'Occupied' : b.Status, sel = state.bed && state.bed.BedId === b.BedId;
                return `<button type="button" class="bed-tile ${E(st)} ${sel ? 'selected' : ''}" data-bed="${b.BedId}" ${b.Selectable ? '' : 'disabled'}>
                    <div class="bn">${E(b.BedNumber)} ${b.IsIcu ? '<span class="ipd-pill alert">ICU</span>' : ''}${b.Status === 'Current' ? '<span class="ipd-pill info">current</span>' : ''}</div>
                    <div class="text-muted">${E(b.BedCategoryName)} · ${E(b.RoomNumber)}</div>
                    <div>${b.Selectable ? (b.NoTariff ? '<span class="text-danger">No rate</span>' : Ipd.money(b.DailyRate) + '/day') : E(b.Status)}</div></button>`;
            }).join('')}</div></div>`).join('') || '<div class="text-muted small">No free bed matches.</div>';
        q('sel').innerHTML = state.bed ? `To <b>${E(state.bed.BedNumber)}</b> · ${E(state.bed.WardName)} · ${E(state.bed.BedCategoryName)}${state.bed.NoTariff ? '' : ' · ' + Ipd.money(state.bed.DailyRate) + '/day'}` : 'Choose the new bed';
        q('save').disabled = !state.bed;
    }
    async function save() {
        const reason = document.getElementById('ipdTrReason').value.trim();
        if (!reason) { Ipd.error('Enter the reason for the transfer.'); return; }
        const btn = modal.querySelector('[data-x="save"]'); btn.disabled = true;
        const r = await Ipd.post(state.transferUrl + '?admissionId=' + state.admissionId, {
            ToBedId: state.bed.BedId, TransferAt: document.getElementById('ipdTrAt').value || null, Reason: reason, UpdateDepartment: document.getElementById('ipdTrDept').checked });
        btn.disabled = false;
        if (!r.success) { Ipd.error(r.error); return; }
        bootstrap.Modal.getInstance(modal).hide();
        Ipd.toast('Transferred to ' + (r.data.BedNumber || 'the new bed'));
        state.onDone && state.onDone(r.data);
    }
    Ipd.transferDialog = async function (opt) {
        build();
        state = Object.assign({}, opt, { bed: null, beds: [] });
        modal.querySelector('[data-x="who"]').textContent = opt.who || '';
        document.getElementById('ipdTrReason').value = ''; document.getElementById('ipdTrAt').value = Ipd.local(); document.getElementById('ipdTrDept').checked = false;
        document.getElementById('ipdTrFind').value = '';
        bootstrap.Modal.getOrCreateInstance(modal).show();
        modal.querySelector('[data-x="beds"]').innerHTML = '<div class="text-muted small">Loading beds…</div>';
        try { state.beds = await Ipd.get(opt.bedsUrl + '?admissionId=' + opt.admissionId) || []; render(); }
        catch (e) { modal.querySelector('[data-x="beds"]').innerHTML = `<div class="text-danger small">${E(e.message)}</div>`; }
    };
})();
