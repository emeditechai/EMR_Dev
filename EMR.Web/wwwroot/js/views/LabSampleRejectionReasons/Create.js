// moved from Views/LabSampleRejectionReasons/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            var txt = document.getElementById('Reason_Text');
            var counter = document.getElementById('reasonTextCount');
            if (txt && counter) {
                var updateCount = function () { counter.textContent = txt.value.length; };
                txt.addEventListener('input', updateCount);
                updateCount();
            }
        });
    
