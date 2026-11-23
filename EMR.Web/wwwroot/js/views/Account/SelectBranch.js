// moved from Views/Account/SelectBranch.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // Enter anywhere on the page continues with the chosen branch (buttons and links keep their own Enter)
        (function () {
            const form = document.getElementById('branchForm');
            const btn = document.getElementById('branchSubmitBtn');
            const select = document.getElementById('BranchId');
            if (!form || !btn) return;
            let sent = false;

            document.addEventListener('keydown', function (e) {
                if (e.key !== 'Enter' || e.isComposing || e.repeat || sent) return;
                const t = e.target;
                if (t && t !== select && t.closest && t.closest('button, a, textarea')) return;
                e.preventDefault();
                if (form.requestSubmit) form.requestSubmit(btn); else btn.click();
            });

            form.addEventListener('submit', function () {
                const $f = window.jQuery ? jQuery(form) : null;
                if ($f && $f.valid && !$f.valid()) return;
                if (select && !select.value) return;
                sent = true;
                setTimeout(() => { btn.disabled = true; btn.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>Please wait...'; }, 0);
            });

            // the branch list has focus, so arrow keys pick a branch and Enter continues
            select?.focus();
        })();
    
