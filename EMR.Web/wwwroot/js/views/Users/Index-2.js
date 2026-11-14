// moved from Views/Users/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        (function () {
            // filters run on the server: the drop-downs submit at once, the search after a short pause (from page 1)
            const form = document.getElementById('umFilter');
            const search = document.getElementById('umSearch');
            const table = document.getElementById('umTable');
            let timer = null;
            function submit() { if (table) table.classList.add('um-loading'); form.submit(); }
            ['umType', 'umStatus', 'umRole'].forEach(id => document.getElementById(id).addEventListener('change', submit));
            search.addEventListener('input', () => {
                clearTimeout(timer);
                const v = search.value.trim();
                if (v.length === 1) return;          // wait for at least two characters (or an empty box)
                timer = setTimeout(submit, 550);
            });
            search.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); clearTimeout(timer); submit(); } });
            // keep the caret at the end of the search box after the page reloads
            if (search.value) { search.focus(); const n = search.value.length; search.setSelectionRange(n, n); }
            const size = document.getElementById('umPageSize');
            if (size) size.addEventListener('change', () => { if (table) table.classList.add('um-loading'); location.href = size.value; });
        })();
    
