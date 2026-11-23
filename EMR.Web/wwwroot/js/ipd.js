/* IPD screens (SQLScripts/2422+): fetch helpers, formatting, messages and the signature pad. */
(function () {
    'use strict';
    const token = () => document.querySelector('input[name="__RequestVerificationToken"]')?.value || '';
    const inr = new Intl.NumberFormat('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

    async function readJson(r) {
        let body = null;
        try { body = await r.json(); } catch { /* not JSON */ }
        if (!r.ok && !body) throw new Error('The server returned ' + r.status + '.');
        return body;
    }

    const Ipd = {
        /** GET a { success, data, error } endpoint; throws with the error text. */
        async get(url) {
            const r = await fetch(url, { headers: { 'X-Requested-With': 'XMLHttpRequest', 'Accept': 'application/json' } });
            const b = await readJson(r);
            if (b && b.success === false) throw new Error(b.error || b.message || 'The request failed.');
            return b && 'data' in b ? b.data : b;
        },
        /** GET a plain JSON endpoint (patient search lists). */
        async getRaw(url) {
            try { const r = await fetch(url, { headers: { 'X-Requested-With': 'XMLHttpRequest' } }); return r.ok ? await r.json() : null; } catch { return null; }
        },
        async post(url, body) {
            const r = await fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': token(), 'X-Requested-With': 'XMLHttpRequest' },
                body: JSON.stringify(body || {})
            });
            return await readJson(r) || { success: false, error: 'No answer from the server.' };
        },
        async postForm(url, formData) {
            if (!formData.has('__RequestVerificationToken')) formData.append('__RequestVerificationToken', token());
            const r = await fetch(url, { method: 'POST', body: formData, headers: { 'X-Requested-With': 'XMLHttpRequest' } });
            return await readJson(r) || { success: false, error: 'No answer from the server.' };
        },
        money(v) { return '₹' + inr.format(Number(v) || 0); },
        num(v) { return inr.format(Number(v) || 0); },
        esc(v) { return String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); },
        dt(v) {
            if (!v) return '';
            const d = new Date(v); if (isNaN(d)) return '';
            return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) + ' ' + d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
        },
        date(v) {
            if (!v) return '';
            const d = new Date(v); if (isNaN(d)) return '';
            return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
        },
        /** yyyy-MM-ddTHH:mm for a datetime-local input. */
        local(d) {
            d = d ? new Date(d) : new Date();
            const p = n => String(n).padStart(2, '0');
            return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
        },
        status(s) {
            const t = { ADMITTED: 'Admitted', DISCHARGE_ADVISED: 'Discharge advised', BILL_FINAL: 'Bill final', DISCHARGED: 'Discharged', CANCELLED: 'Cancelled' }[s] || s;
            return `<span class="ipd-pill st-${Ipd.esc(s)}">${Ipd.esc(t)}</span>`;
        },
        payer(p) { return { CASH: 'Cash', CORPORATE: 'Corporate', INSURANCE: 'Insurance / TPA', SCHEME: 'Govt. scheme' }[p] || p || ''; },
        toast(msg, icon = 'success') {
            if (window.Swal) Swal.fire({ toast: true, position: 'top-end', icon, title: msg, showConfirmButton: false, timer: 3200, timerProgressBar: true });
        },
        error(msg) { if (window.Swal) Swal.fire({ icon: 'error', title: 'Not saved', text: msg || 'The request failed.' }); },
        async confirm(title, html, confirmText = 'Yes') {
            if (!window.Swal) return true;
            const r = await Swal.fire({ icon: 'question', title, html, showCancelButton: true, confirmButtonText: confirmText, focusCancel: true });
            return r.isConfirmed;
        },
        /** Asks for a required reason; null = cancelled. */
        async reason(title, label = 'Reason') {
            if (!window.Swal) return null;
            const r = await Swal.fire({
                title, input: 'textarea', inputLabel: label, inputAttributes: { maxlength: 300 }, showCancelButton: true, confirmButtonText: 'Continue',
                inputValidator: v => (!v || !v.trim()) ? 'Enter the reason.' : undefined
            });
            return r.isConfirmed ? r.value.trim() : null;
        },
        /** ICD-10 search as you type on a code box and a diagnosis box: picking fills both. */
        icdSuggest(codeEl, titleEl, url) {
            if (!codeEl) return;
            const box = document.createElement('div');
            box.className = 'sug-list list-group';
            [codeEl, titleEl].forEach(el => { if (el && el.parentElement) el.parentElement.style.position = 'relative'; });
            let t, items = [], idx = 0, owner = null;
            const show = (el) => { owner = el; el.parentElement.appendChild(box); box.style.display = items.length ? 'block' : 'none'; };
            const render = () => {
                box.innerHTML = items.map((x, i) => `<button type="button" class="list-group-item list-group-item-action sug py-2 px-3 ${i === idx ? 'active' : ''}" data-i="${i}"><span class="badge text-bg-light border font-monospace me-2">${Ipd.esc(x.Code)}</span>${Ipd.esc(x.Title)}</button>`).join('');
            };
            const pick = i => { const x = items[i]; if (!x) return; codeEl.value = x.Code; if (titleEl && !titleEl.value.trim()) titleEl.value = x.Title; else if (titleEl && owner === titleEl) titleEl.value = x.Title; box.style.display = 'none'; };
            const onInput = el => {
                clearTimeout(t); const q = el.value.trim();
                if (q.length < 2) { box.style.display = 'none'; return; }
                t = setTimeout(async () => { try { items = await Ipd.get(url + '?q=' + encodeURIComponent(q)) || []; } catch { items = []; } idx = 0; render(); show(el); }, 220);
            };
            [codeEl, titleEl].forEach(el => {
                if (!el) return;
                el.setAttribute('autocomplete', 'off');
                el.addEventListener('input', () => onInput(el));
                el.addEventListener('keydown', e => {
                    if (box.style.display !== 'block' || owner !== el) return;
                    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); idx = (idx + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length; render(); }
                    else if (e.key === 'Enter') { e.preventDefault(); pick(idx); }
                    else if (e.key === 'Escape') box.style.display = 'none';
                });
            });
            box.addEventListener('mousedown', e => e.preventDefault());
            box.addEventListener('click', e => { const b = e.target.closest('[data-i]'); if (b) pick(Number(b.dataset.i)); });
            document.addEventListener('click', e => { if (!box.contains(e.target) && e.target !== codeEl && e.target !== titleEl) box.style.display = 'none'; });
        },
        /** A drawing pad on a canvas: pad.dataUrl() = PNG data URL or '' when empty, pad.clear(). */
        signaturePad(canvas) {
            const ctx = canvas.getContext('2d');
            let drawing = false, drawn = false;
            function fit() {
                const ratio = window.devicePixelRatio || 1, w = canvas.clientWidth, h = canvas.clientHeight;
                if (!w || !h) return;
                canvas.width = w * ratio; canvas.height = h * ratio; ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
                ctx.lineWidth = 2; ctx.lineCap = 'round'; ctx.strokeStyle = '#0f172a'; drawn = false;
            }
            const pos = e => { const r = canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
            canvas.addEventListener('pointerdown', e => { if (!canvas.width) fit(); drawing = true; const p = pos(e); ctx.beginPath(); ctx.moveTo(p.x, p.y); canvas.setPointerCapture(e.pointerId); });
            canvas.addEventListener('pointermove', e => { if (!drawing) return; const p = pos(e); ctx.lineTo(p.x, p.y); ctx.stroke(); drawn = true; });
            ['pointerup', 'pointercancel', 'pointerleave'].forEach(t => canvas.addEventListener(t, () => { drawing = false; }));
            setTimeout(fit, 50);
            return { clear: fit, dataUrl: () => drawn ? canvas.toDataURL('image/png') : '', fit };
        }
    };
    window.Ipd = Ipd;
})();
