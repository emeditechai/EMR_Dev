// moved from Views/PharmacyItems/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
(function () {
    const form = document.getElementById('phFilter');
    const search = document.getElementById('phSearch');
    new TomSelect('#phMfr', { allowEmptyOption: true, onChange: () => form.submit() });
    form.querySelectorAll('select[data-auto]').forEach(s => s.addEventListener('change', () => form.submit()));
    // search as you type (server side, the list is paged)
    let t;
    search.addEventListener('input', () => { clearTimeout(t); t = setTimeout(() => form.submit(), 450); });
    if (search.value) { search.focus(); search.setSelectionRange(search.value.length, search.value.length); }
    document.querySelectorAll('#phTable tr[data-href]').forEach(tr => tr.addEventListener('click', e => { if (!e.target.closest('a')) location.href = tr.dataset.href; }));
    document.addEventListener('keydown', e => {
        if (e.key === '/' && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) { e.preventDefault(); search.focus(); search.select(); }
        const add = document.getElementById('phAdd');
        if (e.altKey && (e.key === 'n' || e.key === 'N') && add) { e.preventDefault(); location.href = add.href; }
    });
    document.getElementById('phExport').addEventListener('click', () => {
        const ws = XLSX.utils.table_to_sheet(document.getElementById('phTable'), { raw: true });
        const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, 'Items'); XLSX.writeFile(wb, 'Item_Drug_Master.xlsx');
    });
})();
