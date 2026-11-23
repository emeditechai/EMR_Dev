// moved from Views/OtTariffs/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        function calculateTotal() {
            var total = 0;
            document.querySelectorAll('.fee-input').forEach(function (input) {
                var val = parseFloat(input.value) || 0;
                total += val;
            });
            document.getElementById('totalRateDisplay').innerText = '₹' + total.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        }

        document.querySelectorAll('.fee-input').forEach(function (input) {
            input.addEventListener('input', calculateTotal);
            input.addEventListener('change', calculateTotal);
        });

        calculateTotal();
    
