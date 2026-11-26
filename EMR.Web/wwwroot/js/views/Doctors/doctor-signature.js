/* Doctor Master > Edit: the doctor's signature (SQLScripts/2559), uploaded / removed on its own; used on the IPD discharge prints. */
(function () {
    'use strict';
    const panel = document.getElementById('docSigPanel'); if (!panel) return;
    const img = document.getElementById('docSigImg'), none = document.getElementById('docSigNone'), file = document.getElementById('docSigFile');
    const up = document.getElementById('docSigUpload'), rm = document.getElementById('docSigRemove'), msg = document.getElementById('docSigMsg');
    const token = () => panel.querySelector('input[name="__RequestVerificationToken"]')?.value || '';
    const show = has => { img.style.display = has ? '' : 'none'; none.style.display = has ? 'none' : ''; rm.style.display = has ? '' : 'none'; };
    const say = (t, ok) => { msg.className = 'small mt-1 ' + (ok ? 'text-success' : 'text-danger'); msg.textContent = t; };
    img.addEventListener('load', () => show(true));
    img.addEventListener('error', () => show(false));
    if (img.complete) show(img.naturalWidth > 0);

    async function send(url, fd) {
        fd.append('id', panel.dataset.id);
        fd.append('__RequestVerificationToken', token());
        const r = await fetch(url, { method: 'POST', body: fd, credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' } });
        let b = null; try { b = await r.json(); } catch { /* not JSON */ }
        if (!r.ok && !b) throw new Error(r.status === 403 ? 'You are not allowed to change the doctor\'s signature.' : 'The server returned ' + r.status + '.');
        if (!b || !b.success) throw new Error((b && (b.error || b.message)) || 'The request failed.');
        return b;
    }

    up.addEventListener('click', async () => {
        const f = file.files[0];
        if (!f) return say('Choose the signature image.', false);
        if (!/\.(png|jpe?g)$/i.test(f.name)) return say('The signature must be a .png, .jpg or .jpeg file.', false);
        if (f.size > 2 * 1024 * 1024) return say('The signature image must be up to 2 MB.', false);
        const fd = new FormData(); fd.append('signatureFile', f);
        up.disabled = true;
        try { const b = await send(panel.dataset.upload, fd); img.src = b.previewUrl; file.value = ''; say('Signature saved.', true); }
        catch (e) { say(e.message, false); }
        finally { up.disabled = false; }
    });

    rm.addEventListener('click', async () => {
        if (!confirm('Remove the doctor\'s signature?')) return;
        try { await send(panel.dataset.remove, new FormData()); img.removeAttribute('src'); show(false); say('Signature removed.', true); }
        catch (e) { say(e.message, false); }
    });
})();
