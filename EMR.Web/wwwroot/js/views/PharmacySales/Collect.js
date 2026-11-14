// moved from Views/PharmacySales/Collect.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
(function () {
    const al = [...document.querySelectorAll('.al')], t = document.getElementById('alT'), sum = () => t.textContent = al.reduce((s, a) => s + (parseFloat(a.value) || 0), 0).toFixed(2);
    document.getElementById('amt').addEventListener('input', e => { let left = parseFloat(e.target.value) || 0; al.forEach(a => { const v = Math.min(left, parseFloat(a.dataset.due)); a.value = v > 0 ? v.toFixed(2) : ''; left -= v; }); sum(); });
    al.forEach(a => a.addEventListener('input', sum));
    const mode = document.getElementById('mode'), m = () => { document.getElementById('ref').required = mode.value !== 'CASH'; document.getElementById('refL').classList.toggle('req', mode.value !== 'CASH'); }; mode.addEventListener('change', m); m();
})();
