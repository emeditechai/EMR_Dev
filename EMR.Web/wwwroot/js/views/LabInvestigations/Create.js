// moved from Views/LabInvestigations/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        (function () {
            ['Has_External_Document', 'Is_LMP_Date_Required'].forEach(function (id) {
                var t = document.getElementById(id);
                if (!t) return;
                var l = document.querySelector('label.form-check-label[for="' + id + '"]');
                t.addEventListener('change', function () { if (l) l.textContent = t.checked ? 'Yes' : 'No'; });
            });
        })();
    
