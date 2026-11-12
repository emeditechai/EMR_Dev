/*
 * Keyboard-friendly date entry (dd/mm/yyyy) for <input type="date" data-date-entry>.
 *
 * Chrome's own date box builds the year one key at a time (2019 -> 0002, 0020, 0201, 2019) and fires an event for every
 * step, so page logic (age from date of birth, LMP checks) reacted to half-typed years. Here the user types into a
 * plain text box: digits only, the slashes appear by themselves (29011988 -> 29/01/1988), "1/2/1988" and a 2-digit year
 * ("29/01/88") are understood, T = today. A calendar button still opens the normal picker.
 *
 * The real <input type="date"> stays in the form underneath (same id / name, so model binding and every existing
 * script keep working) and is only changed - with input + change events - when a COMPLETE, valid date in range
 * (its min / max) is typed, or when the box is emptied. Values set on it by scripts (patient look-up, age -> date of
 * birth) are shown in the text box automatically.
 */
(function () {
    'use strict';
    if (window.DateEntry) return;

    const css = `
    .de-wrap{position:relative}
    .de-wrap .de-text{font-variant-numeric:tabular-nums;letter-spacing:.02em}
    .de-wrap .de-btn{border-color:var(--bs-border-color,#dee2e6);background:#fff;color:#64748b}
    .de-wrap .de-btn:hover{background:#f1f5f9;color:#0f172a}
    .de-wrap .de-native{position:absolute;right:0;bottom:0;width:1px;height:1px;opacity:0;pointer-events:none;border:0;padding:0}
    .de-msg{display:none;width:100%;margin-top:.25rem;font-size:.775em;color:var(--bs-form-invalid-color,#dc3545)}
    .de-msg.show{display:block}`;
    const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);

    const pad = n => String(n).padStart(2, '0');
    const iso = (y, m, d) => `${y}-${pad(m)}-${pad(d)}`;
    const show = isoVal => { if (!isoVal) return ''; const [y, m, d] = isoVal.split('-'); return `${d}/${m}/${y}`; };
    const fmtNice = isoVal => { const [y, m, d] = isoVal.split('-').map(Number); return new Date(y, m - 1, d).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }); };
    const todayIso = () => { const t = new Date(); return iso(t.getFullYear(), t.getMonth() + 1, t.getDate()); };

    /** "29011988", "29/1/1988", "1-2-88" ... -> { iso } when complete and a real date, else { partial: true } or { error }. */
    function parse(text) {
        const t = (text || '').trim();
        if (!t) return { empty: true };
        let d, m, y;
        if (/[\/.\-\s]/.test(t)) {
            const parts = t.split(/[\/.\-\s]+/).filter(Boolean);
            if (parts.length < 3) return { partial: true };
            [d, m, y] = parts;
        } else {
            const digits = t.replace(/\D/g, '');
            if (digits.length < 6) return { partial: true };
            d = digits.slice(0, 2); m = digits.slice(2, 4); y = digits.slice(4);
        }
        if (!/^\d{1,2}$/.test(d) || !/^\d{1,2}$/.test(m) || !/^(\d{2}|\d{4})$/.test(y)) return { partial: true };
        let yy = Number(y);
        if (y.length === 2) { const cur = new Date().getFullYear() % 100; yy += yy > cur ? 1900 : 2000; }   // 88 -> 1988, 19 -> 2019
        const dd = Number(d), mm = Number(m);
        if (mm < 1 || mm > 12) return { error: 'Month must be 01 to 12.' };
        const last = new Date(yy, mm, 0).getDate();
        if (dd < 1 || dd > last) return { error: `Day must be 01 to ${last} for that month.` };
        if (yy < 1900) return { error: 'Enter a 4-digit year (e.g. 1988).' };
        return { iso: iso(yy, mm, dd) };
    }

    /** While typing: one stream of digits shown as dd/mm/yyyy (slashes added by themselves). A slash typed by hand after a
     *  single digit pads it ("1/" -> "01/", "01/2/" -> "01/02/"). */
    function maskTyping(value) {
        const endsWithSep = /[\/.\-]$/.test(value);
        const parts = value.split(/[\/.\-]/);
        let digits = '';
        parts.forEach((p, i) => {
            p = p.replace(/\D/g, '');
            if (i < parts.length - 1 && p.length === 1 && digits.length < 4) p = '0' + p;   // day / month closed by hand
            digits += p;
        });
        digits = digits.slice(0, 8);
        let out = digits.length <= 2 ? digits
            : digits.length <= 4 ? digits.slice(0, 2) + '/' + digits.slice(2)
            : digits.slice(0, 2) + '/' + digits.slice(2, 4) + '/' + digits.slice(4);
        if (endsWithSep && (digits.length === 2 || digits.length === 4)) out += '/';
        return out;
    }

    function enhance(native) {
        if (native.dataset.deDone) return;
        native.dataset.deDone = '1';

        const group = document.createElement('div');
        group.className = 'input-group de-wrap';
        const text = document.createElement('input');
        text.type = 'text';
        text.className = 'form-control de-text';
        text.placeholder = 'dd/mm/yyyy';
        text.inputMode = 'numeric';
        text.autocomplete = 'off';
        text.maxLength = 10;
        text.setAttribute('aria-label', (native.labels && native.labels[0] ? native.labels[0].textContent.trim() : 'Date') + ' (dd/mm/yyyy)');
        if (native.title) text.title = native.title;
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn de-btn';
        btn.tabIndex = -1;
        btn.title = 'Pick from calendar (or type dd/mm/yyyy, T = today)';
        btn.setAttribute('aria-label', 'Open calendar');
        btn.innerHTML = '<i class="bi bi-calendar3"></i>';
        const msg = document.createElement('div');
        msg.className = 'de-msg';

        native.parentNode.insertBefore(group, native);
        group.appendChild(text);
        group.appendChild(btn);
        group.appendChild(native);
        group.after(msg);
        native.classList.add('de-native');
        native.tabIndex = -1;
        native.setAttribute('aria-hidden', 'true');
        // the page's own feedback (e.g. the LMP message) sits after the group now: keep it working
        const pageFeedback = msg.nextElementSibling && msg.nextElementSibling.classList.contains('invalid-feedback') ? msg.nextElementSibling : null;

        let last = native.value, pushing = false;
        text.value = show(native.value);

        const setMsg = m => { msg.textContent = m || ''; msg.classList.toggle('show', !!m); text.classList.toggle('is-invalid', !!m || native.classList.contains('is-invalid')); };
        function push(isoVal) {
            if (native.value === isoVal) { last = isoVal; return; }
            pushing = true;
            native.value = isoVal; last = isoVal;
            native.dispatchEvent(new Event('input', { bubbles: true }));
            native.dispatchEvent(new Event('change', { bubbles: true }));
            if (window.jQuery) jQuery(native).trigger('blur');   // jquery-validation re-checks the field
            pushing = false;
        }
        function commit(final) {
            const r = parse(text.value);
            if (r.empty) { setMsg(''); push(''); return; }
            if (r.partial) { if (final) { setMsg('Enter the full date as dd/mm/yyyy.'); push(''); } else setMsg(''); return; }
            if (r.error) { setMsg(r.error); if (final) push(''); return; }
            if (native.min && r.iso < native.min) { setMsg(`The date cannot be before ${fmtNice(native.min)}.`); if (final) push(''); return; }
            if (native.max && r.iso > native.max) { setMsg(`The date cannot be after ${fmtNice(native.max)}.`); if (final) push(''); return; }
            setMsg('');
            if (final) text.value = show(r.iso);
            push(r.iso);
        }

        text.addEventListener('keydown', e => {
            if (e.key === 't' || e.key === 'T') { e.preventDefault(); text.value = show(todayIso()); commit(true); return; }
            if (e.altKey && e.key === 'ArrowDown') { e.preventDefault(); openPicker(); return; }
            if (e.key === 'Enter') { commit(true); }
            if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !/[\d\/.\-]/.test(e.key)) e.preventDefault();
        });
        text.addEventListener('input', () => {
            const before = text.value, atEnd = text.selectionStart === before.length;
            const masked = maskTyping(before);
            if (masked !== before) { text.value = masked; if (atEnd) text.setSelectionRange(masked.length, masked.length); }
            commit(false);   // only a complete, valid date reaches the real field
        });
        text.addEventListener('blur', () => commit(true));
        text.addEventListener('paste', e => {
            const v = (e.clipboardData || window.clipboardData).getData('text') || '';
            const isoLike = v.trim().match(/^(\d{4})-(\d{2})-(\d{2})/);
            if (isoLike) { e.preventDefault(); text.value = `${isoLike[3]}/${isoLike[2]}/${isoLike[1]}`; commit(true); }
        });

        function openPicker() {
            if (native.disabled || native.readOnly) return;
            try { if (typeof native.showPicker === 'function') { native.showPicker(); return; } } catch { /* fall back */ }
            native.focus(); native.click();
        }
        btn.addEventListener('click', openPicker);
        // a date chosen in the calendar
        native.addEventListener('change', () => { if (pushing) return; last = native.value; text.value = show(native.value); setMsg(''); });

        // values set by scripts (no event): patient look-up, age -> date of birth; disabled / read-only / invalid state
        setInterval(() => {
            if (native.value !== last && document.activeElement !== text) { last = native.value; text.value = show(native.value); setMsg(''); }
            text.disabled = native.disabled; btn.disabled = native.disabled || native.readOnly; text.readOnly = native.readOnly;
            const nativeInvalid = native.classList.contains('is-invalid');
            text.classList.toggle('is-invalid', nativeInvalid || msg.classList.contains('show'));
            if (pageFeedback) pageFeedback.classList.toggle('d-block', nativeInvalid);
        }, 300);
    }

    function init(root) { (root || document).querySelectorAll('input[type="date"][data-date-entry]').forEach(enhance); }
    window.DateEntry = { init, parse };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => init()); else init();
})();
