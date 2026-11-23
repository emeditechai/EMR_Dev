// moved from Views/Shared/_AuthLayout.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
            // background slideshow: cross-fade to the next image every 7 s, in a loop; paused while the tab is hidden
            (function () {
                const slides = document.querySelectorAll('.auth-slide');
                let i = 0, timer = null;
                const next = () => { slides[i].classList.remove('on'); i = (i + 1) % slides.length; slides[i].classList.add('on'); };
                const start = () => { if (!timer) timer = setInterval(next, 7000); };
                const stop = () => { clearInterval(timer); timer = null; };
                document.addEventListener('visibilitychange', () => document.hidden ? stop() : start());
                start();
            })();
        
