/* Doctor Master > Is Suspended (SQLScripts/2484): when a doctor is chosen on a booking screen - referral doctor (LAB B2C /
   B2B: #ddlReferralDoctor) or consulting doctor (OPD registration / service booking: #ddlDoctor) - a suspended doctor is
   refused with the reason and the choice is cleared. The server refuses it again on save. An OPD visit being edited keeps
   its own doctor (OPDServiceId). Nothing else on the page is changed. */
(function () {
    'use strict';
    const url = document.currentScript && document.currentScript.dataset.url;
    if (!url) return;

    function wire(selector, role) {
        const el = document.querySelector(selector);
        if (!el) return;
        const $el = window.jQuery ? window.jQuery(el) : null;
        let clearing = false, lastChecked = null;
        async function check() {
            const id = el.value;
            if (clearing || !id || id === lastChecked) return;
            lastChecked = id;
            const keep = document.querySelector('input[name="OPDServiceId"]')?.value || '';
            let r = null;
            try {
                const res = await fetch(`${url}?id=${encodeURIComponent(id)}&role=${role}&keepOpdServiceId=${encodeURIComponent(keep)}`,
                    { headers: { 'X-Requested-With': 'XMLHttpRequest' } });
                r = res.ok ? await res.json() : null;
            } catch { r = null; }        // no answer: the server still checks on save
            if (!r || !r.suspended || el.value !== id) return;
            if (window.Swal) await Swal.fire({ icon: 'warning', title: 'Doctor suspended', text: r.message, confirmButtonText: 'OK' });
            else alert(r.message);
            // clear the choice (only if it is still the suspended doctor)
            if (el.value !== id || el.disabled) return;
            clearing = true;
            if ($el) $el.val('').trigger('change'); else { el.value = ''; el.dispatchEvent(new Event('change', { bubbles: true })); }
            clearing = false;
            lastChecked = null;
        }
        if ($el) $el.on('change', check); else el.addEventListener('change', check);
        if (el.value) setTimeout(check, 400);   // chosen before the page opened (roster slot, the patient's last referral)
    }

    wire('#ddlReferralDoctor', 'referral');
    wire('#ddlDoctor', 'consulting');
})();
