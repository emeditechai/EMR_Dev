// moved from Views/WhatsAppConfig/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        function toggleScope(isAll) {
            document.getElementById('copyToAllInput').value = isAll ? 'true' : 'false';
            const ddWrap = document.getElementById('targetBranchDropdownWrap');
            const allNotice = document.getElementById('allBranchesNotice');
            const select = document.getElementById('targetBranchSelect');
            
            if (isAll) {
                ddWrap.classList.add('d-none');
                allNotice.classList.remove('d-none');
                select.removeAttribute('required');
            } else {
                ddWrap.classList.remove('d-none');
                allNotice.classList.add('d-none');
                select.setAttribute('required', 'required');
            }
        }

        document.getElementById('copyConfigForm')?.addEventListener('submit', function(e) {
            const isAll = document.getElementById('copyToAllInput').value === 'true';
            const select = document.getElementById('targetBranchSelect');
            const valMsg = document.getElementById('branchValidationMsg');
            
            if (!isAll && (!select.value || select.value === '')) {
                e.preventDefault();
                valMsg.classList.remove('d-none');
                select.focus();
                return false;
            }
            valMsg?.classList.add('d-none');
        });

        function toggleTokenVisibility() {
            var input = document.getElementById('apiKeyInput');
            var icon = document.getElementById('toggleTokenIcon');
            if (input.type === 'password') {
                input.type = 'text';
                icon.classList.remove('bi-eye');
                icon.classList.add('bi-eye-slash');
            } else {
                input.type = 'password';
                icon.classList.remove('bi-eye-slash');
                icon.classList.add('bi-eye');
            }
        }

        function insertTag(textareaId, tag) {
            var textarea = document.getElementById(textareaId);
            var start = textarea.selectionStart;
            var end = textarea.selectionEnd;
            var text = textarea.value;
            textarea.value = text.substring(0, start) + tag + text.substring(end);
            textarea.focus();
            textarea.selectionEnd = start + tag.length;
        }

        async function sendTestWhatsApp() {
            var phone = document.getElementById('testPhone').value.trim();
            var message = document.getElementById('testMessage').value.trim();
            var resultBox = document.getElementById('testResultBox');
            var btn = document.getElementById('btnSendTest');

            if (!phone) {
                alert('Please enter a recipient phone number.');
                return;
            }

            btn.disabled = true;
            btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1" role="status" aria-hidden="true"></span> Sending...';
            resultBox.style.display = 'none';

            try {
                var response = await fetch('/WhatsAppConfig/SendTestMessage', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        toPhone: phone,
                        messageText: message
                    })
                });

                var res = await response.json();
                resultBox.style.display = 'block';

                if (res.success) {
                    resultBox.className = 'alert alert-success mt-3 p-3 rounded-3';
                    resultBox.innerHTML = '<strong><i class="bi bi-check-circle-fill me-1"></i> Success!</strong> ' + res.message +
                        '<div class="mt-1 small font-monospace">MsgID: ' + (res.msgId || 'N/A') + ' | Status: ' + (res.status || 'in_progress') + '</div>';
                } else {
                    resultBox.className = 'alert alert-danger mt-3 p-3 rounded-3';
                    resultBox.innerHTML = '<strong><i class="bi bi-x-circle-fill me-1"></i> Failed:</strong> ' + res.message;
                }
            } catch (err) {
                resultBox.style.display = 'block';
                resultBox.className = 'alert alert-danger mt-3 p-3 rounded-3';
                resultBox.innerHTML = '<strong>Error:</strong> ' + err.message;
            } finally {
                btn.disabled = false;
                btn.innerHTML = '<i class="bi bi-whatsapp me-1"></i> Send Test Message';
            }
        }
    
