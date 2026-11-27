// LAB > B2C Order List > Reschedule Booking (SQLScripts/2561).
// The menu item shows only for a booking still open to it (Is Booking Req = Yes, booking day not passed, a test without
// its result). The dialog re-reads the booking (someone may have changed it), takes a future date / time (at most 90 days
// ahead) and a reason, and saves; the server re-checks every rule, moves the booking and tells the patient.
(function () {
    'use strict';
    const me = document.currentScript;
    const infoUrl = me?.dataset.infoUrl, saveUrl = me?.dataset.saveUrl;
    const modalEl = document.getElementById('rescheduleModal');
    if (!modalEl || !infoUrl || !saveUrl || !window.bootstrap) return;

    const $ = id => document.getElementById(id);
    const form = $('frmReschedule'), dateIn = $('rsNewDate'), reasonIn = $('rsReason'), pick = $('rsReasonPick');
    const saveBtn = $('btnRescheduleSave'), blocked = $('rsBlocked'), fields = $('rsFields');
    const modal = bootstrap.Modal.getOrCreateInstance(modalEl);
    const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    let limits = { min: '', max: '', current: '' };

    function say(icon, title, text) {
        if (window.Swal) return Swal.fire({ icon, title, html: text });
        alert(title + (text ? '\n' + text.replace(/<[^>]+>/g, '') : ''));
        return Promise.resolve();
    }

    function setBusy(on) {
        saveBtn.disabled = on;
        saveBtn.innerHTML = on ? '<span class="spinner-border spinner-border-sm me-1"></span>Saving…' : '<i class="bi bi-check2-circle me-1"></i>Reschedule';
    }

    function dateError() {
        const v = dateIn.value;
        if (!v) return 'Choose the new booking date and time.';
        if (v < limits.min) return 'The new booking date and time must be in the future.';
        if (v > limits.max) return 'A booking can be moved at most 90 days ahead.';
        if (v === limits.current) return 'Choose a date or time different from the current booking.';
        return '';
    }

    function showDateError(msg) {
        $('rsNewDateErr').textContent = msg;
        dateIn.classList.toggle('is-invalid', !!msg);
    }

    async function open(btn) {
        const id = btn.dataset.laborderid;
        form.reset();
        showDateError('');
        reasonIn.classList.remove('is-invalid');
        $('rsOrderId').value = id;
        $('rsHeader').innerHTML = `<b>${esc(btn.dataset.patient)}</b> · Bill ${esc(btn.dataset.bill)}${btn.dataset.bookingNo ? ' · Booking ' + esc(btn.dataset.bookingNo) : ''}`;
        $('rsCurrent').textContent = 'Loading…';
        $('rsTests').textContent = '';
        $('rsHistoryBox').classList.add('d-none');
        blocked.classList.add('d-none');
        fields.classList.remove('d-none');
        saveBtn.classList.remove('d-none');
        setBusy(true);
        modal.show();
        try {
            const r = await fetch(infoUrl + '?labOrderId=' + encodeURIComponent(id), { headers: { 'X-Requested-With': 'XMLHttpRequest' } });
            const d = await r.json();
            if (!d.success) throw new Error(d.message || 'The booking could not be read.');
            limits = { min: d.minDate, max: d.maxDate, current: d.bookingDate };
            dateIn.min = d.minDate; dateIn.max = d.maxDate;
            $('rsExpected').value = d.bookingDate || '';
            $('rsCurrent').textContent = d.bookingText || '—';
            $('rsTests').textContent = d.totalTests ? `Results entered for ${d.enteredTests} of ${d.totalTests} test(s)` +
                (d.homeVisitStatus ? ` · home visit ${String(d.homeVisitStatus).toLowerCase().replace(/_/g, ' ')}` : '') : '';
            if (!d.canReschedule) {
                blocked.textContent = 'This booking cannot be rescheduled: ' + (d.whyNot || 'not allowed.');
                blocked.classList.remove('d-none');
                fields.classList.add('d-none');
                saveBtn.classList.add('d-none');
            }
            if (Array.isArray(d.history) && d.history.length) {
                $('rsHistory').innerHTML = d.history.map(h => `<li class="list-group-item px-0">
                    <div><b>${esc(h.from)}</b> → <b>${esc(h.to)}</b>${h.token ? ` <span class="text-muted">(token ${esc(h.token)})</span>` : ''}</div>
                    <div class="text-muted">${esc(h.reason)} · ${esc(h.by)} · ${esc(h.at)}${h.whatsApp === 'SENT' || h.email === 'SENT' ? ' · <i class="bi bi-bell-fill text-success" title="Patient informed"></i>' : ''}</div></li>`).join('');
                $('rsHistoryBox').classList.remove('d-none');
            }
        } catch (e) {
            modal.hide();
            say('error', 'Reschedule Booking', esc(e.message));
        } finally {
            setBusy(false);
        }
    }

    document.addEventListener('click', e => {
        const b = e.target.closest('.btn-reschedule-booking');
        if (b) { e.preventDefault(); open(b); }
    });

    pick?.addEventListener('change', () => {
        if (pick.value) { reasonIn.value = pick.value; reasonIn.classList.remove('is-invalid'); }
    });
    dateIn.addEventListener('change', () => showDateError(dateError()));
    reasonIn.addEventListener('input', () => reasonIn.classList.toggle('is-invalid', !reasonIn.value.trim()));

    saveBtn.addEventListener('click', async () => {
        const dErr = dateError();
        showDateError(dErr);
        const rErr = !reasonIn.value.trim();
        reasonIn.classList.toggle('is-invalid', rErr);
        if (dErr || rErr) return;

        const when = new Date(dateIn.value).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true });
        if (window.Swal) {
            const ok = await Swal.fire({ icon: 'question', title: 'Reschedule this booking?', html: `New date and time: <b>${esc(when)}</b>`,
                showCancelButton: true, confirmButtonText: 'Yes, reschedule' });
            if (!ok.isConfirmed) return;
        }
        setBusy(true);
        try {
            const r = await fetch(saveUrl, { method: 'POST', body: new FormData(form), headers: { 'X-Requested-With': 'XMLHttpRequest' } });
            const d = await r.json();
            if (!d.success) { await say('warning', 'Not rescheduled', esc(d.message)); return; }
            modal.hide();
            await say(d.notifiedOk ? 'success' : 'info', 'Booking rescheduled', `${esc(d.message)}<br/><span class="small">${esc(d.notified)}</span>`);
            location.reload();   // the list is by booking date: the order moves to its new day
        } catch {
            say('error', 'Not rescheduled', 'The booking could not be rescheduled. Please try again.');
        } finally {
            setBusy(false);
        }
    });
})();
