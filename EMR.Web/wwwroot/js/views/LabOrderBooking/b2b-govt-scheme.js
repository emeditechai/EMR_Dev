// LAB B2B booking (Views/LabOrderBooking/B2BBooking.cshtml), SQLScripts/2535:
// a company whose rate list in force is marked "Is Government Scheme" (e.g. WBHS) needs the patient's Beneficiary ID -
// the field is shown and mandatory; for any other company or a franchise it stays hidden (and is not sent).
// The server checks the same rule again on save (LabOrderBookingController.B2BBooking).
(function () {
    'use strict';

    let scheme = null;   // { name } while the selected company is a government scheme
    let seq = 0;         // ignores an answer for a company that is no longer selected

    const wrap = () => document.getElementById('divBeneficiaryId');
    const input = () => document.getElementById('BeneficiaryId');
    const msg = () => document.querySelector('span[data-valmsg-for="BeneficiaryId"]');

    function show(name) {
        scheme = { name: name || 'Government Scheme' };
        const w = wrap(), i = input();
        if (!w || !i) return;
        w.style.display = '';
        i.disabled = false;
        i.required = true;
        const s = document.getElementById('lblBeneficiaryScheme');
        if (s) s.textContent = scheme.name;
    }

    function hide() {
        scheme = null;
        const w = wrap(), i = input();
        if (!w || !i) return;
        w.style.display = 'none';
        i.required = false;
        i.disabled = true;   // a hidden field is not posted: the stored Beneficiary ID is kept as it is
        i.classList.remove('is-invalid');
        const m = msg(); if (m) m.textContent = '';
    }

    window.B2BScheme = {
        /** Called whenever the partner (type or company / franchise) changes. */
        refresh(agentType, agentId) {
            const my = ++seq;
            if (!agentId || agentId <= 0) { hide(); return; }
            fetch(`/LabOrderBooking/GetB2BScheme?agentType=${encodeURIComponent(agentType)}&agentId=${agentId}`, { credentials: 'same-origin' })
                .then(r => r.ok ? r.json() : null)
                .then(res => {
                    if (my !== seq) return;
                    if (res && res.success && res.isGovtScheme) show(res.schemeName); else hide();
                })
                .catch(() => { if (my === seq) hide(); });   // the server still enforces the rule on save
        },

        /** false (and the field is flagged) when the scheme needs a Beneficiary ID that is not filled in. */
        validate() {
            if (!scheme) return true;
            const i = input();
            if (i && i.value.trim()) { i.classList.remove('is-invalid'); return true; }
            if (i) { i.classList.add('is-invalid'); i.focus(); }
            const m = msg(); if (m) m.textContent = `Beneficiary ID is required for ${scheme.name} bills.`;
            if (window.Swal) Swal.fire({ icon: 'warning', title: 'Beneficiary ID Required', text: `${scheme.name}: enter the patient's Beneficiary ID.`, confirmButtonColor: '#0d6efd' });
            return false;
        }
    };
})();
