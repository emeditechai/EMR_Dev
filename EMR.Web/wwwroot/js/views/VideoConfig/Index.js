// moved from Views/VideoConfig/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    const token = document.querySelector('input[name="__RequestVerificationToken"]')?.value ?? '';

    function updateKeyHint(inputId, hintId) {
        const el = document.getElementById(inputId);
        const hint = document.getElementById(hintId);
        if (!el || !hint) return;
        const val = (el.tagName === 'TEXTAREA' ? el.value : el.value).trim();
        const parts = val.split('.');
        const len = val.length;
        if (len === 0) {
            hint.innerHTML = '';
            return;
        }
        if (parts.length === 3 && len > 300) {
            hint.innerHTML = `<small class="text-success"><i class="bi bi-check-circle me-1"></i>Valid JWT format — ${len} characters ✅</small>`;
        } else if (parts.length < 3) {
            hint.innerHTML = `<small class="text-danger"><i class="bi bi-exclamation-triangle me-1"></i>Incomplete! JWT needs 3 dot-separated parts. Currently ${parts.length} part(s), ${len} chars. Paste the FULL key.</small>`;
        } else {
            hint.innerHTML = `<small class="text-warning"><i class="bi bi-info-circle me-1"></i>${len} chars, ${parts.length} JWT parts — may be truncated if under 300 chars.</small>`;
        }
    }

    // Run hint check on load for existing values
    document.querySelectorAll('textarea.cfg-value-input[data-key="WherebyApiKey"]').forEach(el => {
        const hintId = el.id.replace('val-', 'hint-');
        updateKeyHint(el.id, hintId);
    });

    function showBanner(msg, type = 'success') {
        const b = document.getElementById('statusBanner');
        b.className = `alert alert-${type} d-block`;
        b.innerHTML = `<i class="bi bi-${type === 'success' ? 'check-circle' : 'x-circle'} me-2"></i>${msg}`;
        setTimeout(() => b.classList.add('d-none'), 5000);
    }

    async function saveConfig(key) {
        const valueEl  = document.querySelector(`.cfg-value-input[data-key="${key}"]`);
        const urlEl    = document.querySelector(`.cfg-url-input[data-key="${key}"]`);
        const activeEl = document.querySelector(`.cfg-active-toggle[data-key="${key}"]`);

        // Extra validation for WherebyApiKey
        if (key === 'WherebyApiKey') {
            const val = (valueEl?.value ?? '').trim();
            const parts = val.split('.');
            if (parts.length < 3 || val.length < 300) {
                showBanner(`⚠️ WARNING: The API key looks incomplete (${val.length} chars, ${parts.length} JWT part(s)). A valid Whereby JWT has 3 parts separated by dots and is usually 400+ characters. Please paste the COMPLETE key from your Whereby dashboard.`, 'warning');
                return;
            }
        }

        const payload = {
            configKey: key,
            configValue: valueEl?.value ?? '',
            meetingCreationUrl: urlEl?.value ?? null,
            isActive: activeEl?.checked ?? true
        };

        const res  = await fetch('/VideoConfig/Save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': token },
            body: JSON.stringify(payload)
        });
        const data = await res.json();
        if (data.success) showBanner(data.message, 'success');
        else              showBanner(data.message, 'danger');
    }

    async function deleteConfig(configId) {
        const confirmed = await Swal.fire({
            title: 'Delete Config?',
            text: 'This will remove the config entry permanently.',
            icon: 'warning',
            showCancelButton: true,
            confirmButtonColor: '#dc3545',
            confirmButtonText: 'Yes, delete'
        });
        if (!confirmed.isConfirmed) return;

        const res  = await fetch('/VideoConfig/Delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': token },
            body: JSON.stringify(configId)
        });
        const data = await res.json();
        if (data.success) {
            document.getElementById(`card-${configId}`)?.closest('.col-12, .col-lg-6')?.remove();
            showBanner('Config entry deleted.', 'success');
        } else {
            showBanner(data.message, 'danger');
        }
    }

    // Add new config
    document.getElementById('btnSaveNewConfig').addEventListener('click', async function () {
        const key   = document.getElementById('newConfigKey').value.trim();
        const value = document.getElementById('newConfigValue').value.trim();
        const url   = document.getElementById('newMeetingUrl').value.trim();
        const active = document.getElementById('newIsActive').checked;

        if (!key || !value) { showBanner('Config Key and Value are required.', 'warning'); return; }

        const res  = await fetch('/VideoConfig/AddConfig', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': token },
            body: JSON.stringify({ configKey: key, configValue: value, meetingCreationUrl: url || null, isActive: active })
        });
        const data = await res.json();
        if (data.success) {
            bootstrap.Modal.getInstance(document.getElementById('addConfigModal')).hide();
            showBanner(`Config '${key}' added. Refreshing...`, 'success');
            setTimeout(() => window.location.reload(), 1200);
        } else {
            showBanner(data.message, 'danger');
        }
    });

    // Test Connection
    document.getElementById('btnTestConnection').addEventListener('click', async function () {
        const btn = this;
        btn.disabled = true;
        btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Testing…';
        try {
            const res  = await fetch('/VideoConfig/TestConnection', {
                method: 'POST',
                headers: { 'RequestVerificationToken': token }
            });
            const data = await res.json();
            showBanner(data.message, data.success ? 'success' : 'danger');
        } finally {
            btn.disabled = false;
            btn.innerHTML = '<i class="bi bi-wifi me-1"></i>Test Connection';
        }
    });

    // ── Failed Video Bookings ─────────────────────────────────────────────────
    async function loadFailedBookings() {
        const container = document.getElementById('failedBookingsContainer');
        const countBadge = document.getElementById('failedCount');
        container.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span> Loading...';

        try {
            const res = await fetch('/VideoConfig/GetFailedVideoBookings');
            const data = await res.json();

            if (!data.success || !data.items || data.items.length === 0) {
                countBadge.textContent = '0';
                container.innerHTML = `<div class="p-4 text-center text-success">
                    <i class="bi bi-check-circle-fill fs-3 mb-2 d-block"></i>
                    No failed video bookings found. All video rooms created successfully!
                </div>`;
                return;
            }

            countBadge.textContent = data.items.length;
            let html = '<div class="table-responsive"><table class="table table-hover align-middle mb-0">';
            html += `<thead class="table-light"><tr>
                <th class="ps-3">OPD Bill</th>
                <th>Patient</th>
                <th>Doctor</th>
                <th>Visit Date</th>
                <th>Error</th>
                <th class="text-center pe-3">Action</th>
            </tr></thead><tbody>`;

            for (const item of data.items) {
                html += `<tr>
                    <td class="ps-3"><span class="badge bg-secondary font-monospace">${item.opdBillNo || item.opdServiceId}</span></td>
                    <td>${item.patientName}</td>
                    <td>${item.doctorName}</td>
                    <td>${item.visitDate}</td>
                    <td><small class="text-danger">${item.errorMessage || 'Whereby API failed'}</small></td>
                    <td class="text-center pe-3">
                        <button data-permission="SETTINGS.VIDEOCONFIG:RETRIGGER" class="btn btn-sm btn-warning" onclick="retriggerVideoRoom(${item.opdServiceId}, this)" title="Re-trigger video room creation">
                            <i class="bi bi-arrow-repeat me-1"></i>Retry
                        </button>
                    </td>
                </tr>`;
            }
            html += '</tbody></table></div>';
            container.innerHTML = html;
        } catch (err) {
            container.innerHTML = '<div class="p-3 text-danger"><i class="bi bi-x-circle me-2"></i>Failed to load. ' + err.message + '</div>';
        }
    }

    async function retriggerVideoRoom(opdServiceId, btn) {
        btn.disabled = true;
        btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Retrying...';
        try {
            const res = await fetch('/OPD/RetriggerVideoRoom', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': token },
                body: JSON.stringify(opdServiceId)
            });
            const data = await res.json();
            if (data.success) {
                showBanner(data.message, 'success');
                setTimeout(() => loadFailedBookings(), 4000);
            } else {
                showBanner(data.message, 'danger');
                btn.disabled = false;
                btn.innerHTML = '<i class="bi bi-arrow-repeat me-1"></i>Retry';
            }
        } catch (err) {
            showBanner('Error: ' + err.message, 'danger');
            btn.disabled = false;
            btn.innerHTML = '<i class="bi bi-arrow-repeat me-1"></i>Retry';
        }
    }

    async function retryAllFailed() {
        const btn = document.getElementById('btnRetryAll');
        const rows = document.querySelectorAll('#failedBookingsContainer tr[data-opdid]');

        // Collect all OPD service IDs from the table
        const ids = [];
        document.querySelectorAll('#failedBookingsContainer button[onclick^="retriggerVideoRoom"]').forEach(b => {
            const match = b.getAttribute('onclick').match(/retriggerVideoRoom\((\d+)/);
            if (match) ids.push(parseInt(match[1]));
        });

        if (ids.length === 0) {
            showBanner('No failed bookings found to retry.', 'warning');
            return;
        }

        btn.disabled = true;
        btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Retrying All...';
        showBanner(`Retrying ${ids.length} failed video bookings... please wait.`, 'info');

        let successCount = 0, failCount = 0;
        for (const id of ids) {
            try {
                const res = await fetch('/OPD/RetriggerVideoRoom', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': token },
                    body: JSON.stringify(id)
                });
                const data = await res.json();
                if (data.success) successCount++;
                else failCount++;
            } catch { failCount++; }
            await new Promise(r => setTimeout(r, 1500)); // wait between calls
        }

        btn.disabled = false;
        btn.innerHTML = '<i class="bi bi-arrow-repeat me-1"></i>Retry All Failed';

        if (successCount > 0) {
            showBanner(`✅ ${successCount} video room(s) re-triggered! Email & WhatsApp notifications sent. Refreshing...`, 'success');
            setTimeout(() => loadFailedBookings(), 8000);
        } else {
            showBanner(`❌ All ${failCount} retries failed. Check your API key with "Test Connection".`, 'danger');
        }
    }

    // Load on page init
    loadFailedBookings();
