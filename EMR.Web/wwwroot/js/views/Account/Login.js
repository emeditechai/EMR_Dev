// moved from Views/Account/Login.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // "Remember me": the app keeps the e-mail in this browser (the last one is filled in, up to 5 are offered as you
        // type) and lets the browser's own password manager save the password - encrypted by the browser, never by the app.
        // Not ticked: the e-mail is forgotten and the password is not offered to the password manager.
        // Unticking: the remembered e-mail is forgotten at once and both boxes are cleared.
        (function () {
            const KEY = 'emr.rememberedEmails';
            const email = document.querySelector('#loginForm input[name="Email"]');
            const remember = document.querySelector('#loginForm input[name="RememberMe"][type="checkbox"]');
            const pw = document.getElementById('passwordInput');
            let list = [];
            try {
                list = JSON.parse(localStorage.getItem(KEY) || '[]');
                const old = localStorage.getItem('emr.rememberedEmail');   // earlier single-e-mail key
                if (old && !list.includes(old)) list.unshift(old);
                localStorage.removeItem('emr.rememberedEmail');
            } catch { list = []; }
            if (email) {
                const dl = document.createElement('datalist');
                dl.id = 'rememberedEmails';
                list.forEach(e => { const o = document.createElement('option'); o.value = e; dl.appendChild(o); });
                email.after(dl);
                email.setAttribute('list', dl.id);
                if (list.length && !email.value) { email.value = list[0]; if (remember) remember.checked = true; pw?.focus(); }
            }
            const save = () => { try { localStorage.setItem(KEY, JSON.stringify(list.slice(0, 5))); } catch { } };
            remember?.addEventListener('change', () => {
                if (remember.checked) return;
                const v = email?.value.trim().toLowerCase();
                if (v) { list = list.filter(e => e.toLowerCase() !== v); save(); }
                document.getElementById('rememberedEmails')?.querySelectorAll('option').forEach(o => { if (o.value.toLowerCase() === v) o.remove(); });
                if (email) email.value = '';
                if (pw) pw.value = '';
                email?.focus();
            });
            const form = document.getElementById('loginForm');
            form?.addEventListener('submit', () => {
                const $f = window.jQuery ? jQuery(form) : null;
                if ($f && $f.valid && !$f.valid()) return;
                const v = email?.value.trim().toLowerCase();
                if (v) {
                    list = list.filter(e => e.toLowerCase() !== v);
                    if (remember?.checked) list.unshift(email.value.trim());
                    save();
                }
                // not remembered: post the password from a hidden field and empty the password box, so the browser
                // has no password to offer to save
                if (pw && !remember?.checked) {
                    const h = document.createElement('input');
                    h.type = 'hidden'; h.name = pw.name; h.value = pw.value;
                    form.appendChild(h);
                    pw.removeAttribute('name'); pw.value = '';
                }
            });
        })();

        document.getElementById('licRevalidateForm')?.addEventListener('submit', function () {
            const b = document.getElementById('licRevalidateBtn');
            b.disabled = true;
            b.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Checking with the licence server...';
        });
        function togglePassword() {
            const input = document.getElementById('passwordInput');
            const icon  = document.getElementById('eyeIcon');
            const btn   = document.getElementById('eyeBtn');
            const show  = input.type === 'password';
            input.type = show ? 'text' : 'password';
            icon.classList.replace(show ? 'bi-eye' : 'bi-eye-slash', show ? 'bi-eye-slash' : 'bi-eye');
            btn.setAttribute('aria-label', show ? 'Hide password' : 'Show password');
            btn.title = show ? 'Hide password' : 'Show password';
            input.focus();
        }

        // Caps Lock hint on the password field
        (function () {
            const pw = document.getElementById('passwordInput'), warn = document.getElementById('capsWarn');
            const check = e => { if (e.getModifierState) warn.hidden = !e.getModifierState('CapsLock'); };
            pw.addEventListener('keydown', check);
            pw.addEventListener('keyup', check);
            pw.addEventListener('blur', () => warn.hidden = true);
        })();

        // empty validation summary takes no space; busy state on Sign In once the form is valid
        (function () {
            const sum = document.querySelector('.ar-summary');
            const syncSummary = () => { if (sum) sum.style.display = sum.querySelector('li') && sum.textContent.trim() ? '' : 'none'; };
            syncSummary();
            const form = document.getElementById('loginForm');
            form.addEventListener('submit', function () {
                const $f = window.jQuery ? jQuery(form) : null;
                if ($f && $f.valid && !$f.valid()) return;
                const b = document.getElementById('signInBtn');
                setTimeout(() => { b.disabled = true; b.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>Signing in...'; }, 0);
            });
        })();
    
