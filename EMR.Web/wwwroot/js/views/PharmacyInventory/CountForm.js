// moved from Views/PharmacyInventory/CountForm.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
document.getElementById('q').addEventListener('input', e => { const q = e.target.value.toLowerCase(); document.querySelectorAll('#tbl tbody tr').forEach(tr => tr.style.display = tr.textContent.toLowerCase().includes(q) ? '' : 'none'); });
document.querySelectorAll('#tbl input').forEach((i, k, all) => i.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); (all[k + 1] || i).focus(); all[k + 1]?.select(); } }));
document.querySelectorAll('form[data-confirm], form[data-remarks]').forEach(f => f.addEventListener('submit', async e => {
    if (f.dataset.ok) return; e.preventDefault();
    const r = f.dataset.remarks ? await Swal.fire({ title: f.querySelector('button').innerText.trim(), input: 'text', inputLabel: f.dataset.remarks, showCancelButton: true, inputValidator: x => f.dataset.required && !x.trim() ? 'Required.' : null })
                                : await Swal.fire({ title: 'Please confirm', text: f.dataset.confirm, icon: 'question', showCancelButton: true });
    if (!r.isConfirmed) return;
    if (f.dataset.remarks) { const h = document.createElement('input'); h.type = 'hidden'; h.name = 'remarks'; h.value = r.value || ''; f.appendChild(h); }
    f.dataset.ok = '1'; f.submit();
}));
