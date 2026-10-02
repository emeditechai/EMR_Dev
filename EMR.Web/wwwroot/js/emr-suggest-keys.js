// Keyboard support for the patient-search suggestion lists (Vitals, Record Vital, New Service Booking):
//   ↓ / ↑  move through the results (wrapping), the mouse moves the same highlight
//   Enter  opens the highlighted result (the page's own click handler runs); with nothing highlighted the page's
//          own Enter behaviour (Search) runs as before
//   Esc    closes the list
// Usage: emrSuggestKeys(inputElement, dropdownElement [, itemSelector = '.suggest-item'])
(function () {
    'use strict';
    if (window.emrSuggestKeys) return;

    const style = document.createElement('style');
    style.textContent = '.suggest-item.active{background:#e8f0fe;box-shadow:inset 3px 0 0 #0d6efd}';
    document.head.appendChild(style);

    window.emrSuggestKeys = function (input, drop, itemSelector) {
        if (!input || !drop) return;
        const sel = itemSelector || '.suggest-item';
        const items = () => [...drop.querySelectorAll(sel)];
        const isOpen = () => drop.style.display !== 'none' && getComputedStyle(drop).display !== 'none' && items().length > 0;
        const current = () => items().findIndex(el => el.classList.contains('active'));

        function setActive(idx) {
            const list = items();
            if (!list.length) return;
            const i = (idx + list.length) % list.length;
            list.forEach((el, k) => {
                el.classList.toggle('active', k === i);
                el.setAttribute('role', 'option');
                el.setAttribute('aria-selected', k === i ? 'true' : 'false');
            });
            list[i].scrollIntoView({ block: 'nearest' });
        }

        input.setAttribute('aria-autocomplete', 'list');
        drop.setAttribute('role', 'listbox');

        input.addEventListener('keydown', e => {
            if (e.key === 'ArrowDown' && isOpen()) { e.preventDefault(); setActive(current() + 1); }
            else if (e.key === 'ArrowUp' && isOpen()) { e.preventDefault(); const c = current(); setActive(c < 0 ? -1 : c - 1); }
            else if (e.key === 'Escape' && isOpen()) { e.preventDefault(); drop.style.display = 'none'; }
            else if (e.key === 'Enter' && isOpen()) {
                const c = current();
                if (c >= 0) { e.preventDefault(); items()[c].click(); }   // preventDefault also stops the page's Enter = Search
            }
        });
        drop.addEventListener('mousemove', e => {
            const el = e.target.closest(sel);
            if (!el) return;
            const i = items().indexOf(el);
            if (i >= 0 && i !== current()) setActive(i);
        });
    };
})();
