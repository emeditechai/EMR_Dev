// moved from Views/Branches/_Form.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
(function () {
    'use strict';

    const inputs = document.querySelectorAll('.geo-suggest');
    let activeIndex = -1;

    function closeAll(except) {
        document.querySelectorAll('.geo-dropdown').forEach(dd => {
            if (dd !== except) dd.style.display = 'none';
        });
    }

    function clearChildren(fieldId) {
        if (fieldId === 'inp_Country') {
            const s = document.getElementById('inp_State');
            const c = document.getElementById('inp_City');
            if (s) s.value = '';
            if (c) c.value = '';
        }
        if (fieldId === 'inp_State') {
            const c = document.getElementById('inp_City');
            if (c) c.value = '';
        }
    }

    function buildDropdown(dd, items, nameKey, onSelect) {
        dd.innerHTML = '';
        activeIndex = -1;
        if (!items.length) { dd.style.display = 'none'; return; }

        items.forEach((item, idx) => {
            const li = document.createElement('li');
            li.className = 'list-group-item list-group-item-action py-2 px-3';
            li.style.cursor = 'pointer';
            li.textContent = item[nameKey];
            li.addEventListener('mousedown', e => {
                e.preventDefault();
                onSelect(item[nameKey]);
                dd.style.display = 'none';
            });
            dd.appendChild(li);
        });
        dd.style.display = 'block';
    }

    function highlightItem(dd, newIdx) {
        const items = dd.querySelectorAll('.list-group-item');
        items.forEach((el, i) => {
            el.classList.toggle('active', i === newIdx);
        });
        if (newIdx >= 0 && items[newIdx]) {
            items[newIdx].scrollIntoView({ block: 'nearest' });
        }
        activeIndex = newIdx;
    }

    inputs.forEach(input => {
        const ddId    = 'dd_' + input.id.replace('inp_', '');
        const dd      = document.getElementById(ddId);
        const url     = input.dataset.url;
        const nameKey = input.dataset.field === 'country' ? 'countryName'
                      : input.dataset.field === 'state'   ? 'stateName'
                      :                                     'cityName';

        let debounce;

        input.addEventListener('input', () => {
            clearTimeout(debounce);
            const term = input.value.trim();
            if (term.length < 2) { dd.style.display = 'none'; dd.innerHTML = ''; return; }

            debounce = setTimeout(async () => {
                const parentId    = input.dataset.parent;
                const parentParam = input.dataset.parentParam;
                let fetchUrl = `${url}?term=${encodeURIComponent(term)}`;
                if (parentId && parentParam) {
                    const parentVal = (document.getElementById(parentId)?.value ?? '').trim();
                    if (parentVal) fetchUrl += `&${parentParam}=${encodeURIComponent(parentVal)}`;
                }

                try {
                    const res  = await fetch(fetchUrl, { headers: { 'X-Requested-With': 'XMLHttpRequest' } });
                    const data = await res.json();
                    buildDropdown(dd, data, nameKey, name => {
                        input.value = name;
                        clearChildren(input.id);
                    });
                } catch { dd.style.display = 'none'; }
            }, 220);
        });

        input.addEventListener('keydown', e => {
            const items = dd.querySelectorAll('.list-group-item');
            if (!items.length || dd.style.display === 'none') return;

            if (e.key === 'ArrowDown') {
                e.preventDefault();
                highlightItem(dd, Math.min(activeIndex + 1, items.length - 1));
            } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                highlightItem(dd, Math.max(activeIndex - 1, 0));
            } else if (e.key === 'Enter' || e.key === 'Tab') {
                if (activeIndex >= 0 && items[activeIndex]) {
                    e.preventDefault();
                    input.value = items[activeIndex].textContent;
                    clearChildren(input.id);
                    dd.style.display = 'none';
                }
            } else if (e.key === 'Escape') {
                dd.style.display = 'none';
            }
        });

        input.addEventListener('focus', () => closeAll(dd));
        input.addEventListener('blur',  () => setTimeout(() => { dd.style.display = 'none'; }, 200));
    });

    document.addEventListener('click', e => {
        if (!e.target.closest('.geo-suggest-wrap')) closeAll(null);
    });
})();
