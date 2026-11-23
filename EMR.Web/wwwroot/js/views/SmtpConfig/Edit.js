// moved from Views/SmtpConfig/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    function selectProvider(type, host, port, ssl, starttls) {
        document.getElementById('providerType').value = type;
        if (host) document.getElementById('smtpHost').value = host;
        if (port) document.getElementById('smtpPort').value = port;
        document.getElementById('useSsl').checked = ssl;
        document.getElementById('useStartTls').checked = starttls;

        // Toggle active class
        document.querySelectorAll('.provider-preset').forEach(function (el) { el.classList.remove('active'); });
        event.currentTarget.classList.add('active');
    }

    function togglePassword() {
        var field = document.getElementById('passwordField');
        var icon = document.getElementById('pwdIcon');
        if (field.type === 'password') {
            field.type = 'text';
            icon.className = 'bi bi-eye-slash-fill';
        } else {
            field.type = 'password';
            icon.className = 'bi bi-eye-fill';
        }
    }
