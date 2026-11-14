// moved from Views/AuditLogs/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
document.getElementById('auditModal').addEventListener('show.bs.modal', function (e) {
    const b = e.relatedTarget;
    document.getElementById('am-header-sub').textContent = `Log Entry #${b.dataset.id} • ${b.dataset.ts}`;
    document.getElementById('am-desc').textContent       = b.dataset.desc || '—';
    document.getElementById('am-module').textContent     = b.dataset.module || '—';
    document.getElementById('am-refno').textContent      = b.dataset.refno || '—';
    document.getElementById('am-patcode').textContent    = b.dataset.patcode || '—';
    document.getElementById('am-refid').textContent      = b.dataset.refid || '—';

    document.getElementById('am-ts').textContent         = b.dataset.ts;
    document.getElementById('am-user').textContent       = b.dataset.user;
    document.getElementById('am-branch').textContent     = b.dataset.branch;
    document.getElementById('am-action').textContent     = b.dataset.action;
    document.getElementById('am-route').textContent      = `${b.dataset.method} ${b.dataset.route}`;
    document.getElementById('am-ip').textContent         = b.dataset.ip;
    document.getElementById('am-agent').textContent      = b.dataset.agent;

    const metaContainer = document.getElementById('am-meta-container');
    const metaPre = document.getElementById('am-meta');
    const metaStr = b.dataset.meta;
    if (metaStr && metaStr.trim().length > 0) {
        try {
            const parsed = JSON.parse(metaStr);
            metaPre.textContent = JSON.stringify(parsed, null, 2);
            metaContainer.style.display = 'block';
        } catch {
            metaPre.textContent = metaStr;
            metaContainer.style.display = 'block';
        }
    } else {
        metaContainer.style.display = 'none';
        metaPre.textContent = '';
    }
});
