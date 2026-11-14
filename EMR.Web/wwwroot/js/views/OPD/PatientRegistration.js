// moved from Views/OPD/PatientRegistration.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    // Age limit 110 years: the date of birth cannot be more than 110 years ago (picker limit + a check on a typed date)
    (function () {
        var dob = document.getElementById('DateOfBirth');
        if (!dob) return;
        var oldest = new Date(); oldest.setFullYear(oldest.getFullYear() - 110);
        var pad = function (n) { return String(n).padStart(2, '0'); };
        dob.min = oldest.getFullYear() + '-' + pad(oldest.getMonth() + 1) + '-' + pad(oldest.getDate());
        dob.addEventListener('change', function () {
            if (dob.value && dob.value < dob.min) {
                dob.classList.add('is-invalid');
                var fb = document.getElementById('ageValidationFeedback');
                if (fb) { fb.textContent = 'Age cannot be more than 110 years: check the date of birth.'; fb.classList.remove('d-none'); }
                if (window.Swal) Swal.fire({ icon: 'warning', title: 'Invalid Date of Birth', text: 'Age cannot be more than 110 years.' });
                dob.value = '';
                ['AgeYears', 'AgeMonths', 'AgeDays'].forEach(function (id) { var e = document.getElementById(id); if (e) e.value = ''; });
                dob.focus();
            }
        });
    })();
