// moved from Views/SampleTransfer/PrintWorksheet.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        function closeWorksheetWindow() {
            try {
                if (window.parent && window.parent.$ && window.parent.$('#modalPrintWorksheet').length) {
                    window.parent.$('#modalPrintWorksheet').modal('hide');
                    return;
                }
            } catch (e) { }
            window.close();
        }

        // Trigger print after rendering
        window.onload = function() {
            setTimeout(function() {
                window.print();
            }, 400);
        };
    
