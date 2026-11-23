// moved from Views/AccVouchers/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            var $ = function (id) { return document.getElementById(id); };
            var fmt = function (n) { return Number(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); };
            var body = $('vcLines');

            function reindex() {
                body.querySelectorAll('tr.vc-line').forEach(function (tr, i) {
                    tr.querySelectorAll('[name]').forEach(function (el) { el.name = el.name.replace(/Lines\[\d+\]/, 'Lines[' + i + ']'); });
                });
            }

            function totals() {
                var dr = 0, cr = 0, lines = 0;
                body.querySelectorAll('tr.vc-line').forEach(function (tr) {
                    var d = parseFloat(tr.querySelector('.vc-dr').value) || 0, c = parseFloat(tr.querySelector('.vc-cr').value) || 0;
                    dr += d; cr += c; if ((d > 0 || c > 0) && tr.querySelector('.vc-ledger').value !== '0') lines++;
                });
                dr = Math.round(dr * 100) / 100; cr = Math.round(cr * 100) / 100;
                $('vcDr').textContent = fmt(dr); $('vcCr').textContent = fmt(cr);
                var diff = Math.round((dr - cr) * 100) / 100, ok = diff === 0 && dr > 0 && lines >= 2, badge = $('vcDiff');
                badge.textContent = dr === 0 && cr === 0 ? 'Enter the lines' : diff === 0 ? 'Balanced' : 'Difference ' + fmt(Math.abs(diff)) + (diff > 0 ? ' - credit short' : ' - debit short');
                badge.className = 'badge rounded-pill px-3 py-2 ' + (ok ? 'bg-success' : diff === 0 ? 'bg-secondary' : 'bg-danger');
                $('vcSave').disabled = !ok;   // an unbalanced voucher cannot be saved (the procedure refuses it too)
            }

            // ledgers offered depend on the voucher type: Contra = cash / bank only, Journal = no cash / bank
            function applyType() {
                var radio = document.querySelector('input[name="VoucherTypeCode"]:checked'), type = radio.value;
                $('vcHint').textContent = radio.dataset.hint;
                $('vcPayeeLabel').textContent = type === 'RCT' ? 'Received From' : 'Paid To';
                document.querySelectorAll('.vc-money').forEach(function (el) { el.classList.toggle('d-none', type === 'JRN'); });
                body.querySelectorAll('.vc-ledger option[data-type]').forEach(function (o) {
                    var money = o.dataset.type === 'CASH' || o.dataset.type === 'BANK';
                    var hide = (type === 'CTR' && !money) || (type === 'JRN' && money);
                    o.hidden = hide; o.disabled = hide;
                    if (hide && o.selected) o.parentElement.closest('select').value = '0';
                });
                totals();
            }

            $('vcAdd').addEventListener('click', function () {
                var tr = body.querySelector('tr.vc-line').cloneNode(true);
                tr.querySelectorAll('input').forEach(function (i) { i.value = ''; });
                tr.querySelector('select').value = '0';
                body.appendChild(tr); reindex();
                // offer the amount that balances the voucher on the short side
                var dr = 0, cr = 0;
                body.querySelectorAll('.vc-dr').forEach(function (x) { dr += parseFloat(x.value) || 0; });
                body.querySelectorAll('.vc-cr').forEach(function (x) { cr += parseFloat(x.value) || 0; });
                var diff = Math.round((dr - cr) * 100) / 100;
                if (diff > 0) tr.querySelector('.vc-cr').value = diff.toFixed(2); else if (diff < 0) tr.querySelector('.vc-dr').value = (-diff).toFixed(2);
                totals(); tr.querySelector('select').focus();
            });
            body.addEventListener('click', function (e) {
                var btn = e.target.closest('.vc-remove'); if (!btn) return;
                if (body.querySelectorAll('tr.vc-line').length > 2) btn.closest('tr').remove();
                else { btn.closest('tr').querySelectorAll('input').forEach(function (i) { i.value = ''; }); btn.closest('tr').querySelector('select').value = '0'; }
                reindex(); totals();
            });
            body.addEventListener('input', function (e) {
                // a line is either a debit or a credit
                var tr = e.target.closest('tr');
                if (e.target.classList.contains('vc-dr') && parseFloat(e.target.value) > 0) tr.querySelector('.vc-cr').value = '';
                if (e.target.classList.contains('vc-cr') && parseFloat(e.target.value) > 0) tr.querySelector('.vc-dr').value = '';
                totals();
            });
            body.addEventListener('change', totals);
            document.querySelectorAll('input[name="VoucherTypeCode"]').forEach(function (r) { r.addEventListener('change', applyType); });
            $('voucherForm').addEventListener('submit', function () { setTimeout(function () { $('vcSave').disabled = true; }, 0); });
            applyType();
        });
    
