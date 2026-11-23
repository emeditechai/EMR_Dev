// Master > Lab Franchises (SQLScripts/2490 / 2515): the franchise signs in with its e-mail, so the e-mail is checked while
// typing - free in this application and in the central user register - and Save stays disabled until it is confirmed
// (no e-mail = no login = nothing to wait for). The save checks again on the server. Same rule as User Master.
(function () {
    const mail = document.getElementById('Email');
    const script = document.currentScript;
    if (!mail || !script) return;
    const url = script.dataset.checkUrl, franchiseId = script.dataset.franchiseId || '0';
    const original = mail.value.trim().toLowerCase();
    const saveBtns = mail.form ? [...mail.form.querySelectorAll('button[type="submit"]')] : [];
    let msg = document.getElementById('flEmailState');
    if (!msg) {
        msg = document.createElement('div'); msg.id = 'flEmailState'; msg.className = 'small mt-1'; msg.setAttribute('aria-live', 'polite');
        (mail.closest('.input-group') || mail).after(msg);
    }
    let ok = true, timer = null, seq = 0;
    const gate = () => saveBtns.forEach(b => {
        b.disabled = !ok;
        b.title = ok ? '' : 'Enter an e-mail that is available for the franchise login - Save is enabled once it is confirmed.';
    });
    const paint = (kind, text) => {
        ok = kind === 'ok' || kind === '';
        mail.classList.toggle('is-valid', kind === 'ok');
        mail.classList.toggle('is-invalid', kind === 'bad');
        msg.className = 'small mt-1 ' + (kind === 'ok' ? 'text-success' : kind === 'bad' ? 'text-danger' : 'text-muted');
        msg.innerHTML = !text ? '' : (kind === 'ok' ? '<i class="bi bi-check-circle-fill me-1"></i>' : kind === 'bad' ? '<i class="bi bi-x-circle-fill me-1"></i>'
                      : '<span class="spinner-border spinner-border-sm me-1"></span>') + String(text).replace(/[<>&]/g, '');
        gate();
    };
    async function check() {
        const v = mail.value.trim();
        if (!v) { paint('', ''); return; }                                   // optional: no login
        if (v.toLowerCase() === original && franchiseId !== '0') { paint('ok', 'Current e-mail of this franchise.'); return; }
        const my = ++seq;
        paint('wait', 'Checking...'); ok = false; gate();
        try {
            const r = await (await fetch(url + '?email=' + encodeURIComponent(v) + '&franchiseId=' + franchiseId, { credentials: 'same-origin' })).json();
            if (my === seq) paint(r.valid && r.available ? 'ok' : 'bad', r.message);
        } catch (e) { if (my === seq) paint('bad', 'The e-mail could not be checked. Check the connection and try again.'); }
    }
    mail.addEventListener('input', () => {
        clearTimeout(timer);
        if (!mail.value.trim()) { paint('', ''); return; }
        ok = false; gate(); timer = setTimeout(check, 450);
    });
    mail.addEventListener('blur', () => { clearTimeout(timer); check(); });
    mail.form?.addEventListener('submit', e => {
        if (!ok) { e.preventDefault(); mail.focus(); mail.scrollIntoView({ block: 'center' }); check(); }
    });
    if (mail.value.trim()) check(); else gate();
})();
