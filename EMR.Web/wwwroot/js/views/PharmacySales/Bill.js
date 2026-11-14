// moved from Views/PharmacySales/Bill.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
const cf = document.getElementById('cancelForm');
cf && cf.addEventListener('submit', async e => {
    if (cf.dataset.ok) return; e.preventDefault();
    const r = await Swal.fire({ title: 'Cancel this bill?', text: 'Stock goes back and the money taken is refunded (shown in your day closing).', input: 'text', inputLabel: 'Reason', icon: 'warning', showCancelButton: true, inputValidator: v => !v.trim() ? 'Reason is required.' : null });
    if (!r.isConfirmed) return; cf.querySelector('[name=reason]').value = r.value; cf.dataset.ok = '1'; cf.submit();
});
