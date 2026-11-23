// moved from Views/SmtpConfig/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    function selectProvider(type, host, port, ssl, starttls) {
        document.getElementById('providerType').value = type;
        document.getElementById('smtpHost').value = host;
        document.getElementById('smtpPort').value = port;
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

    function showGmailHelp() {
        Swal.fire({
            icon: 'info',
            title: 'Gmail App Password',
            html: '<div class="text-start">' +
                '<p>Google requires an <strong>App Password</strong> for SMTP access:</p>' +
                '<ol>' +
                '<li>Go to <a href="https://myaccount.google.com/apppasswords" target="_blank">Google App Passwords</a></li>' +
                '<li>Sign in with your Google account</li>' +
                '<li>Select <strong>Mail</strong> as the app</li>' +
                '<li>Select your device or choose <strong>Other</strong></li>' +
                '<li>Click <strong>Generate</strong></li>' +
                '<li>Copy the 16-character password and paste it here</li>' +
                '</ol>' +
                '<p class="text-muted small">Note: You must have 2-Step Verification enabled on your Google account.</p>' +
                '</div>',
            confirmButtonText: 'Got it',
            confirmButtonColor: 'var(--emr-primary)',
            width: '500px'
        });
    }
