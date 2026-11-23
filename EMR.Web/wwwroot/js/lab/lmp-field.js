/* 2453: LMP Date on LAB B2C (Other Information section) / B2B (patient grid) booking - visible only while Gender is Female (cleared when hidden, so another gender
   never sends one). Dates: not in the future, at most a year back, after the date of birth. The server checks the same
   (LabOrderBookingController.LmpError and usp_LabOrder_SetLmp). Gender is a select2 control that pages sometimes set
   with namespaced events (patient look-up), so its value is also watched. */
(function () {
    'use strict';
    const wrap = document.getElementById('lmpWrap'), input = document.getElementById('LmpDate'), gender = document.getElementById('ddlGender');
    if (!wrap || !input || !gender) return;
    const iso = d => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    const today = new Date(), yearBack = new Date(today); yearBack.setDate(yearBack.getDate() - 365);
    input.max = iso(today); input.min = iso(yearBack);
    let last = null;

    function sync() {
        const female = (gender.value || '') === 'Female';
        if (female === last) return;
        last = female;
        wrap.classList.toggle('d-none', !female);
        if (!female) { input.value = ''; input.classList.remove('is-invalid'); }
        // B2C keeps it in the collapsed "Other Information" section: open that section so the field is seen
        const sec = female ? wrap.closest('.collapse:not(.show)') : null;
        if (sec && window.bootstrap) bootstrap.Collapse.getOrCreateInstance(sec, { toggle: false }).show();
    }
    function check() {
        const v = input.value;
        let msg = '';
        if (v) {
            const dob = (document.getElementById('DateOfBirth') || {}).value;
            if (v > input.max) msg = 'The LMP date cannot be in the future.';
            else if (v < input.min) msg = 'The LMP date can be at most one year back.';
            else if (dob && v <= dob) msg = 'The LMP date must be after the date of birth.';
        }
        input.classList.toggle('is-invalid', !!msg);
        document.getElementById('lmpMsg').textContent = msg || 'Not in the future, at most a year back.';
        input.setCustomValidity(msg);
        return !msg;
    }
    input.addEventListener('change', check);
    input.addEventListener('input', check);
    if (window.jQuery) jQuery(gender).on('change change.select2 select2:select select2:clear', sync);
    gender.addEventListener('change', sync);
    setInterval(sync, 400);   // values set by script without an event (patient look-up, form reset)
    // a wrong date stops the submit (both the normal post and the payment flow read the form)
    const form = input.form;
    if (form) form.addEventListener('submit', e => { if (!wrap.classList.contains('d-none') && !check()) { e.preventDefault(); e.stopImmediatePropagation(); input.focus(); } }, true);
    sync();
})();
