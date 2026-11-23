// moved from Views/HospitalSettings/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    (function () {
        const btn = document.getElementById('btnCopyHo');
        if (!btn) return;
        btn.addEventListener('click', async () => {
            const r = await Swal.fire({
                icon: 'warning',
                title: 'Copy all settings from ' + btn.dataset.ho + '?',
                html: 'Every Hospital Settings value of <b>' + btn.dataset.ho + '</b> - hospital name, logo, address, contacts, NABH and all OPD / IPD / LAB / MED parameters - ' +
                      'replaces the settings of <b>' + btn.dataset.branch + '</b>.<br><br>The branch keeps its own day-closing start date. Its current values are saved in the audit log.',
                showCancelButton: true, confirmButtonText: 'Copy settings', confirmButtonColor: '#0d6efd'
            });
            if (r.isConfirmed) document.getElementById('frmCopyHo').submit();
        });
    })();
