// moved from Views/PatientPortal/ChangePassword.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        (function () {
            const pw = document.getElementById('newPassword');
            const confirm = document.getElementById('confirmPassword');
            const bar = document.getElementById('strengthBar');
            const text = document.getElementById('strengthText');
            const btn = document.getElementById('btnSave');
            const rules = {
                len: v => v.length >= 8,
                letter: v => /[A-Za-z]/.test(v),
                digit: v => /\d/.test(v),
                match: v => v.length > 0 && v === confirm.value
            };

            // show / hide each password
            document.querySelectorAll('.pw-toggle').forEach(b => b.addEventListener('click', () => {
                const input = document.getElementById(b.dataset.target);
                const show = input.type === 'password';
                input.type = show ? 'text' : 'password';
                b.querySelector('i').className = show ? 'bi bi-eye-slash' : 'bi bi-eye';
                b.setAttribute('aria-label', show ? 'Hide password' : 'Show password');
            }));

            function update() {
                const v = pw.value;
                let met = 0;
                document.querySelectorAll('#pwRules li').forEach(li => {
                    const ok = rules[li.dataset.rule](v);
                    li.classList.toggle('ok', ok);
                    li.querySelector('i').className = ok ? 'bi bi-check-circle-fill' : 'bi bi-circle';
                    if (ok && li.dataset.rule !== 'match') met++;
                });
                // strength: the three rules plus length 12+ and a mix of cases / symbols
                let score = met;
                if (v.length >= 12) score++;
                if (/[a-z]/.test(v) && /[A-Z]/.test(v) && /[^A-Za-z0-9]/.test(v)) score++;
                const levels = [
                    { w: 0, c: '#e9ecef', t: '' },
                    { w: 25, c: '#dc3545', t: 'Weak' },
                    { w: 45, c: '#fd7e14', t: 'Fair' },
                    { w: 70, c: '#0d6efd', t: 'Good' },
                    { w: 85, c: '#16a34a', t: 'Strong' },
                    { w: 100, c: '#15803d', t: 'Very strong' }
                ];
                const l = v.length === 0 ? levels[0] : levels[Math.min(score, 5)] || levels[1];
                bar.style.width = l.w + '%';
                bar.style.backgroundColor = l.c;
                text.textContent = l.t ? 'Password strength: ' + l.t : '';
                btn.disabled = !(rules.len(v) && rules.letter(v) && rules.digit(v) && rules.match(v));
            }

            pw.addEventListener('input', update);
            confirm.addEventListener('input', update);
            update();
            document.getElementById('changePasswordForm').addEventListener('submit', () => {
                btn.disabled = true;
                btn.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>Saving...';
            });
        })();
    
