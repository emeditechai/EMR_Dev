// moved from Views/PharmacySales/ReturnForm.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
(function () {
    const rq = [...document.querySelectorAll('.rq')], tot = document.getElementById('rTotal'); if (!rq.length) return;
    const sum = () => { let t = 0; rq.forEach(i => { const v = (parseFloat(i.value) || 0) * parseFloat(i.dataset.rate); i.closest('tr').querySelector('.rv').textContent = v ? v.toFixed(2) : '—'; t += v; }); tot.textContent = t.toFixed(2); };
    rq.forEach(i => i.addEventListener('input', sum));
    // batch on the pack (SQLScripts/2406): a GS1 pack code gives the batch; it must be the batch sold on this line
    document.querySelectorAll('.rb').forEach(b => b.addEventListener('change', () => {
        const g = window.PhGs1 ? PhGs1.parse(b.value) : null;
        if (g && g.batch) b.value = g.batch;
        b.value = b.value.trim().toUpperCase();
        const ok = !b.value || b.value === String(b.dataset.batch).toUpperCase();
        b.classList.toggle('is-invalid', !ok); b.classList.toggle('is-valid', !!b.value && ok);
        b.title = ok ? '' : 'Not the batch sold on this bill (' + b.dataset.batch + ')';
    }));
    const f = document.getElementById('retForm');
    f.addEventListener('submit', async e => {
        if (f.dataset.ok) return; e.preventDefault();
        if (!rq.some(i => parseFloat(i.value) > 0)) { Swal.fire({ icon: 'info', title: 'Enter the quantity coming back.' }); return; }
        const noBatch = rq.filter(i => parseFloat(i.value) > 0).find(i => { const b = i.closest('tr').querySelector('.rb'); return !b || !b.value.trim() || b.classList.contains('is-invalid'); });
        if (noBatch) { Swal.fire({ icon: 'warning', title: 'Check the batch', text: 'For each item coming back, scan or type the batch number on the pack - it must be the batch sold on this bill.' }); return; }
        const r = await Swal.fire({ title: 'Save this return?', text: `Return value ₹ ${tot.textContent}. Stock goes back to the same batch.`, icon: 'question', showCancelButton: true });
        if (r.isConfirmed) { f.dataset.ok = '1'; f.submit(); }
    });
})();
