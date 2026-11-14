// moved from Views/DiscountTypes/_Form.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    document.addEventListener('DOMContentLoaded', function() {
        const radios = document.querySelectorAll('.discount-flag');
        const percentageFields = document.querySelectorAll('.percentage-field');
        const amountFields = document.querySelectorAll('.amount-field');
        
        function toggleFields() {
            const selected = document.querySelector('.discount-flag:checked').value;
            if (selected === 'P') {
                percentageFields.forEach(el => el.style.display = '');
                amountFields.forEach(el => el.style.display = 'none');
                
                // Clear amount when switching to percentage
                document.getElementById('DiscountAmount').value = '';
            } else {
                percentageFields.forEach(el => el.style.display = 'none');
                amountFields.forEach(el => el.style.display = '');
                
                // Clear percentages when switching to amount
                document.getElementById('PercentageFrom').value = '';
                document.getElementById('PercentageTo').value = '';
            }
        }
        
        radios.forEach(r => r.addEventListener('change', toggleFields));
    });
