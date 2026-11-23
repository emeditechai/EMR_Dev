// moved from Views/Doctors/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // Phone Number: green when it is a valid mobile, red when typed but invalid (same rule as the server)
        (function () {
            var $ph = $('#PhoneNumber'), re = /^(?:\+?91[\- ]?|0)?[6-9]\d{9}$/;
            function mark() {
                var v = ($ph.val() || '').trim();
                $ph.toggleClass('is-valid', re.test(v)).toggleClass('is-invalid', v.length > 0 && !re.test(v));
            }
            $ph.on('input blur', mark);
            if ($ph.val()) mark();
        })();
    
