/* IPD > OT Schedule (Phase 8, SQLScripts/2492). Config window.OtPage = { base, patient, can: { book, cancel, patient } }.
   One column per OT with a day timeline and its bookings; book from here (any admitted patient), change / cancel a scheduled one. */
(function () {
    'use strict';
    const P = window.OtPage, E = v => Ipd.esc(v), $ = id => document.getElementById(id);
    let D = null;
    const iso = d => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    const hm = d => new Date(d).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
    const ST = { SCHEDULED: 'Scheduled', IN_OT: 'In OT', COMPLETED: 'Completed', CANCELLED: 'Cancelled' };

    async function load() {
        try {
            D = await Ipd.get(`${P.base}ScheduleData?date=${$('day').value}&otId=${$('otFilter').value}&includeCancelled=${$('showCancelled').checked}`);
            if ($('otFilter').options.length === 1) (D.ots || []).forEach(o => $('otFilter').add(new Option(o.OtName, o.OtId)));
            render();
            $('asOf').textContent = 'As of ' + new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
        } catch (e) { $('board').innerHTML = `<div class="alert alert-danger">${E(e.message)}</div>`; }
    }

    function render() {
        const ots = D.ots || [], bk = D.bookings || [], live = bk.filter(b => b.Status !== 'CANCELLED');
        const k = (c, label, val, sub) => `<div class="ipdx-kpi"><small>${label}</small><b style="color:${c}">${val}</b><span class="small text-muted">${sub}</span></div>`;
        const mins = live.reduce((a, b) => a + (new Date(b.ScheduledEnd) - new Date(b.ScheduledStart)) / 60000, 0);
        $('kpis').innerHTML = k('#1d4ed8', 'Bookings', live.length, `${ots.length} OT(s)`) + k('#b91c1c', 'In OT now', live.filter(b => b.Status === 'IN_OT').length, 'surgery under way')
            + k('#15803d', 'Completed', live.filter(b => b.Status === 'COMPLETED').length, 'today') + k('#b45309', 'Emergency', live.filter(b => b.SurgeryType === 'EMERGENCY').length, 'cases')
            + k('#6d28d9', 'Booked hours', (mins / 60).toFixed(1), ots.length ? `${Math.round(mins / (ots.length * 600) * 100)}% of 10 h per OT` : '');
        const day0 = new Date($('day').value + 'T00:00').getTime(), span = 24 * 3600000;
        $('board').innerHTML = ots.map(o => {
            const mine = bk.filter(b => b.OtId === o.OtId);
            const bars = mine.filter(b => b.Status !== 'CANCELLED').map(b => {
                const s = Math.max(0, (new Date(b.ScheduledStart) - day0) / span * 100), e = Math.min(100, (new Date(b.ScheduledEnd) - day0) / span * 100);
                return `<i class="${b.Status}" style="left:${s}%;width:${Math.max(0.8, e - s)}%" title="${hm(b.ScheduledStart)}-${hm(b.ScheduledEnd)} ${E(b.ProcedureName)}"></i>`;
            }).join('');
            return `<div class="ot-col"><div class="ot-col-head"><div><b>${E(o.OtName)}</b><div><small>${E(o.OtType || '')}${o.EmergencyAvailable ? ' · emergency' : ''}</small></div></div>
                ${P.can.book ? `<button type="button" class="btn btn-sm btn-outline-danger" data-book="${o.OtId}" title="Book this OT"><i class="bi bi-plus-lg"></i></button>` : ''}</div>
                <div class="ot-timeline">${bars}</div><div class="d-flex justify-content-between px-3 small text-muted"><span>00</span><span>06</span><span>12</span><span>18</span><span>24</span></div>
                ${mine.length ? mine.map(b => `<div class="ot-slot ${b.Status}" data-id="${b.OtBookingId}">
                    <div class="d-flex justify-content-between"><span class="tm">${hm(b.ScheduledStart)} – ${hm(b.ScheduledEnd)}</span><span class="ot-st ${b.Status}">${ST[b.Status]}</span></div>
                    <div class="pt">${E(b.PatientName)} <small class="text-muted">${E(b.AgeText || '')} ${E(b.Gender || '')}</small></div>
                    <div class="sub">${E(b.ProcedureName)}${b.Laterality && b.Laterality !== 'NA' ? ' (' + E(b.Laterality.toLowerCase()) + ')' : ''}${b.SurgeryType === 'EMERGENCY' ? ' · <b class="text-danger">emergency</b>' : ''}${b.IsUnplannedReturn ? ' · <b class="text-danger">return to OT</b>' : ''}</div>
                    <div class="sub">${E(b.SurgeonName)}${b.AnaesthetistName ? ' · ' + E(b.AnaesthetistName) : ''}${b.AnaesthesiaType ? ' (' + E(b.AnaesthesiaType) + ')' : ''}</div>
                    <div class="sub">${E(b.IpNo)} · ${E(b.WardName || '')} ${E(b.BedNumber || '')} · ${E(b.BookingNo)} · checklists ${b.ChecklistsDone}/4</div>
                    ${b.Status === 'SCHEDULED' && (P.can.book || P.can.cancel) ? `<div class="mt-1 d-flex gap-1">${P.can.book ? `<button type="button" class="btn btn-sm btn-outline-secondary py-0" data-edit="${b.OtBookingId}">Change</button>` : ''}${P.can.cancel ? `<button type="button" class="btn btn-sm btn-outline-danger py-0" data-cancel="${b.OtBookingId}">Cancel</button>` : ''}</div>` : ''}
                  </div>`).join('') : '<div class="ot-empty">No booking.</div>'}</div>`;
        }).join('') || '<div class="alert alert-light border">No active OT in this branch (Master › OT Master).</div>';
    }

    $('board').addEventListener('click', async e => {
        const t = e.target;
        const bookBtn = t.closest('[data-book]'), edit = t.closest('[data-edit]'), cancel = t.closest('[data-cancel]'), slot = t.closest('.ot-slot');
        if (bookBtn) { const d = new Date($('day').value + 'T09:00'); return IpdOtBook.open({ base: P.base, pickPatient: true, defaultOtId: Number(bookBtn.dataset.book), defaultStart: d < new Date() ? undefined : d, onSaved: load }); }
        if (edit) { const b = D.bookings.find(x => x.OtBookingId === Number(edit.dataset.edit)); return IpdOtBook.open({ base: P.base, booking: b, patientLabel: `${b.PatientName} · ${b.IpNo}`, onSaved: load }); }
        if (cancel) {
            const reason = await Ipd.reason('Cancel this OT booking?'); if (reason == null) return;
            const r = await Ipd.post(P.base + 'Cancel?bookingId=' + cancel.dataset.cancel, { reason });
            if (!r.success) return Ipd.error(r.error); Ipd.toast('OT booking cancelled'); return load();
        }
        if (slot && P.can.patient) { const b = D.bookings.find(x => x.OtBookingId === Number(slot.dataset.id)); if (b) window.location.href = P.patient + b.AdmissionId + '?tab=ot'; }
    });
    $('bookNew')?.addEventListener('click', () => IpdOtBook.open({ base: P.base, pickPatient: true, onSaved: load }));
    const shift = n => { const d = new Date($('day').value + 'T00:00'); d.setDate(d.getDate() + n); $('day').value = iso(d); load(); };
    $('prevDay').addEventListener('click', () => shift(-1)); $('nextDay').addEventListener('click', () => shift(1));
    $('today').addEventListener('click', () => { $('day').value = iso(new Date()); load(); });
    ['day', 'otFilter', 'showCancelled'].forEach(id => $(id).addEventListener('change', load));
    $('day').value = iso(new Date());
    load(); setInterval(load, 60000);
})();
