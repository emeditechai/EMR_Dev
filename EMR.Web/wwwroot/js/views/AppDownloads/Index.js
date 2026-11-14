// moved from Views/AppDownloads/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    // the file comes from the FTP server through the application - a large app can take a moment to start
    document.querySelectorAll('.btn-apk-dl').forEach(a => a.addEventListener('click', () => {
        const old = a.innerHTML; a.classList.add('disabled');
        a.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Preparing…';
        setTimeout(() => { a.classList.remove('disabled'); a.innerHTML = old; }, 4000);
    }));
