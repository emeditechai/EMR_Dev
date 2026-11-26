// OPD New Service Booking: IPD discharge follow-ups of the patient (SQLScripts/2560).
//  - opened from IPD > Discharge > "OPD booking": the patient is pre-selected and the booking closes that follow-up;
//  - a patient searched at the OPD desk: their booked follow-ups are shown, one click books against it.
// Saving the booking marks the follow-up VISITED with the OPD bill (OPDController.NewServiceBooking POST); the visit
// is booked for the follow-up date and slot (a date already passed books today).
(function () {
    'use strict';
    const box = document.getElementById('ipdFollowUpBanner');
    const hid = document.getElementById('hdnIpdFollowUpId');
    if (!box || !hid) return;

    const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const day = v => v ? new Date(v).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '';
    let rows = [];

    function render() {
        if (!rows.length) { box.classList.add('d-none'); box.innerHTML = ''; return; }
        const linked = hid.value;
        box.innerHTML = `<div class="fw-semibold mb-1"><i class="bi bi-hospital me-1"></i>IPD discharge follow-up${rows.length > 1 ? 's' : ''}</div>` +
            rows.map(f => {
                const on = String(f.FollowUpId) === String(linked);
                return `<div class="d-flex align-items-center flex-wrap gap-2 py-1">
                    <span>${esc(day(f.FollowUpDate))}${f.SlotTime ? ' at ' + esc(f.SlotTime) : ''} with <b>${esc(f.DoctorName)}</b>
                    <span class="text-muted small">(IP ${esc(f.IpNo)}${f.Notes ? ' · ' + esc(f.Notes) : ''})</span></span>
                    ${on ? '<span class="badge bg-success"><i class="bi bi-link-45deg me-1"></i>This booking closes it</span>'
                         : `<button type="button" class="btn btn-sm btn-outline-primary" data-fu="${f.FollowUpId}" data-doc="${f.DoctorId}">Book against this follow-up</button>`}
                </div>`;
            }).join('');
        box.classList.remove('d-none');
    }

    // ── appointment date / slot of the visit (follow-up or roster): the OPD visit is on that date, not the bill date ──
    const apptBox = document.getElementById('apptBox'), apptDate = document.getElementById('txtApptDate'),
          apptSch = document.getElementById('hdnApptSchedule'), apptTime = document.getElementById('hdnApptTime'),
          apptText = document.getElementById('apptSlotText');
    const iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    function clearSlot() {
        if (!apptSch) return;
        apptSch.value = ''; apptSch.disabled = true; apptTime.value = ''; apptTime.disabled = true;
        apptBox.dataset.slotDoctor = '';
        if (apptText) apptText.innerHTML = '';
    }
    function setAppointment(f) {
        if (!apptBox) return;
        const today = iso(new Date()), d = String(f.FollowUpDate || '').substring(0, 10);
        const slotAt = d && f.SlotTime ? new Date(d + 'T' + f.SlotTime) : null;
        const passed = !d || d < today || (slotAt && slotAt < new Date());
        apptBox.classList.remove('d-none');
        apptDate.disabled = false;
        apptDate.value = passed ? today : d;
        clearSlot();
        if (!passed && f.SlotTime) {
            apptSch.value = f.ScheduleId || ''; apptSch.disabled = !f.ScheduleId;
            apptTime.value = f.SlotTime; apptTime.disabled = false;
            apptBox.dataset.slotDoctor = f.DoctorId || '';
            apptText.innerHTML = `<span class="text-success"><i class="bi bi-clock me-1"></i>Slot ${esc(f.SlotTime)} (follow-up)</span>`;
        } else if (passed) {
            apptText.innerHTML = `<div class="text-warning-emphasis"><i class="bi bi-exclamation-triangle me-1"></i>The follow-up date has passed: the visit is booked for today.</div>`;
        }
    }
    function resetAppointment() {
        if (!apptBox || box.dataset.presetPatient) return;   // a follow-up / roster link keeps its date
        clearSlot();
        apptDate.value = ''; apptDate.disabled = true;
        apptBox.classList.add('d-none');
    }
    apptDate?.addEventListener('change', clearSlot);   // another date: the roster slot no longer applies
    if (window.jQuery) jQuery('#ddlDoctor').on('change', function () {
        if (apptBox?.dataset.slotDoctor && String(this.value) !== String(apptBox.dataset.slotDoctor)) clearSlot();
    });

    box.addEventListener('click', e => {
        const b = e.target.closest('[data-fu]');
        if (!b) return;
        hid.value = b.dataset.fu;
        const f = rows.find(r => String(r.FollowUpId) === b.dataset.fu) || {};
        if (window.jQuery && b.dataset.doc) jQuery('#ddlDoctor').val(b.dataset.doc).trigger('change');
        setAppointment(f);
        render();
    });

    document.addEventListener('opd:patient-loaded', async e => {
        const pid = e.detail?.patientId;
        rows = [];
        if (pid) {
            try { const r = await fetch(box.dataset.url + '?patientId=' + encodeURIComponent(pid)); rows = r.ok ? await r.json() : []; }
            catch { rows = []; }
        }
        if (!Array.isArray(rows)) rows = [];
        if (hid.value && !rows.some(f => String(f.FollowUpId) === hid.value)) hid.value = '';   // another patient's follow-up
        render();
    });

    document.addEventListener('opd:patient-cleared', () => { rows = []; hid.value = ''; resetAppointment(); render(); });

    // from IPD discharge: the patient comes pre-selected
    const preset = parseInt(box.dataset.presetPatient || '0', 10);
    if (preset > 0 && typeof window.selectPatient === 'function') window.selectPatient(preset);
})();
