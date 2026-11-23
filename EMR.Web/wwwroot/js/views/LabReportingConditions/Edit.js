// moved from Views/LabReportingConditions/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            var txt = document.getElementById('Condition_Text');
            var counter = document.getElementById('conditionTextCount');
            if (txt && counter) {
                var update = function () { counter.textContent = txt.value.length; };
                txt.addEventListener('input', update);
                update();
            }
        });
    
