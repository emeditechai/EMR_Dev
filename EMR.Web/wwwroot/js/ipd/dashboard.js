/* IPD/Index.cshtml (IPD, SQLScripts/2422+): page script, moved out of the view so it is not compiled into EMR.Web.dll. Server values come in window.IpdPage. */
(function () {
const E = Ipd.esc, pBase = (window.IpdPage || {}).patientBase; let patients = [];
const tile = (lbl, val, sub, cls) => `<div class="col-6 col-md-4 col-xl-2"><div class="ipd-tile ${cls}"><div class="lbl">${lbl}</div><div class="val">${val}</div><div class="sub">${sub || ''}</div></div></div>`;
function renderPts() {
    const f = q.value.trim().toLowerCase();
    const list = patients.filter(p => !f || [p.PatientName, p.IpNo, p.BedNumber, p.RoomNumber, p.WardName, p.PatientCode].join(' ').toLowerCase().includes(f));
    pts.innerHTML = list.map(p => `<tr style="cursor:pointer" data-id="${p.AdmissionId}"><td><div class="fw-semibold">${p.RoomNumber ? 'Room ' + E(p.RoomNumber) + ' · ' : ''}${E(p.BedNumber || '')}</div><div class="small text-muted">${E(p.WardName || '')}</div></td>
        <td><div class="fw-semibold">${E(p.PatientName)}</div><div class="small text-muted">${E(p.AgeText)} / ${E(p.Gender || '')} · ${E(Ipd.payer(p.PayerType))}</div></td>
        <td class="font-monospace small">${E(p.IpNo)}</td><td>${E(p.ConsultantDoctorName || '')}</td><td class="text-end">${p.DayCount}</td>
        <td class="text-end num">${Ipd.money(p.BillNow)}</td><td class="text-end num ${p.BalanceDue > 0 ? 'money-due' : 'money-ok'}">${Ipd.money(Math.abs(p.BalanceDue))}${p.BalanceDue < 0 ? '<div class="small fw-normal">refundable</div>' : ''}</td></tr>`).join('')
        || '<tr><td colspan="7" class="text-center text-muted py-4">No patient admitted.</td></tr>';
}
async function load() {
    try {
        const d = await Ipd.get(window.IpdPage.dataUrl);
        const t = d.tiles || {};
        const occ = t.BedsTotal ? Math.round(100 * t.BedsOccupied / t.BedsTotal) : 0;
        tiles.innerHTML = tile('In-patients', t.InPatients ?? 0, 'admitted now', 'accent') + tile('Admitted today', t.AdmittedToday ?? 0, '', 'good')
            + tile('Discharged today', t.DischargedToday ?? 0, (t.DischargeAdvised ?? 0) + ' discharge advised', '') + tile('Bed occupancy', occ + '%', `${t.BedsOccupied ?? 0} of ${t.BedsTotal ?? 0} beds`, occ >= 90 ? 'bad' : 'warn')
            + tile('Beds available', t.BedsAvailable ?? 0, (t.BedsOther ?? 0) + ' cleaning / reserved / blocked', 'good') + tile('Advance today', Ipd.money(t.AdvanceToday), 'refunds ' + Ipd.money(t.RefundToday), '');
        wards.innerHTML = (d.wards || []).map(w => `<div class="mb-3"><div class="d-flex justify-content-between small"><span class="fw-semibold">${E(w.WardName)}</span><span>${w.Occupied}/${w.Total} occupied · <span class="text-success">${w.Available} free</span></span></div>
            <div class="occ-bar mt-1"><span style="width:${w.Total ? Math.round(100 * w.Occupied / w.Total) : 0}%"></span></div></div>`).join('') || '<div class="text-muted small">No beds in Master &gt; IPD &gt; Bed Master for this branch.</div>';
        patients = d.patients || []; renderPts();
        asOf.textContent = '· ' + new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
    } catch (e) { tiles.innerHTML = `<div class="col-12"><div class="alert alert-danger">${E(e.message)}</div></div>`; }
}
pts.addEventListener('click', e => { const tr = e.target.closest('tr[data-id]'); if (tr) location.href = pBase + tr.dataset.id; });
q.addEventListener('input', renderPts); refresh.addEventListener('click', load);
load(); setInterval(load, 120000);
})();
