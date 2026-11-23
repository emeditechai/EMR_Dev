// moved from Views/Services/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        (function () {
            const sel = document.getElementById('ServiceType');
            
            const regRow = document.getElementById('isRegistrationRow');
            const chk = document.getElementById('IsRegistration');
            
            const consRow = document.getElementById('consultingTypeRow');
            const consSel = document.getElementById('ConsultingType');

            const gstToggle = document.getElementById('IsGstRequired');
            const gstCol = document.getElementById('gstPercentageCol');
            const gstInput = document.getElementById('GstPercentage');

            function toggle() {
                const isService = sel.value === 'Service';
                regRow.style.display = isService ? '' : 'none';
                if (!isService) chk.checked = false;

                const isConsulting = sel.value === 'Consulting';
                consRow.style.display = isConsulting ? '' : 'none';
                // Only clear value if we are switching away from Consulting
                if (!isConsulting) consSel.value = '';
            }

            function toggleGst() {
                if (gstToggle.checked) {
                    gstCol.style.display = '';
                } else {
                    gstCol.style.display = 'none';
                    gstInput.value = '';
                }
            }

            sel.addEventListener('change', toggle);
            gstToggle.addEventListener('change', toggleGst);

            toggle(); // run on page load (preserves server-side value)
            toggleGst();
        })();
    
