/* IPD > Bed Board (Phase 2, SQLScripts/2431): live beds, side panel actions, reservations, housekeeping, census. */
(function () {
    'use strict';
    const C = window.IpdPage || {}, base = C.base, can = C.can || {}, E = Ipd.esc, $id = id => document.getElementById(id);
    let D = { beds: [], staff: [], reservations: [], cleaning: [] }, current = null, timer;
    const statusColor = { Available: '#16a34a', Occupied: '#dc2626', Reserved: '#d97706', Cleaning: '#0891b2', Blocked: '#64748b', Maintenance: '#64748b' };
    const mins = m => m >= 60 ? Math.floor(m / 60) + 'h ' + (m % 60) + 'm' : m + 'm';

    async function load() {
        try {
            D = await Ipd.get(base + 'BoardData');
            ['beds', 'staff', 'reservations', 'cleaning'].forEach(k => { D[k] = D[k] || []; });
            filters(); kpis(); render(); reservations(); housekeeping();
            $id('asOf').textContent = '· as of ' + new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
            if (current) { const b = D.beds.find(x => x.BedId === current); if (b && $id('bedPanel').classList.contains('show')) panel(b); }
        } catch (e) { $id('board').innerHTML = `<div class="alert alert-danger">${E(e.message)}</div>`; }
    }

    function kpis() {
        const n = s => D.beds.filter(b => b.Status === s).length, total = D.beds.length, occ = n('Occupied');
        const k = (l, v, sub, cls) => `<div class="ipdx-kpi ${cls || ''}"><small>${l}</small><b class="num">${v}</b><span>${sub || ''}</span></div>`;
        const overdue = D.cleaning.filter(c => c.Status !== 'DONE' && c.Overdue).length;
        $id('kpis').innerHTML = k('Total beds', total, 'active') + k('Occupied', occ, '', occ ? 'bad' : '') + k('Available', n('Available'), 'ready to admit', 'good')
            + k('Reserved', n('Reserved'), 'planned admissions') + k('Cleaning', n('Cleaning'), overdue ? overdue + ' over SLA' : 'housekeeping', overdue ? 'bad' : '')
            + k('Blocked', n('Blocked') + n('Maintenance'), 'out of use') + k('Occupancy', total ? Math.round(100 * occ / total) + '%' : '—', 'occupied / total', 'accent');
        const ra = D.reservations.filter(r => r.Status === 'ACTIVE').length, ho = D.cleaning.filter(c => c.Status !== 'DONE' && c.Status !== 'CANCELLED').length;
        $id('resCount').textContent = ra || ''; $id('hkCount').textContent = ho || '';
    }

    function fillSelect(id, pairs) {
        const el = $id(id), keep = el.value;
        el.innerHTML = '<option value="">All</option>' + pairs.map(([v, t]) => `<option value="${E(v)}">${E(t)}</option>`).join('');
        el.value = pairs.some(([v]) => String(v) === keep) ? keep : '';
    }
    function filters() {
        const uniq = (list, k, t) => [...new Map(list.map(b => [b[k], b[t]])).entries()].filter(([v]) => v != null);
        fillSelect('fBuilding', uniq(D.beds, 'BuildingId', 'BuildingName'));
        const b1 = D.beds.filter(b => !$id('fBuilding').value || String(b.BuildingId) === $id('fBuilding').value);
        fillSelect('fFloor', uniq(b1, 'FloorId', 'FloorName'));
        const b2 = b1.filter(b => !$id('fFloor').value || String(b.FloorId) === $id('fFloor').value);
        fillSelect('fWard', uniq(b2, 'WardId', 'WardName'));
    }
    function visible() {
        const bl = $id('fBuilding').value, fl = $id('fFloor').value, w = $id('fWard').value, st = $id('fStatus').value, q = $id('fSearch').value.trim().toLowerCase();
        return D.beds.filter(b => (!bl || String(b.BuildingId) === bl) && (!fl || String(b.FloorId) === fl) && (!w || String(b.WardId) === w) && (!st || b.Status === st)
            && (!q || [b.BedNumber, b.PatientName, b.IpNo, b.PatientCode, b.ResPatientName, b.WardName].join(' ').toLowerCase().includes(q)));
    }

    function tile(b) {
        let body = '';
        if (b.Status === 'Occupied') body = `<div class="fw-semibold text-truncate">${E(b.PatientName)}</div><div class="text-muted text-truncate">${E(b.AgeText)}/${E((b.Gender || '').charAt(0))} · Day ${b.DayCount} · ${E(b.ConsultantName || '')}</div>
            <div class="d-flex justify-content-between"><span class="font-monospace small">${E(b.IpNo)}</span>${Number(b.BalanceDue) > 0 ? `<span class="money-due small">${Ipd.money(b.BalanceDue)}</span>` : ''}</div>`;
        else if (b.Status === 'Reserved') body = `<div class="fw-semibold text-truncate">${E(b.ResPatientName || 'Reserved')}</div><div class="text-muted">${b.ExpectedAdmitAt ? 'Expected ' + Ipd.dt(b.ExpectedAdmitAt) : E(b.StatusReason || '')}</div>`;
        else if (b.Status === 'Cleaning') {
            const over = b.CleaningMinutes > b.SlaMinutes;
            body = `<div>${b.CleaningStatus === 'IN_PROGRESS' ? 'Cleaning in progress' : 'Waiting for housekeeping'}</div><div class="${over ? 'text-danger fw-semibold' : 'text-muted'}">${b.CleaningMinutes != null ? mins(b.CleaningMinutes) + ' / SLA ' + b.SlaMinutes + 'm' : ''}</div>`;
        }
        else if (b.Status === 'Available') body = `<div class="text-success fw-semibold">Ready</div><div class="text-muted">${E(b.BedCategoryName)}</div>`;
        else body = `<div class="text-muted text-truncate">${E(b.StatusReason || b.Status)}</div>`;
        const flags = (b.IsIcu ? '<span class="ipd-pill alert">ICU</span>' : '') + (b.IsIsolation ? '<span class="ipd-pill warn">ISO</span>' : '') + (b.IsMlc ? '<span class="ipd-pill alert">MLC</span>' : '')
            + (b.KnownAllergies ? '<span class="ipd-pill alert" title="' + E(b.KnownAllergies) + '">ALG</span>' : '');
        return `<button type="button" class="bed-tile ${E(b.Status)}" data-bed="${b.BedId}" style="border-left-color:${statusColor[b.Status] || '#94a3b8'};cursor:pointer;min-height:96px">
            <div class="d-flex justify-content-between align-items-start gap-1"><span class="bn">${E(b.BedNumber)}</span><span class="d-flex gap-1">${flags}</span></div>
            <div class="small text-muted mb-1">${E(b.RoomNumber)} · ${E(b.BedCategoryName)}</div>${body}</button>`;
    }
    function render() {
        const list = visible(), groups = {};
        list.forEach(b => (groups[b.WardId] = groups[b.WardId] || { w: b, beds: [] }).beds.push(b));
        $id('board').innerHTML = Object.values(groups).map(g => {
            const t = g.beds.length, o = g.beds.filter(b => b.Status === 'Occupied').length, a = g.beds.filter(b => b.Status === 'Available').length;
            return `<div class="ipdx-card p-3 mb-3"><div class="d-flex justify-content-between align-items-center mb-2 flex-wrap gap-2">
                <div><span class="fw-bold">${E(g.w.WardName)}</span> <span class="ipd-pill muted">${E(g.w.WardType || '')}</span> ${g.w.WardGender && !/unisex/i.test(g.w.WardGender) ? `<span class="ipd-pill info">${E(g.w.WardGender)}</span>` : ''}
                    <span class="small text-muted ms-1">${E(g.w.WardDepartment || '')} · ${E(g.w.FloorName || '')} · ${E(g.w.BuildingName || '')}</span></div>
                <div class="small"><b>${o}</b>/${t} occupied · <span class="text-success fw-semibold">${a} free</span></div></div>
                <div class="occ-bar mb-2"><span style="width:${t ? Math.round(100 * o / t) : 0}%"></span></div>
                <div class="bed-grid" style="grid-template-columns:repeat(auto-fill, minmax(190px, 1fr))">${g.beds.map(tile).join('')}</div></div>`;
        }).join('') || '<div class="ipdx-empty"><i class="bi bi-grid-3x3-gap"></i>No bed matches the filters.</div>';
    }

    // ── side panel ──
    function act(label, cls, fn, icon) { return { label, cls, fn, icon }; }
    function panel(b) {
        current = b.BedId;
        $id('bpTitle').innerHTML = `${E(b.BedNumber)} <span class="ipd-pill" style="background:${statusColor[b.Status]}22;color:${statusColor[b.Status]}">${E(b.Status)}</span>`;
        $id('bpSub').textContent = `${b.WardName} · Room ${b.RoomNumber} · ${b.BedCategoryName}${b.FloorName ? ' · ' + b.FloorName : ''}`;
        const kv = (k, v) => v ? `<dt>${k}</dt><dd>${v}</dd>` : '';
        let html = '<dl class="kv mb-3">', acts = [];
        if (b.Status === 'Occupied') {
            html += kv('Patient', `<b>${E(b.PatientName)}</b><div class="small text-muted">${E(b.PatientCode)} · ${E(b.AgeText)} / ${E(b.Gender || '')}</div>`) + kv('IP No.', `<span class="font-monospace">${E(b.IpNo)}</span>`)
                + kv('Admitted', Ipd.dt(b.AdmissionAt) + ` · Day ${b.DayCount}`) + kv('In this bed since', Ipd.dt(b.OccupiedSince)) + kv('Consultant', E(b.ConsultantName))
                + kv('Payer', E(Ipd.payer(b.PayerType))) + kv('Bill / advance', `${Ipd.money(b.BillNow)} / ${Ipd.money(b.NetAdvance)}`)
                + kv('Balance', `<span class="${Number(b.BalanceDue) > 0 ? 'money-due' : 'money-ok'}">${Ipd.money(Math.abs(b.BalanceDue))}${Number(b.BalanceDue) < 0 ? ' refundable' : ''}</span>`)
                + kv('Expected discharge', Ipd.dt(b.ExpectedDischargeAt)) + kv('Allergies', b.KnownAllergies ? `<span class="text-danger">${E(b.KnownAllergies)}</span>` : '');
            acts.push(act('Open patient', 'btn-primary', () => location.href = C.adm + 'Patient/' + b.AdmissionId, 'bi-person-badge'));
            acts.push(act('Current bill', 'btn-light border', () => location.href = C.est + 'Patient/' + b.AdmissionId, 'bi-calculator'));
            if (can.transfer) acts.push(act('Transfer / ICU shift', 'btn-warning', () => Ipd.transferDialog({ admissionId: b.AdmissionId, who: b.PatientName + ' (' + b.BedNumber + ')', transferUrl: base + 'Transfer', bedsUrl: base + 'TransferBeds', onDone: load }), 'bi-arrow-left-right'));
            if (can.swap) acts.push(act('Swap with another patient', 'btn-light border', () => swap(b), 'bi-shuffle'));
        } else if (b.Status === 'Available') {
            html += kv('Status', 'Clean and ready') + kv('Since', Ipd.dt(b.StatusSince)) + kv('Note', E(b.StatusReason));
            acts.push(act('Admit to this bed', 'btn-success', () => location.href = C.adm + 'New?bedId=' + b.BedId, 'bi-person-plus'));
            if (can.reserve) acts.push(act('Reserve', 'btn-warning', () => reserve(b), 'bi-calendar-check'));
            if (can.block) { acts.push(act('Block', 'btn-light border', () => setStatus(b, 'Blocked'), 'bi-slash-circle')); acts.push(act('Under maintenance', 'btn-light border', () => setStatus(b, 'Maintenance'), 'bi-tools')); }
        } else if (b.Status === 'Reserved') {
            html += kv('Reserved for', `<b>${E(b.ResPatientName || '')}</b> ${E(b.ResPhone || '')}`) + kv('Expected', Ipd.dt(b.ExpectedAdmitAt)) + kv('Held until', Ipd.dt(b.ReservedUntil)) + kv('Note', E(b.StatusReason));
            acts.push(act('Admit (reserved patient)', 'btn-success', () => location.href = C.adm + 'New?bedId=' + b.BedId + (b.ResPatientId ? '&patientId=' + b.ResPatientId : ''), 'bi-person-plus'));
            if (can.release && b.ReservationId) acts.push(act('Release reservation', 'btn-light border', () => release(b.ReservationId), 'bi-x-circle'));
            else if (!b.ReservationId && can.block) acts.push(act('Make available (no reservation on record)', 'btn-light border', () => setStatus(b, 'Available'), 'bi-check2-circle'));
        } else if (b.Status === 'Cleaning') {
            html += kv('Cleaning', E(b.CleaningType || 'Bed cleaning')) + kv('Requested', Ipd.dt(b.CleaningRequestedAt)) + kv('Waiting', b.CleaningMinutes != null ? mins(b.CleaningMinutes) + ' (SLA ' + b.SlaMinutes + ' min)' : '')
                + kv('Staff', E(b.CleaningStaff)) + kv('Started', Ipd.dt(b.CleaningStartedAt));
            if (can.housekeeping && b.CleaningTaskId) {
                if (b.CleaningStatus !== 'IN_PROGRESS') acts.push(act('Start cleaning', 'btn-info', () => cleaning(b.CleaningTaskId, 'START'), 'bi-play'));
                acts.push(act('Cleaning done · bed ready', 'btn-success', () => cleaning(b.CleaningTaskId, 'DONE'), 'bi-check2-circle'));
            } else if (can.block) acts.push(act('Make available', 'btn-success', () => setStatus(b, 'Available'), 'bi-check2-circle'));
        } else {
            html += kv('Reason', E(b.StatusReason)) + kv('Since', Ipd.dt(b.StatusSince));
            if (can.block) acts.push(act('Make available', 'btn-success', () => setStatus(b, 'Available'), 'bi-check2-circle'));
        }
        html += '</dl><div class="d-grid gap-2 mb-3" id="bpActs"></div><div class="fw-semibold small text-uppercase text-muted mb-1">History</div><div id="bpHist" class="small text-muted">Loading…</div>';
        $id('bpBody').innerHTML = html;
        const box = $id('bpActs');
        acts.forEach(a => { const btn = document.createElement('button'); btn.type = 'button'; btn.className = 'btn btn-sm ' + a.cls; btn.innerHTML = `<i class="bi ${a.icon} me-1"></i>${E(a.label)}`; btn.addEventListener('click', a.fn); box.appendChild(btn); });
        if (!acts.length) box.innerHTML = '<div class="small text-muted">No action for your role.</div>';
        bootstrap.Offcanvas.getOrCreateInstance($id('bedPanel')).show();
        history(b.BedId);
    }
    async function history(bedId) {
        try {
            const h = await Ipd.get(base + 'History?bedId=' + bedId);
            const rows = (h.log || []).slice(0, 15).map(l => `<div class="d-flex gap-2 border-bottom py-1"><span class="text-nowrap">${Ipd.dt(l.CreatedDate)}</span><span><b>${E(l.ToStatus)}</b> ${E(l.Reason || '')}${l.IpNo ? ' · ' + E(l.IpNo) : ''}<div class="text-muted">${E(l.CreatedByName || '')}</div></span></div>`).join('');
            const pts = (h.patients || []).slice(0, 8).map(p => `<div class="py-1 border-bottom"><span class="font-monospace">${E(p.IpNo)}</span> ${E(p.PatientName)}<div class="text-muted">${Ipd.dt(p.FromAt)} → ${p.ToAt ? Ipd.dt(p.ToAt) : 'now'} · ${E(p.MoveType)}${p.EndType ? ' / ' + E(p.EndType) : ''}</div></div>`).join('');
            $id('bpHist').innerHTML = (rows || '<div>No status change recorded yet.</div>') + (pts ? '<div class="fw-semibold small text-uppercase text-muted mt-3 mb-1">Patients in this bed</div>' + pts : '');
        } catch (e) { $id('bpHist').textContent = e.message; }
    }
    $id('board').addEventListener('click', e => { const t = e.target.closest('.bed-tile'); if (!t) return; const b = D.beds.find(x => x.BedId === Number(t.dataset.bed)); if (b) panel(b); });

    async function done(r, msg) { if (!r.success) { Ipd.error(r.error); return false; } Ipd.toast(msg); await load(); return true; }
    async function setStatus(b, status) {
        let reason = null;
        if (status !== 'Available') { reason = await Ipd.reason(status === 'Blocked' ? 'Block bed ' + b.BedNumber : 'Bed ' + b.BedNumber + ' under maintenance', 'Reason'); if (!reason) return; }
        else if (!await Ipd.confirm('Make bed ' + b.BedNumber + ' available?', b.Status === 'Cleaning' ? 'The open cleaning job is closed.' : '', 'Make available')) return;
        await done(await Ipd.post(base + 'SetStatus', { BedId: b.BedId, Status: status, Reason: reason }), 'Bed ' + b.BedNumber + ' ' + status.toLowerCase());
    }
    async function release(id) {
        const reason = await Ipd.reason('Release the reservation', 'Reason'); if (!reason) return;
        await done(await Ipd.post(base + 'ReleaseReservation', { ReservationId: id, Reason: reason }), 'Reservation released');
    }
    async function cleaning(id, action) {
        let staff = null;
        if (D.staff.length) {
            const opts = {}; D.staff.forEach(s => { opts[s.UserId] = s.Name; });
            const r = await Swal.fire({ title: action === 'START' ? 'Start cleaning' : 'Cleaning done', input: 'select', inputOptions: opts, inputPlaceholder: 'Housekeeping staff (optional)', showCancelButton: true, confirmButtonText: action === 'START' ? 'Start' : 'Bed ready' });
            if (!r.isConfirmed) return; staff = Number(r.value) || null;
        } else if (!await Ipd.confirm(action === 'START' ? 'Start cleaning?' : 'Cleaning done?', '', 'Yes')) return;
        await done(await Ipd.post(base + 'Cleaning', { CleaningTaskId: id, Action: action, StaffUserId: staff }), action === 'START' ? 'Cleaning started' : 'Bed is ready');
    }
    async function swap(b) {
        const others = D.beds.filter(x => x.Status === 'Occupied' && x.AdmissionId && x.AdmissionId !== b.AdmissionId);
        if (!others.length) { Ipd.error('No other admitted patient to swap with.'); return; }
        const opts = {}; others.forEach(o => { opts[o.AdmissionId] = `${o.BedNumber} · ${o.PatientName} (${o.WardName})`; });
        const r = await Swal.fire({ title: 'Swap ' + b.BedNumber + ' with', input: 'select', inputOptions: opts, showCancelButton: true, confirmButtonText: 'Next' });
        if (!r.isConfirmed) return;
        const reason = await Ipd.reason('Reason for the swap', 'Reason'); if (!reason) return;
        await done(await Ipd.post(base + 'Swap', { AdmissionId: b.AdmissionId, OtherAdmissionId: Number(r.value), Reason: reason }), 'Beds swapped');
    }
    let resBed = null;
    function reserve(b) {
        resBed = b;
        $id('rvBed').textContent = b.BedNumber + ' · ' + b.WardName;
        ['rvSearch', 'rvName', 'rvPhone', 'rvHold', 'rvRemarks', 'rvPatientId'].forEach(id => $id(id).value = '');
        const d = new Date(); d.setHours(d.getHours() + 2, 0, 0, 0); $id('rvAt').value = Ipd.local(d);
        bootstrap.Modal.getOrCreateInstance($id('reserveModal')).show();
    }
    let st;
    $id('rvSearch').addEventListener('input', () => {
        clearTimeout(st); const v = $id('rvSearch').value.trim(); const box = $id('rvSug'); $id('rvPatientId').value = '';
        if (v.length < 3) { box.style.display = 'none'; return; }
        st = setTimeout(async () => {
            const url = /^\d+$/.test(v) ? C.adm + 'SearchPatientByPhone?phone=' + encodeURIComponent(v) : C.adm + 'SearchPatientByName?name=' + encodeURIComponent(v);
            const list = await Ipd.getRaw(url) || [];
            box.innerHTML = list.map(p => `<button type="button" class="list-group-item list-group-item-action sug py-2 px-3" data-id="${p.patientId}" data-name="${E(p.fullName)}" data-phone="${E(p.phoneNumber || '')}"><b>${E(p.fullName)}</b> <span class="badge text-bg-info text-dark">${E(p.patientCode)}</span><div class="small text-muted">${E(p.phoneNumber || '')}</div></button>`).join('') || '<div class="list-group-item small text-muted">No patient: type the name and mobile.</div>';
            box.style.display = 'block';
        }, 260);
    });
    $id('rvSug').addEventListener('click', e => { const s = e.target.closest('[data-id]'); if (!s) return; $id('rvPatientId').value = s.dataset.id; $id('rvName').value = s.dataset.name; $id('rvPhone').value = s.dataset.phone; $id('rvSearch').value = s.dataset.name; $id('rvSug').style.display = 'none'; });
    $id('rvSave').addEventListener('click', async () => {
        if (!$id('rvName').value.trim()) { Ipd.error('Enter the patient name.'); return; }
        const r = await Ipd.post(base + 'Reserve', { BedId: resBed.BedId, PatientId: Number($id('rvPatientId').value) || null, PatientName: $id('rvName').value.trim(), Phone: $id('rvPhone').value.trim(),
            ExpectedAdmitAt: $id('rvAt').value, HoldHours: Number($id('rvHold').value) || null, Remarks: $id('rvRemarks').value.trim() });
        if (await done(r, 'Bed ' + resBed.BedNumber + ' reserved')) bootstrap.Modal.getInstance($id('reserveModal')).hide();
    });

    // ── reservations / housekeeping / census tabs ──
    function reservations() {
        const label = { ACTIVE: '<span class="ipd-pill warn">Active</span>', USED: '<span class="ipd-pill st-ADMITTED">Admitted</span>', RELEASED: '<span class="ipd-pill muted">Released</span>', EXPIRED: '<span class="ipd-pill alert">Expired</span>' };
        $id('resRows').innerHTML = D.reservations.map(r => `<tr><td class="fw-semibold">${E(r.BedNumber)}<div class="small text-muted">${E(r.WardName)}</div></td><td>${E(r.PatientName)}<div class="small text-muted">${E(r.Phone || '')}</div></td>
            <td>${Ipd.dt(r.ExpectedAdmitAt)}</td><td>${Ipd.dt(r.ReservedUntil)}</td><td>${E(r.DoctorName || '')}</td><td>${label[r.Status] || E(r.Status)}${r.IpNo ? ' <span class="font-monospace small">' + E(r.IpNo) + '</span>' : ''}${r.CloseReason ? '<div class="small text-muted">' + E(r.CloseReason) + '</div>' : ''}</td>
            <td class="small text-muted">${E(r.CreatedByName || '')}</td><td class="text-end">${r.Status === 'ACTIVE' && can.release ? `<button type="button" class="btn btn-sm btn-light border" data-release="${r.ReservationId}">Release</button>` : ''}</td></tr>`).join('')
            || '<tr><td colspan="8"><div class="ipdx-empty"><i class="bi bi-calendar-check"></i>No reservation. Reserve an available bed from the board.</div></td></tr>';
    }
    $id('resRows').addEventListener('click', e => { const b = e.target.closest('[data-release]'); if (b) release(Number(b.dataset.release)); });
    function housekeeping() {
        const label = { OPEN: '<span class="ipd-pill warn">Waiting</span>', IN_PROGRESS: '<span class="ipd-pill info">In progress</span>', DONE: '<span class="ipd-pill st-ADMITTED">Done</span>', CANCELLED: '<span class="ipd-pill muted">Cancelled</span>' };
        $id('hkRows').innerHTML = D.cleaning.map(c => `<tr><td class="fw-semibold">${E(c.BedNumber)}<div class="small text-muted">${E(c.WardName)} · ${E(c.RoomNumber)}</div></td><td>${E((c.Reason || '').toLowerCase())}</td><td>${E(c.CleaningType || '')}</td>
            <td>${Ipd.dt(c.RequestedAt)}</td><td class="${c.Overdue ? 'text-danger fw-semibold' : ''}">${mins(c.Minutes)} / ${c.SlaMinutes}m</td><td>${E(c.StaffName || c.CompletedByName || '')}</td><td>${label[c.Status] || E(c.Status)}</td>
            <td class="text-end text-nowrap">${(c.Status === 'OPEN' || c.Status === 'IN_PROGRESS') && can.housekeeping ? `${c.Status === 'OPEN' ? `<button type="button" class="btn btn-sm btn-light border" data-clean="${c.CleaningTaskId}" data-act="START">Start</button>` : ''} <button type="button" class="btn btn-sm btn-success" data-clean="${c.CleaningTaskId}" data-act="DONE">Done</button>` : ''}</td></tr>`).join('')
            || '<tr><td colspan="8"><div class="ipdx-empty"><i class="bi bi-bucket"></i>No bed waiting for cleaning.</div></td></tr>';
    }
    $id('hkRows').addEventListener('click', e => { const b = e.target.closest('[data-clean]'); if (b) cleaning(Number(b.dataset.clean), b.dataset.act); });
    async function census() {
        try {
            const rows = await Ipd.get(base + 'CensusData?fromDate=' + $id('cFrom').value + '&toDate=' + $id('cTo').value) || [];
            const byDate = {}; rows.forEach(r => (byDate[r.CensusDate] = byDate[r.CensusDate] || []).push(r));
            $id('cRows').innerHTML = Object.entries(byDate).map(([d, list]) => {
                const t = k => list.reduce((s, r) => s + Number(r[k] || 0), 0), beds = t('Beds'), occ = t('Occupied');
                return list.map(r => `<tr><td>${Ipd.date(d)}</td><td>${E(r.WardName)}</td><td class="text-end">${r.Beds}</td><td class="text-end">${r.Occupied}</td><td class="text-end">${r.Beds ? Math.round(100 * r.Occupied / r.Beds) + '%' : '—'}</td>
                    <td class="text-end">${r.Admissions}</td><td class="text-end">${r.Discharges}</td><td class="text-end">${r.TransfersIn}</td><td class="text-end">${r.TransfersOut}</td></tr>`).join('')
                    + `<tr class="table-light fw-semibold"><td>${Ipd.date(d)}</td><td>All wards</td><td class="text-end">${beds}</td><td class="text-end">${occ}</td><td class="text-end">${beds ? Math.round(100 * occ / beds) + '%' : '—'}</td>
                    <td class="text-end">${t('Admissions')}</td><td class="text-end">${t('Discharges')}</td><td class="text-end">${t('TransfersIn')}</td><td class="text-end">${t('TransfersOut')}</td></tr>`;
            }).join('') || '<tr><td colspan="9" class="text-center text-muted py-4">No ward.</td></tr>';
        } catch (e) { $id('cRows').innerHTML = `<tr><td colspan="9" class="text-danger">${E(e.message)}</td></tr>`; }
    }
    const today = new Date(), wk = new Date(); wk.setDate(today.getDate() - 6);
    $id('cTo').value = Ipd.local(today).substring(0, 10); $id('cFrom').value = Ipd.local(wk).substring(0, 10);
    $id('cLoad').addEventListener('click', census); $id('tabCensus').addEventListener('shown.bs.tab', census);

    ['fBuilding', 'fFloor'].forEach(id => $id(id).addEventListener('change', () => { filters(); render(); }));
    ['fWard', 'fStatus'].forEach(id => $id(id).addEventListener('change', render));
    $id('fSearch').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(render, 200); });
    $id('refresh').addEventListener('click', load);
    load(); setInterval(load, 60000);
})();
