// moved from Views/HospitalSettings/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
// Save: a field that breaks its limits (on any tab) is shown - its tab opened and the field focused - instead of the browser
// refusing to submit silently; fields hidden by a switch (e.g. the other loyalty type) never block the save.
(function () {
    const form = document.getElementById('hsForm'); if (!form) return;
    const box = document.getElementById('hsErrors'), list = document.getElementById('hsErrorList');
    const labelOf = el => { const l = el.id && form.querySelector(`label[for="${el.id}"]`); return (l ? l.textContent : el.name || 'A field').replace(/\s+/g, ' ').trim(); };
    const openTabOf = el => {
        const pane = el.closest('.tab-pane');
        if (pane && !pane.classList.contains('active')) {
            const btn = document.querySelector(`[data-bs-target="#${pane.id}"]`);
            if (btn) bootstrap.Tab.getOrCreateInstance(btn).show();
        }
    };
    const hidden = el => !!el.closest('.d-none');
    form.addEventListener('submit', e => {
        const bad = [...form.querySelectorAll('input, select, textarea')].filter(el => !el.disabled && !hidden(el) && !el.checkValidity());
        if (!bad.length) return;
        e.preventDefault();
        list.innerHTML = bad.map(el => `<li>${labelOf(el)}: ${el.validationMessage}</li>`).join('');
        box.classList.remove('d-none');
        // the reason also right under each field, and in a pop-up, so it is seen where the cursor goes
        form.querySelectorAll('.hs-inline-err').forEach(x => x.remove());
        form.querySelectorAll('.is-invalid').forEach(x => x.classList.remove('is-invalid'));
        bad.forEach(el => {
            el.classList.add('is-invalid');
            el.insertAdjacentHTML('afterend', `<div class="invalid-feedback d-block hs-inline-err">${el.validationMessage}</div>`);
            el.addEventListener('input', () => { el.classList.remove('is-invalid'); el.parentElement.querySelector('.hs-inline-err')?.remove(); }, { once: true });
        });
        openTabOf(bad[0]);
        setTimeout(() => { bad[0].focus(); bad[0].scrollIntoView({ block: 'center' }); }, 150);
        if (window.Swal) Swal.fire({ icon: 'warning', title: 'Settings not saved', html: `<b>${labelOf(bad[0])}</b>: ${bad[0].validationMessage}${bad.length > 1 ? `<div class="small mt-1">and ${bad.length - 1} more - see the red fields</div>` : ''}`, returnFocus: false })
            .then(() => bad[0].focus());
    });
    // jQuery Validation (_ValidationScriptsPartial) also checks this form and blocks the save without a message (e.g. its
    // "step" rule refuses 10000.00 on step 1); the check above shows every problem, so it is switched off here.
    window.addEventListener('load', () => { if (window.jQuery && $.fn.validate) { const v = $(form).data('validator') || $(form).validate(); v.settings.ignore = '*'; } });
    // after a refused save: open the tab of the first field in error
    const first = form.querySelector('.input-validation-error') || [...(list?.querySelectorAll('li[data-field]') || [])].map(li => form.querySelector(`[name="${li.dataset.field}"]`)).find(Boolean);
    if (first) { openTabOf(first); setTimeout(() => first.focus(), 200); }
})();
