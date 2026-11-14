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
    
