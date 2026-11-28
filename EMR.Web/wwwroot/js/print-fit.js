/* Bill pages (LAB B2C / B2B and OPD PrintBill): show the bill sheet as wide as the window ("Fit to screen"), or at its
   paper size ("Actual size"). The choice is remembered on this computer. Screen only - css/print-fit.css applies the
   zoom inside @media screen, so printing and the WhatsApp / e-mail PDFs are unchanged. */
(function () {
    'use strict';
    var KEY = 'emr.printFit';
    var root = document.documentElement;
    var wrap = document.querySelector('.page-wrap');
    if (!wrap || /HeadlessChrome/.test(navigator.userAgent)) return;

    var on = true;
    try { on = localStorage.getItem(KEY) !== '0'; } catch (e) { /* private mode: default on */ }

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn-fit';
    var bar = document.querySelector('.print-actions');
    if (bar) bar.insertBefore(btn, bar.firstChild);

    function fit() {
        // the sheet at its own size (A5 landscape bills carry their own zoom of 0.6)
        root.classList.remove('pf-on');
        root.style.removeProperty('--pf-zoom');
        if (on) {
            var own = parseFloat(getComputedStyle(wrap).zoom) || 1;
            var width = wrap.getBoundingClientRect().width;
            root.classList.add('pf-on');
            if (width > 0) {
                // window width less a margin; a vertical scroll bar appears once the sheet grows, so measure after
                var avail = function () { return root.clientWidth - 48; };
                var z = own * Math.min(3, Math.max(0.3, avail() / width));
                root.style.setProperty('--pf-zoom', String(z));
                if (root.scrollWidth > root.clientWidth) root.style.setProperty('--pf-zoom', String(own * Math.min(3, Math.max(0.3, avail() / width))));
            }
        }
        btn.textContent = on ? '\u2921 Actual size' : '\u2922 Fit to screen';
        btn.title = on ? 'Show the bill at its paper size' : 'Show the bill as wide as the window';
    }

    btn.addEventListener('click', function () {
        on = !on;
        try { localStorage.setItem(KEY, on ? '1' : '0'); } catch (e) { /* not remembered */ }
        fit();
    });
    var t;
    window.addEventListener('resize', function () { clearTimeout(t); t = setTimeout(fit, 120); });
    if (document.readyState === 'complete') fit(); else window.addEventListener('load', fit);
    fit();
})();
