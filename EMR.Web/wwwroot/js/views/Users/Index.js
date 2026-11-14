// moved from Views/Users/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // User Master > Unlock (locked after too many wrong passwords): confirm with a reason, then post
        document.querySelectorAll('.um-unlock').forEach(btn => btn.addEventListener('click', async () => {
            const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
            const r = await Swal.fire({
                title: 'Unlock user?',
                html: '<div class="small text-start"><b>' + esc(btn.dataset.name) + '</b> is locked after ' + esc(btn.dataset.tries) +
                      ' wrong passwords until ' + esc(btn.dataset.until) + '. Confirm the identity of the user before unlocking.</div>',
                icon: 'warning',
                input: 'text',
                inputLabel: 'Reason (recorded in the audit log)',
                inputPlaceholder: 'e.g. identity verified by phone',
                inputAttributes: { maxlength: 300 },
                inputValidator: v => (!v || v.trim().length < 3) ? 'Enter a reason (at least 3 characters).' : undefined,
                showCancelButton: true,
                confirmButtonText: '<i class="bi bi-unlock me-1"></i>Unlock',
                confirmButtonColor: '#d97706'
            });
            if (!r.isConfirmed) return;
            const f = document.getElementById('umUnlockForm');
            f.elements['id'].value = btn.dataset.id;
            f.elements['reason'].value = r.value.trim();
            f.submit();
        }));
    
