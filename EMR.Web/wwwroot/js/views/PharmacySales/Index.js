// moved from Views/PharmacySales/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
(function () {
    const form = document.getElementById('phFilter'), search = document.getElementById('phSearch');
    form.querySelectorAll('[data-auto]').forEach(s => s.addEventListener('change', () => form.submit()));
    let t; search.addEventListener('input', () => { clearTimeout(t); t = setTimeout(() => form.submit(), 450); });
    if (search.value) { search.focus(); search.setSelectionRange(search.value.length, search.value.length); }
    document.querySelectorAll('#phTable tr[data-href]').forEach(tr => tr.addEventListener('click', () => location.href = tr.dataset.href));
    document.addEventListener('keydown', e => { if (e.key === '/' && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) { e.preventDefault(); search.focus(); } });
    document.getElementById('phExport').addEventListener('click', () => { const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, XLSX.utils.table_to_sheet(document.getElementById('phTable'), { raw: true }), 'Bills'); XLSX.writeFile(wb, 'Pharmacy_Sale_Bills.xlsx'); });
})();
