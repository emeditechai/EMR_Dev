// moved from Views/SampleCollection/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // Fit the two panes into the screen space left below the filters, so the last tests of an order are never below
        // the bottom edge (a fixed 100vh - 240px was taller than that space). Re-fitted on resize; phones keep auto height.
        (function () {
            const pane = document.querySelector('.dual-pane-layout');
            if (!pane) return;
            function fitPanes() {
                if (window.innerWidth < 992) { pane.style.height = ''; pane.style.minHeight = ''; return; }
                const top = pane.getBoundingClientRect().top + window.scrollY;   // position on the page, whatever the scroll
                const available = window.innerHeight - Math.min(top, window.innerHeight * 0.55) - 32;   // 16px row gutter + 16px gap
                const h = Math.max(420, Math.round(available)) + 'px';
                pane.style.minHeight = h;   // replaces the stylesheet's fixed 580px minimum
                pane.style.height = h;
            }
            fitPanes();
            window.addEventListener('resize', fitPanes);
            window.addEventListener('load', fitPanes);
        })();
    
