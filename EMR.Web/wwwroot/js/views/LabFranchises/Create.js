// moved from Views/LabFranchises/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // Prepaid (Wallet) franchises have no credit terms: every field after Credit Facility Type is switched off and cleared.
        // The server ignores them for a prepaid franchise too. Switching back to Postpaid restores what was typed.
        (function () {
            var type = document.getElementById('Credit_Facility_Type');
            var ids = ['Credit_Limit', 'Credit_Days', 'Grace_Days', 'Security_Deposit_Amount', 'Security_Deposit_Received_On',
                       'Interest_On_Overdue_Percent', 'Temporary_Limit_Increase', 'Temp_Limit_Valid_Till'];
            function sync() {
                var prepaid = type.value === '1';
                ids.forEach(function (id) {
                    var el = document.getElementById(id);
                    if (!el) return;
                    if (prepaid && !el.disabled) { el.dataset.kept = el.value; el.value = ''; }
                    if (!prepaid && el.disabled && el.dataset.kept !== undefined) { el.value = el.dataset.kept; }
                    el.disabled = prepaid;
                    el.classList.toggle('bg-light', prepaid);
                });
                var note = document.getElementById('prepaidCreditNote');
                if (note) note.classList.toggle('d-none', !prepaid);
            }
            type.addEventListener('change', sync);
            sync();
        })();

        function goToStep(stepNumber) {
            var tabTrigger = document.querySelector('#tab-step' + stepNumber);
            var tab = new bootstrap.Tab(tabTrigger);
            tab.show();
            window.scrollTo({ top: 0, behavior: 'smooth' });
        }
    
