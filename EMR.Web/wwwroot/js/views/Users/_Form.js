// moved from Views/Users/_Form.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
// ── Step tabs: dependency order Account -> Profile -> Access & Roles -> Clinical & Status ──
(function () {
    const steps = [...document.querySelectorAll('#ufSteps .uf-step')];
    const panes = [...document.querySelectorAll('.uf-pane')];
    const prev = document.getElementById('ufPrev'), next = document.getElementById('ufNext'), info = document.getElementById('ufStepInfo');
    const form = document.getElementById('ufSteps').closest('form');
    let current = 1;

    function go(n, scroll) {
        current = Math.min(Math.max(n, 1), steps.length);
        steps.forEach(s => {
            const k = parseInt(s.dataset.step);
            s.classList.toggle('active', k === current);
            s.classList.toggle('done', k < current && !s.classList.contains('has-error'));
            s.setAttribute('aria-selected', k === current ? 'true' : 'false');
        });
        panes.forEach(p => p.classList.toggle('active', parseInt(p.dataset.step) === current));
        prev.disabled = current === 1;
        next.style.visibility = current === steps.length ? 'hidden' : 'visible';
        info.textContent = 'Step ' + current + ' of ' + steps.length;
        document.querySelectorAll('.cms-wrap.cms-open').forEach(w => w.classList.remove('cms-open'));
        if (scroll) document.getElementById('ufSteps').scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    // Steps that hold an invalid field (client or server) get a red marker; returns the first one
    function markErrors() {
        let first = null;
        panes.forEach(p => {
            const bad = p.querySelector('.input-validation-error, .field-validation-error:not(:empty)');
            const k = parseInt(p.dataset.step);
            steps[k - 1].classList.toggle('has-error', !!bad);
            if (bad && first === null) first = k;
        });
        return first;
    }

    // "Next" asks for the dependency of the following step: Access & Roles needs at least one branch
    function canLeave(step) {
        if (step === 3 && !document.querySelector('input[name="SelectedBranchIds"]:checked')) {
            const v = document.querySelector('[data-valmsg-for="SelectedBranchIds"]');
            if (v) { v.textContent = 'Select at least one branch.'; v.classList.add('field-validation-error'); }
            markErrors();
            return false;
        }
        return true;
    }

    steps.forEach(s => s.addEventListener('click', () => go(parseInt(s.dataset.step))));
    prev.addEventListener('click', () => go(current - 1, true));
    next.addEventListener('click', () => { if (canLeave(current)) go(current + 1, true); });

    document.querySelectorAll('input[name="SelectedBranchIds"]').forEach(cb => cb.addEventListener('change', () => {
        const v = document.querySelector('[data-valmsg-for="SelectedBranchIds"]');
        if (v && document.querySelector('input[name="SelectedBranchIds"]:checked') && v.textContent === 'Select at least one branch.') {
            v.textContent = ''; v.classList.remove('field-validation-error'); markErrors();
        }
    }));

    if (form) {
        // Fields of hidden steps must still be validated on Save
        window.addEventListener('load', () => {
            const v = window.jQuery && jQuery(form).data('validator');
            if (v) v.settings.ignore = ':hidden:not(.uf-pane :input)';
        });
        form.addEventListener('submit', e => {
            if (!document.querySelector('input[name="SelectedBranchIds"]:checked')) {
                canLeave(3); e.preventDefault(); go(3, true); return;
            }
            setTimeout(() => { const bad = markErrors(); if (bad && bad !== current) go(bad, true); }, 0);
        });
        form.addEventListener('input', () => setTimeout(markErrors, 0));
        form.addEventListener('change', () => setTimeout(markErrors, 0));
    }

    // After a failed post-back open the first step with an error; otherwise start at step 1
    go(markErrors() || 1);
})();
