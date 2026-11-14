// moved from Views/Shared/_ApprovalBanner.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
            // read-only while waiting: fields and the save button of the master's edit form are switched off
            document.addEventListener('DOMContentLoaded', function () {
                document.querySelectorAll('#franchiseWizardEditForm, #corporateEditForm, #profileForm').forEach(function (form) {
                    form.querySelectorAll('input:not([type=hidden]), select, textarea').forEach(function (el) { el.disabled = true; });
                    form.querySelectorAll('button[type=submit], input[type=submit], button:not([type])').forEach(function (b) { b.disabled = true; b.classList.add('d-none'); });
                    form.addEventListener('submit', function (e) { e.preventDefault(); });
                });
            });
        
