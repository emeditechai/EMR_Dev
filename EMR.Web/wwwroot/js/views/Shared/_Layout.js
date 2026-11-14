// moved from Views/Shared/_Layout.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // Nested submenu: hover on desktop, click on mobile
        document.querySelectorAll('.dropdown-submenu').forEach(function (el) {
            var toggle = el.querySelector('.dropdown-submenu-toggle');
            var menu   = el.querySelector('.dropdown-submenu-menu');
            if (!toggle || !menu) return;

            var scrollParent = el.closest('.emr-menu-scroll');
            function positionSubmenu() {
                // inside a scrolling menu the flyout is placed on the page, next to its row (a scroll box would cut it off)
                if (scrollParent) {
                    var r = el.getBoundingClientRect();
                    var vw0 = window.innerWidth || document.documentElement.clientWidth;
                    var vh0 = window.innerHeight || document.documentElement.clientHeight;
                    menu.classList.add('is-fixed');
                    menu.classList.remove('open-left');
                    var w = menu.offsetWidth, h = menu.offsetHeight;
                    var left = r.right + 2;
                    if (left + w > vw0 - 8) { left = Math.max(8, r.left - w - 2); menu.classList.add('open-left'); }
                    var top = Math.min(r.top, Math.max(8, vh0 - h - 15));
                    menu.style.left = left + 'px'; menu.style.top = top + 'px'; menu.style.right = 'auto';
                    return;
                }
                menu.style.top = '0px';
                // open to the left when the flyout would run past the right edge (menus near the end of the bar)
                menu.classList.remove('open-left');
                var vw = window.innerWidth || document.documentElement.clientWidth;
                if (menu.getBoundingClientRect().right > vw - 8) menu.classList.add('open-left');
                var rect = menu.getBoundingClientRect();
                var vh = window.innerHeight || document.documentElement.clientHeight;
                if (rect.bottom > vh - 15) {
                    var overflow = rect.bottom - (vh - 15);
                    menu.style.top = '-' + Math.max(0, overflow) + 'px';
                }
            }

            // Desktop: hover
            el.addEventListener('mouseenter', function () {
                document.querySelectorAll('.dropdown-submenu-menu.show').forEach(function (m) { m.classList.remove('show'); });
                menu.classList.add('show');
                positionSubmenu();
            });
            el.addEventListener('mouseleave', function () {
                menu.classList.remove('show', 'open-left');
                menu.style.top = '0px';
                if (scrollParent) { menu.classList.remove('is-fixed'); menu.style.left = ''; menu.style.right = ''; }
            });
            // scrolling the menu moves the row away from its flyout: close it
            if (scrollParent) scrollParent.addEventListener('scroll', function () {
                if (menu.classList.contains('show')) { menu.classList.remove('show', 'open-left', 'is-fixed'); menu.style.top = '0px'; menu.style.left = ''; }
            }, { passive: true });

            // Mobile / click fallback
            toggle.addEventListener('click', function (e) {
                e.preventDefault();
                e.stopPropagation();
                var wasOpen = menu.classList.contains('show');
                document.querySelectorAll('.dropdown-submenu-menu.show').forEach(function (m) { m.classList.remove('show'); });
                if (!wasOpen) {
                    menu.classList.add('show');
                    positionSubmenu();
                }
            });
        });

        // A top menu with more than 10 entries: show the first 10 rows (dividers between them included) and scroll the rest;
        // never taller than the window below the menu bar.
        document.querySelectorAll('.emr-main-menu .dropdown-menu.emr-menu-scroll').forEach(function (ul) {
            var toggle = ul.previousElementSibling;
            if (!toggle) return;
            toggle.addEventListener('shown.bs.dropdown', function () {
                ul.style.maxHeight = '';
                var rows = Array.prototype.filter.call(ul.children, function (li) { return li.tagName === 'LI'; });
                var count = 0, height = 0;
                for (var i = 0; i < rows.length; i++) {
                    var isItem = !rows[i].querySelector('.dropdown-divider');
                    if (isItem && count === 10) break;
                    height += rows[i].getBoundingClientRect().height;
                    if (isItem) count++;
                }
                var cs = getComputedStyle(ul);
                height += parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom) + parseFloat(cs.borderTopWidth) + parseFloat(cs.borderBottomWidth);
                var room = (window.innerHeight || document.documentElement.clientHeight) - ul.getBoundingClientRect().top - 12;
                ul.style.maxHeight = Math.max(160, Math.min(height, room)) + 'px';
            });
        });

        // Close submenus when parent dropdown closes
        document.querySelectorAll('[data-bs-toggle="dropdown"]').forEach(function (btn) {
            btn.addEventListener('hidden.bs.dropdown', function () {
                document.querySelectorAll('.dropdown-submenu-menu.show').forEach(function (m) { m.classList.remove('show'); });
            });
        });
    
