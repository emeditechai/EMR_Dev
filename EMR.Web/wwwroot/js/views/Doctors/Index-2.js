// moved from Views/Doctors/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    // Filters run on the server (same behaviour as User Master): drop-downs submit at once, the search after a short pause
    (function () {
        const form = document.getElementById('dmFilter');
        const search = document.getElementById('dmSearch');
        const table = document.getElementById('dmTable');
        let timer = null;
        function submit() { if (table) table.classList.add('dm-loading'); form.submit(); }

        // Speciality / Department: auto-suggest (type to search) dropdowns
        $('#dmSpeciality, #dmDept').each(function () {
            $(this).select2({ theme: 'bootstrap-5', width: '100%', allowClear: true,
                placeholder: this.id === 'dmDept' ? 'All departments' : 'All specialities' });
        });
        $('#dmStatus, #dmReferral, #dmSpeciality, #dmDept').on('change', submit);

        search.addEventListener('input', () => {
            clearTimeout(timer);
            if (search.value.trim().length === 1) return;     // wait for two characters (or an empty box)
            timer = setTimeout(submit, 550);
        });
        search.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); clearTimeout(timer); submit(); } });
        if (search.value) { search.focus(); const n = search.value.length; search.setSelectionRange(n, n); }
        const size = document.getElementById('dmPageSize');
        if (size) size.addEventListener('change', () => { if (table) table.classList.add('dm-loading'); location.href = size.value; });
    })();
