// moved from Views/AccOpening/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        (function () {
            const fmt = v => v.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
            function totals() {
                let dr = 0, cr = 0;
                document.querySelectorAll('.ob-dr').forEach(x => dr += parseFloat(x.value) || 0);
                document.querySelectorAll('.ob-cr').forEach(x => cr += parseFloat(x.value) || 0);
                document.getElementById('obDr').textContent = fmt(dr);
                document.getElementById('obCr').textContent = fmt(cr);
                const d = Math.round((dr - cr) * 100) / 100, el = document.getElementById('obDiff');
                el.innerHTML = d === 0 ? '<span class="text-success"><i class="bi bi-check-circle me-1"></i>Balanced</span>'
                    : `<span class="text-danger">${fmt(Math.abs(d))} ${d > 0 ? 'more debit' : 'more credit'}</span>`;
            }
            document.getElementById('obTable').addEventListener('input', totals);
            totals();
            document.getElementById('obForm').addEventListener('submit', e => {
                const d = document.getElementById('obDiff').textContent;
                if (!d.includes('Balanced') && !confirm('Debits and credits differ. Save anyway? The difference goes to "Opening Balance Difference".')) e.preventDefault();
            });
        })();
    
