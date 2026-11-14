// moved from Views/Branches/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        (function () {
            const rows = [...document.querySelectorAll('#bmTable tbody tr[data-search]')];
            const $search = document.getElementById('bmSearch');
            const $status = document.getElementById('bmStatus');
            const $type = document.getElementById('bmType');
            const $lab = document.getElementById('bmLab');
            const $count = document.getElementById('bmCount');
            const $empty = document.getElementById('bmEmpty');

            function apply() {
                const term = $search.value.toLowerCase().trim();
                const status = $status.value;
                const type = $type.value;
                const lab = $lab.value;
                let shown = 0;

                rows.forEach(r => {
                    const ok = (!term || r.dataset.search.includes(term))
                        && (!status || r.dataset.status === status)
                        && (!type || r.dataset.type === type)
                        && (!lab || r.dataset.lab === lab);
                    r.style.display = ok ? '' : 'none';
                    if (ok) shown++;
                });

                $count.textContent = 'Showing ' + shown + ' of ' + rows.length;
                $empty.style.display = (rows.length > 0 && shown === 0) ? '' : 'none';
            }

            $search.addEventListener('input', apply);
            $status.addEventListener('change', apply);
            $type.addEventListener('change', apply);
            $lab.addEventListener('change', apply);
            document.getElementById('bmReset').addEventListener('click', () => {
                $search.value = ''; $status.value = ''; $type.value = ''; $lab.value = ''; apply(); $search.focus();
            });
        })();
    
