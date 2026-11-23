// moved from Views/Account/ResetPassword.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        (function () {
            const pw = document.getElementById('NewPassword');
            const rules = { len: v => v.length >= 8, letter: v => /[A-Za-z]/.test(v), digit: v => /\d/.test(v) };
            const paint = () => document.querySelectorAll('#pwRules li').forEach(li => {
                const ok = rules[li.dataset.rule](pw.value);
                li.classList.toggle('ok', ok);
                li.querySelector('i').className = ok ? 'bi bi-check-circle-fill' : 'bi bi-circle';
            });
            pw.addEventListener('input', paint);
            paint();
        })();
    
