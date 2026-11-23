// moved from Views/Notifications/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
(function () {
    if (!window.EmrNotify) return;
    var N = window.EmrNotify, list = document.getElementById('pgList'), more = document.getElementById('pgMoreWrap');
    var filter = 'all', oldest = null, PAGE = 25;

    function unread(c) { var b = document.getElementById('pgUnread'); b.textContent = c; b.classList.toggle('d-none', !c); }

    function page(reset) {
        if (reset) { oldest = null; list.innerHTML = '<div class="emr-bell-empty">Loading…</div>'; }
        N.feed({ top: PAGE, beforeId: oldest, unreadOnly: filter === 'unread' }).then(function (r) {
            if (!r || !r.success) { list.innerHTML = '<div class="emr-bell-empty">Notifications could not be loaded.</div>'; return; }
            unread(r.unreadCount);
            var html = r.items.map(N.row).join('');
            if (reset) list.innerHTML = html || '<div class="emr-bell-empty"><i class="bi bi-bell-slash d-block fs-3 mb-1"></i>'
                + (filter === 'unread' ? 'No unread notifications.' : 'You have no notifications.') + '</div>';
            else list.insertAdjacentHTML('beforeend', html);
            if (r.items.length) oldest = r.items[r.items.length - 1].notificationId;
            more.classList.toggle('d-none', r.items.length < PAGE);
        });
    }

    N.wireList(list, function () { if (!list.querySelector('.emr-notif')) page(true); });
    N.on(function () { page(true); });   // a new one arrived / changed in another tab
    document.getElementById('pgMore').addEventListener('click', function () { page(false); });
    document.getElementById('pgReadAll').addEventListener('click', function () { N.markAllRead().then(function () { page(true); }); });
    document.querySelectorAll('[data-filter]').forEach(function (b) {
        b.addEventListener('click', function () {
            document.querySelectorAll('[data-filter]').forEach(function (x) { x.classList.toggle('active', x === b); });
            filter = b.getAttribute('data-filter');
            page(true);
        });
    });
    page(true);
})();
