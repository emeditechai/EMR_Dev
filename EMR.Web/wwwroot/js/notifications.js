/*
 * The bell (SQLScripts/2263): the signed-in user's notifications.
 *  - live: a SignalR connection (/hubs/notifications) pushes a new notification to every open tab of its
 *    recipient, with automatic reconnect; while it is down the badge is checked every 60 seconds instead
 *  - a new notification rings the bell, shows a toast (click = open it) and, when the tab is in the background and
 *    the user allowed it, a desktop notification (permission is asked on the first click of the bell)
 *  - a new notification plays a short tone (a more urgent one for CRITICAL), once across the user's open tabs;
 *    the speaker button in the panel turns it off / on for this browser
 *  - read / dismissed in one tab updates the badge of the user's other tabs
 * window.EmrNotify is shared with the "View all" page (Views/Notifications/Index.cshtml).
 */
(function () {
    'use strict';
    var bell = document.getElementById('emrBell');
    if (!bell) return;

    var badge = document.getElementById('emrBellBadge');
    var list = document.getElementById('emrBellList');
    var live = document.getElementById('emrBellLive');
    var filter = 'all';
    var lastSeenId = 0;          // newest notification this tab knows about
    var loaded = false;
    var pollTimer = null;
    var listeners = [];          // the View all page listens for new / changed notifications

    var ICONS = { DISCOUNT_APPROVAL: 'bi-percent', MASTER_APPROVAL: 'bi-patch-check' };

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    }

    function when(iso) {
        var d = new Date(iso);
        if (isNaN(d)) return '';
        var s = Math.round((Date.now() - d.getTime()) / 1000);
        if (s < 45) return 'just now';
        if (s < 3600) return Math.round(s / 60) + ' min ago';
        if (s < 86400) return Math.round(s / 3600) + ' h ago';
        if (s < 7 * 86400) return Math.round(s / 86400) + ' d ago';
        return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
    }

    function fullTime(iso) {
        var d = new Date(iso);
        return isNaN(d) ? '' : d.toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
    }

    /** One notification row (also used by the View all page; full = no line clamp, with a dismiss button). */
    function row(n) {
        var sev = (n.severity || 'INFO').toUpperCase();
        return '<div class="emr-notif' + (n.isRead ? '' : ' unread') + '" data-id="' + n.notificationId + '" data-link="' + esc(n.link || '') + '" role="button" tabindex="0">'
            + '<div class="emr-notif-icon sev-' + esc(sev) + '"><i class="bi ' + (ICONS[n.category] || 'bi-bell') + '"></i></div>'
            + '<div class="emr-notif-body">'
            + '<div class="emr-notif-title">' + esc(n.title) + '</div>'
            + '<div class="emr-notif-msg">' + esc(n.message) + '</div>'
            + '<div class="emr-notif-time" title="' + esc(fullTime(n.createdOn)) + '">' + esc(when(n.createdOn)) + '</div>'
            + '</div>'
            + '<button type="button" class="emr-notif-x" title="Remove" aria-label="Remove notification"><i class="bi bi-x-lg"></i></button>'
            + '</div>';
    }

    function setBadge(count) {
        count = Number(count) || 0;
        badge.textContent = count > 99 ? '99+' : String(count);
        badge.classList.toggle('d-none', count === 0);
        var btn = document.getElementById('emrBellBtn');
        btn.title = count ? count + ' unread notification' + (count === 1 ? '' : 's') : 'Notifications';
        document.title = document.title.replace(/^\(\d+\+?\) /, '');
        if (count) document.title = '(' + (count > 99 ? '99+' : count) + ') ' + document.title;
    }

    function api(url, method) {
        return fetch(url, { method: method || 'GET', credentials: 'same-origin', headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } })
            .then(function (r) { return r.ok ? r.json() : null; })
            .catch(function () { return null; });
    }

    function feed(opts) {
        opts = opts || {};
        var q = '?top=' + (opts.top || 15) + (opts.beforeId ? '&beforeId=' + opts.beforeId : '') + (opts.unreadOnly ? '&unreadOnly=true' : '');
        return api('/Notifications/Feed' + q);
    }

    function load() {
        return feed({ unreadOnly: filter === 'unread' }).then(function (r) {
            if (!r || !r.success) { list.innerHTML = '<div class="emr-bell-empty">Notifications could not be loaded.</div>'; return; }
            loaded = true;
            setBadge(r.unreadCount);
            r.items.forEach(function (n) { if (n.notificationId > lastSeenId) lastSeenId = n.notificationId; });
            list.innerHTML = r.items.length ? r.items.map(row).join('')
                : '<div class="emr-bell-empty"><i class="bi bi-bell-slash d-block fs-4 mb-1"></i>' + (filter === 'unread' ? 'No unread notifications.' : 'You have no notifications.') + '</div>';
        });
    }

    function markRead(id) {
        return api('/Notifications/MarkRead?id=' + encodeURIComponent(id), 'POST').then(function (r) { if (r) setBadge(r.unreadCount); return r; });
    }
    function markAllRead() {
        return api('/Notifications/MarkAllRead', 'POST').then(function (r) { if (r) setBadge(r.unreadCount); return r; });
    }
    function dismiss(id) {
        return api('/Notifications/Dismiss?id=' + encodeURIComponent(id), 'POST').then(function (r) { if (r) setBadge(r.unreadCount); return r; });
    }

    /** Opens a notification: marked read, then its page (prints open in a new tab). */
    function open(id, link) {
        markRead(id).then(function () {
            notify('changed');
            if (!link) { if (loaded) load(); return; }
            if (/print/i.test(link)) { window.open(link, '_blank', 'noopener'); if (loaded) load(); }
            else window.location.href = link;
        });
    }

    /** Clicks inside any list of notification rows (the bell, the View all page). */
    function wireList(container, after) {
        container.addEventListener('click', function (e) {
            var item = e.target.closest('.emr-notif');
            if (!item) return;
            e.preventDefault();
            var id = item.getAttribute('data-id');
            if (e.target.closest('.emr-notif-x')) {
                dismiss(id).then(function () { item.remove(); notify('changed'); if (after) after(); });
                return;
            }
            open(id, item.getAttribute('data-link'));
        });
        container.addEventListener('keydown', function (e) {
            if (e.key !== 'Enter') return;
            var item = e.target.closest('.emr-notif');
            if (item) open(item.getAttribute('data-id'), item.getAttribute('data-link'));
        });
    }

    function notify(kind, item) { listeners.forEach(function (fn) { try { fn(kind, item); } catch (x) { } }); }

    // ── message tone ────────────────────────────────────────────────────────────────────────────────────────
    // Made with Web Audio (no sound file). Browsers allow sound only after the user has clicked or typed on the
    // page, so the audio is unlocked on the first such action; until then a tone is skipped silently.
    var SOUND_KEY = 'emr-notif-sound', CLAIM_KEY = 'emr-notif-tone';
    var audio = null;
    var soundBtn = document.getElementById('emrBellSound');

    function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (x) { return null; } }
    function soundOn() { return store(SOUND_KEY) !== 'off'; }
    function paintSound() {
        if (!soundBtn) return;
        var on = soundOn();
        soundBtn.classList.toggle('off', !on);
        soundBtn.innerHTML = '<i class="bi ' + (on ? 'bi-volume-up-fill' : 'bi-volume-mute-fill') + '"></i>';
        soundBtn.title = 'Notification sound: ' + (on ? 'on' : 'off');
        soundBtn.setAttribute('aria-label', soundBtn.title);
        soundBtn.setAttribute('aria-pressed', on ? 'true' : 'false');
    }
    function unlockAudio() {
        try {
            var Ctx = window.AudioContext || window.webkitAudioContext;
            if (!Ctx) return;
            if (!audio) audio = new Ctx();
            if (audio.state === 'suspended') audio.resume();
        } catch (x) { }
    }
    ['pointerdown', 'keydown'].forEach(function (ev) { document.addEventListener(ev, unlockAudio, { capture: true, passive: true }); });

    // notes: [frequency Hz, start s, length s]
    function playTone(critical) {
        if (!audio || audio.state !== 'running') return;
        var notes = critical
            ? [[988, 0, 0.14], [784, 0.17, 0.14], [988, 0.34, 0.14], [784, 0.51, 0.22]]   // urgent: four quick notes
            : [[880, 0, 0.16], [1318.5, 0.14, 0.32]];                                   // soft two-note chime
        var t0 = audio.currentTime + 0.02;
        notes.forEach(function (n) {
            var osc = audio.createOscillator(), gain = audio.createGain();
            osc.type = critical ? 'triangle' : 'sine';
            osc.frequency.value = n[0];
            var start = t0 + n[1], end = start + n[2];
            gain.gain.setValueAtTime(0.0001, start);
            gain.gain.exponentialRampToValueAtTime(critical ? 0.22 : 0.18, start + 0.015);
            gain.gain.exponentialRampToValueAtTime(0.0001, end);
            osc.connect(gain).connect(audio.destination);
            osc.start(start);
            osc.stop(end + 0.05);
        });
    }

    // every open tab hears about the notification: the tab on screen plays it at once, a background tab waits a
    // moment and plays only if no other tab has claimed this notification
    function toneFor(n) {
        if (!soundOn() || !n) return;
        var id = String(n.notificationId), critical = n.severity === 'CRITICAL';
        function claim() {
            if (store(CLAIM_KEY) === id) return;
            store(CLAIM_KEY, id);
            playTone(critical);
        }
        if (document.visibilityState === 'visible') claim();
        else setTimeout(claim, 250 + Math.floor(Math.random() * 250));
    }

    if (soundBtn) {
        soundBtn.addEventListener('click', function (e) {
            e.preventDefault(); e.stopPropagation();   // keep the panel open
            store(SOUND_KEY, soundOn() ? 'off' : 'on');
            paintSound();
            if (soundOn()) { unlockAudio(); setTimeout(function () { playTone(false); }, 30); }   // a sample of the tone
        });
        paintSound();
    }
    window.addEventListener('storage', function (e) { if (e.key === SOUND_KEY) paintSound(); });

    // ── a new notification arrives ──────────────────────────────────────────────────────────────────────────
    function arrived(n, unreadCount) {
        if (!n || n.notificationId <= lastSeenId) { if (unreadCount != null) setBadge(unreadCount); return; }
        lastSeenId = n.notificationId;
        if (unreadCount != null) setBadge(unreadCount);
        bell.classList.remove('ring'); void bell.offsetWidth; bell.classList.add('ring');
        toneFor(n);
        if (loaded) load();
        notify('new', n);

        if (window.Swal) {
            Swal.fire({
                toast: true, position: 'top-end', timer: 8000, timerProgressBar: true, showConfirmButton: false, showCloseButton: true,
                icon: n.severity === 'CRITICAL' ? 'error' : n.severity === 'WARNING' ? 'warning' : 'info',
                title: n.title, text: n.message,
                didOpen: function (el) {
                    el.style.cursor = 'pointer';
                    el.addEventListener('click', function (e) { if (!e.target.closest('.swal2-close')) { Swal.close(); open(n.notificationId, n.link); } });
                }
            });
        }
        if (document.hidden && 'Notification' in window && Notification.permission === 'granted') {
            try {
                var d = new Notification(n.title, { body: n.message, tag: 'emr-' + n.notificationId, icon: '/favicon.ico' });
                d.onclick = function () { window.focus(); open(n.notificationId, n.link); d.close(); };
            } catch (x) { }
        }
    }

    // ── live connection, with a 60-second check while it is down ────────────────────────────────────────────
    function setLive(on) {
        live.classList.toggle('on', !!on);
        live.title = on ? 'Live updates on' : 'Live updates paused - checking every minute';
        if (on) { if (pollTimer) { clearInterval(pollTimer); pollTimer = null; } }
        else if (!pollTimer) pollTimer = setInterval(poll, 60000);
    }

    function poll() {
        feed({ top: 5 }).then(function (r) {
            if (!r || !r.success) return;
            var fresh = r.items.filter(function (n) { return n.notificationId > lastSeenId; }).reverse();
            if (!fresh.length) { setBadge(r.unreadCount); return; }
            fresh.forEach(function (n) { arrived(n, r.unreadCount); });
        });
    }

    function connect() {
        if (!window.signalR) { setLive(false); return; }
        var conn = new signalR.HubConnectionBuilder()
            .withUrl('/hubs/notifications')
            .withAutomaticReconnect([0, 2000, 5000, 10000, 30000, 60000])
            .configureLogging(signalR.LogLevel.None)
            .build();
        conn.on('notification', function (p) { arrived(p && p.item, p && p.unreadCount); });
        conn.on('unread', function (p) { setBadge(p && p.unreadCount); if (loaded) load(); notify('changed'); });
        conn.onreconnecting(function () { setLive(false); });
        conn.onreconnected(function () { setLive(true); poll(); });   // catch up on anything sent while away
        conn.onclose(function () { setLive(false); setTimeout(start, 30000); });
        function start() {
            conn.start().then(function () { setLive(true); }).catch(function () { setLive(false); setTimeout(start, 30000); });
        }
        start();
    }

    // ── the bell ────────────────────────────────────────────────────────────────────────────────────────────
    bell.addEventListener('show.bs.dropdown', function () {
        load();
        if ('Notification' in window && Notification.permission === 'default') {
            try { Notification.requestPermission(); } catch (x) { }
        }
    });
    document.getElementById('emrBellReadAll').addEventListener('click', function () {
        markAllRead().then(function () { load(); notify('changed'); });
    });
    bell.querySelectorAll('.emr-bell-tabs button').forEach(function (b) {
        b.addEventListener('click', function () {
            bell.querySelectorAll('.emr-bell-tabs button').forEach(function (x) { x.classList.toggle('active', x === b); });
            filter = b.getAttribute('data-filter');
            load();
        });
    });
    wireList(list);

    // first paint: the badge and the newest id (so older notifications do not toast again)
    feed({ top: 1 }).then(function (r) {
        if (!r || !r.success) return;
        setBadge(r.unreadCount);
        if (r.items.length) lastSeenId = r.items[0].notificationId;
    });
    setLive(false);
    connect();

    window.EmrNotify = {
        row: row, feed: feed, markRead: markRead, markAllRead: markAllRead, dismiss: dismiss, open: open, wireList: wireList,
        on: function (fn) { listeners.push(fn); }
    };
})();
