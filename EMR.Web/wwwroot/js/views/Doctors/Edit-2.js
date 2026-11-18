// moved from Views/Doctors/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        new TomSelect('#primarySpeciality', { create: false, sortField: { field: 'text', direction: 'asc' } });
        new TomSelect('#secondarySpeciality', { create: false, allowEmptyOption: true });
        // marketing executive: search by name, type or code (Master > General > Marketing Executive)
        new TomSelect('#marketingExecutive', { create: false, allowEmptyOption: true, maxOptions: 500, placeholder: 'Search marketing executive…',
            sortField: [{ field: '$score' }, { field: 'text', direction: 'asc' }] });
        new TomSelect('#departmentMulti', {
            create: false,
            plugins: ['remove_button'],
            maxItems: null,
            hideSelected: true,
            placeholder: 'Select one or more departments'
        });

        const branchElement = document.getElementById('branchMulti');
        if (branchElement) {
            new TomSelect('#branchMulti', {
                create: false,
                plugins: ['remove_button'],
                maxItems: null,
                hideSelected: true,
                placeholder: 'Assign one or more branches'
            });
        }

        // ── Login account toggle ──
        // Is Referral Doctor: show Yes / No next to the switch
        (function () {
            const sw = document.getElementById('IsReferralDoctor'), txt = document.getElementById('isReferralDoctorText');
            if (!sw || !txt) return;
            const paint = () => {
                txt.textContent = sw.checked ? 'Yes' : 'No';
                txt.className = 'badge ms-1 ' + (sw.checked ? 'bg-success-subtle text-success border border-success-subtle'
                                                           : 'bg-secondary-subtle text-secondary border border-secondary-subtle');
            };
            sw.addEventListener('change', paint);
        })();

        // Is Suspended (SQLScripts/2484): switching it on asks for the reason (popup); cancelling leaves it off
        (function () {
            const sw = document.getElementById('IsSuspended'), txt = document.getElementById('isSuspendedText'),
                  reason = document.getElementById('SuspendReason'), info = document.getElementById('suspendInfo'),
                  infoText = document.getElementById('suspendReasonText'), btn = document.getElementById('btnSuspendReason');
            if (!sw || !reason) return;
            const paint = () => {
                txt.textContent = sw.checked ? 'Suspended' : 'No';
                txt.className = 'badge ms-1 ' + (sw.checked ? 'bg-danger-subtle text-danger border border-danger-subtle'
                                                           : 'bg-secondary-subtle text-secondary border border-secondary-subtle');
                info.classList.toggle('d-none', !sw.checked);
                infoText.textContent = reason.value;
            };
            async function ask() {
                if (!window.Swal) { const r = window.prompt('Reason for suspending the doctor', reason.value || ''); return r && r.trim() ? r.trim() : null; }
                const r = await Swal.fire({
                    title: 'Suspend this doctor?', icon: 'warning', input: 'textarea', inputValue: reason.value || '',
                    inputLabel: 'Reason for suspension (required)', inputPlaceholder: 'e.g. licence under review, on extended leave',
                    inputAttributes: { maxlength: 500 }, showCancelButton: true, confirmButtonText: 'Suspend', confirmButtonColor: '#dc2626',
                    inputValidator: v => (!v || !v.trim()) ? 'Enter the reason.' : (v.trim().length > 500 ? 'At most 500 characters.' : undefined)
                });
                return r.isConfirmed ? r.value.trim() : null;
            }
            sw.addEventListener('change', async () => {
                if (sw.checked) {
                    const r = await ask();
                    if (r === null) { sw.checked = false; paint(); return; }   // cancelled: not suspended
                    reason.value = r;
                } else {
                    reason.value = '';   // lifting the suspension clears the reason (the audit log keeps it)
                }
                paint();
            });
            btn?.addEventListener('click', async () => { const r = await ask(); if (r !== null) { reason.value = r; paint(); } });
            // the server refused (e.g. no reason): ask again
            if (sw.checked && !reason.value.trim()) setTimeout(async () => { const r = await ask(); if (r === null) { sw.checked = false; } else reason.value = r; paint(); }, 300);
        })();

        const loginToggle = document.getElementById('isLoginRequired');
        const loginPanel  = document.getElementById('loginFieldsPanel');
        function syncLoginPanel() {
            if (loginToggle.checked) {
                loginPanel.classList.remove('d-none');
            } else {
                loginPanel.classList.add('d-none');
            }
        }
        loginToggle.addEventListener('change', syncLoginPanel);
        // Panel visibility already set server-side via Razor class binding
    
