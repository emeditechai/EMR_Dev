/* LAB > Marketing Field Report (SQLScripts/2462): visits from the Marketing Executive App with the distance from the doctor's
   clinic, field days with km covered and the route, and the forecast doctors with address. Read only. */
(function () {
    'use strict';
    const P = window.MfPage, $ = id => document.getElementById(id), E = Ipd.esc;
    const iso = d => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    const STATUS = { VERIFIED: 'Verified', UNCONFIRMED: 'Unconfirmed pin', OUTSIDE: 'Outside clinic', NO_PIN: 'Clinic not pinned', NO_GPS: 'No location', MOCK: 'Fake location' };
    const PIN = { OK: 'GPS, checked', FLAGGED: 'Flagged', UNCONFIRMED: 'From the address', CONFIRMED: 'Confirmed by office', REJECTED: 'Rejected by office', NONE: 'Not saved' };
    const OUTCOME = { INTERESTED: 'Interested', FOLLOW_UP: 'Follow-up needed', NOT_AVAILABLE: 'Not available', NOT_INTERESTED: 'Not interested' };
    const STAGE = { PROSPECT: 'Prospect', CONTACTED: 'Contacted', ENGAGED: 'Engaged', TRIAL: 'Trial', ACTIVE: 'Active', LOST: 'Lost' };
    let tab = 'visits', data = [], execLoaded = false, map = null, layer = null;

    const metres = m => m == null ? '' : m >= 1000 ? (m / 1000).toFixed(1) + ' km' : Math.round(m) + ' m';
    const pill = (code, text) => `<span class="mf-st mf-st-${E(code)}">${E(text || code)}</span>`;
    const pinLabel = r => r.PinLat == null ? pill('NONE', PIN.NONE) : pill(r.PinStatus || 'OK', (r.PinSource === 'ADDRESS' ? 'From the address' : 'GPS') + (r.PinStatus === 'FLAGGED' ? ' · flagged' : ''));
    const kpi = (c, l, v, s) => `<div class="col-6 col-lg-3"><div class="border rounded-3 bg-white p-2 px-3 h-100 mf-kpi" style="--mf-c:${c}"><div class="small text-uppercase fw-bold text-muted" style="font-size:.68rem">${l}</div><div class="fs-5 fw-bold">${v}</div><div class="small text-muted">${s}</div></div></div>`;

    // ── loading ────────────────────────────────────────────────────────────────────────────────────────────────
    async function load() {
        const ex = $('mfExec').value, s = $('mfSearch').value.trim();
        const span = 8 + (tab === 'doctors' ? 2 : 0);
        $('mfRows').innerHTML = `<tr><td colspan="${span}" class="text-center text-muted py-4">Loading…</td></tr>`;
        try {
            if (tab === 'visits') {
                const d = await Ipd.get(P.base + 'VisitData?' + new URLSearchParams({ fromDate: $('mfFrom').value, toDate: $('mfTo').value, executiveId: ex, status: $('mfStatus').value, search: s }));
                data = d.visits || [];
                if (!execLoaded) fillExecs(d.executives || []);
            } else if (tab === 'days') {
                data = await Ipd.get(P.base + 'DayData?' + new URLSearchParams({ fromDate: $('mfFrom').value, toDate: $('mfTo').value, executiveId: ex })) || [];
            } else {
                data = await Ipd.get(P.base + 'DoctorData?' + new URLSearchParams({ executiveId: ex, stage: $('mfStage').value, pin: $('mfPin').value, search: s })) || [];
            }
            render();
        } catch (e) {
            $('mfRows').innerHTML = `<tr><td colspan="${span}" class="text-center text-danger py-4">${E(e.message)}</td></tr>`;
        }
    }

    function fillExecs(list) {
        list.forEach(e => $('mfExec').add(new Option(`${e.ExecutiveName} (${e.ExecutiveCode})${e.IsActive ? '' : ' · inactive'}`, e.ExecutiveId)));
        if (list.length === 1) { $('mfExec').value = list[0].ExecutiveId; $('mfExec').disabled = true; }
        execLoaded = true;
    }

    // ── rendering ──────────────────────────────────────────────────────────────────────────────────────────────
    function render() {
        if (tab === 'visits') renderVisits(); else if (tab === 'days') renderDays(); else renderDoctors();
    }

    function renderVisits() {
        const by = s => data.filter(r => r.VisitStatus === s).length;
        $('mfKpis').innerHTML = kpi('#2563eb', 'Visits', data.length, `${new Set(data.map(r => r.ForecastDoctorId)).size} doctor(s)`)
            + kpi('#16a34a', 'Verified', by('VERIFIED'), 'within 100 m of a checked clinic location')
            + kpi('#d97706', 'Unconfirmed pin', by('UNCONFIRMED'), 'clinic location from the address or flagged')
            + kpi('#dc2626', 'Outside / no location / fake', by('OUTSIDE') + by('NO_GPS') + by('MOCK') + by('NO_PIN'), `${data.filter(r => r.FlagReason).length} with a warning`);
        $('mfHead').innerHTML = '<tr><th>Date &amp; time</th><th>Executive</th><th>Doctor &amp; clinic address</th><th>Visit status</th><th class="text-end">From clinic</th><th>Clinic location</th><th>Outcome / notes</th><th class="text-end">Map</th></tr>';
        $('mfRows').innerHTML = data.length ? data.map((r, i) => `<tr>
            <td class="text-nowrap">${Ipd.dt(r.VisitDate)}</td>
            <td><div class="fw-semibold">${E(r.ExecutiveName)}</div><small class="text-muted">${E(r.ExecutiveCode)}</small></td>
            <td class="mf-addr"><div class="fw-semibold">${E(r.DoctorName)}</div><small class="text-muted">${E([r.ClinicName, r.Address].filter(Boolean).join(' · '))}</small></td>
            <td>${pill(r.VisitStatus, STATUS[r.VisitStatus])}${r.FlagReason ? `<div class="mf-warn mt-1"><i class="bi bi-exclamation-triangle me-1"></i>${E(r.FlagReason)}</div>` : ''}${r.IsMock ? '<div class="mf-warn mt-1">Fake (mock) location app</div>' : ''}</td>
            <td class="text-end text-nowrap">${r.DistanceM != null ? metres(r.DistanceM) : '-'}${r.AccuracyM != null ? `<div class="small text-muted">GPS ±${Math.round(r.AccuracyM)} m</div>` : ''}</td>
            <td>${pinLabel(r)}${r.PinSource === 'GPS' && r.AddressDistanceM != null ? `<div class="small text-muted">${metres(r.AddressDistanceM)} from the address</div>` : ''}${r.PinFlagReason && r.PinStatus === 'FLAGGED' ? `<div class="mf-warn">${E(r.PinFlagReason)}</div>` : ''}</td>
            <td class="small">${E(OUTCOME[r.Outcome] || r.Outcome)}${r.Notes ? `<div class="text-muted">${E(r.Notes)}</div>` : ''}</td>
            <td class="text-end">${r.VisitLat != null || r.PinLat != null ? `<button type="button" class="btn btn-sm btn-outline-primary" data-visit="${i}" title="Where the phone was and where the clinic is"><i class="bi bi-map"></i></button>` : ''}</td></tr>`).join('')
            : '<tr><td colspan="8" class="text-center text-muted py-4"><i class="bi bi-inbox me-1"></i>No visits from the app in this period.</td></tr>';
        $('mfNote').textContent = 'The distance is from the clinic location saved at the time of the visit. Verified = within 100 m of a GPS clinic location that passed the checks; Unconfirmed pin = near a location taken from the address, or a flagged one.';
    }

    function renderDays() {
        const sum = f => data.reduce((a, r) => a + (Number(r[f]) || 0), 0);
        $('mfKpis').innerHTML = kpi('#2563eb', 'Field days', data.length, `${new Set(data.map(r => r.ExecutiveId)).size} executive(s)`)
            + kpi('#0d9488', 'Distance covered', sum('Km').toFixed(1) + ' km', 'from the route recorded')
            + kpi('#7c3aed', 'Hours in the field', sum('Hours').toFixed(1), 'start to end')
            + kpi('#16a34a', 'Visits on field days', sum('Visits'), `${sum('Verified')} verified`);
        $('mfHead').innerHTML = '<tr><th>Date</th><th>Executive</th><th>Start</th><th>End</th><th class="text-end">Hours</th><th class="text-end">Km covered</th><th class="text-end">Visits</th><th class="text-end">Route</th></tr>';
        $('mfRows').innerHTML = data.length ? data.map(r => `<tr>
            <td class="text-nowrap">${Ipd.date(r.DutyDate)}</td>
            <td><div class="fw-semibold">${E(r.ExecutiveName)}</div><small class="text-muted">${E(r.ExecutiveCode)}</small></td>
            <td class="text-nowrap">${Ipd.dt(r.StartDate)}</td>
            <td class="text-nowrap">${r.IsOpen ? '<span class="mf-st mf-st-UNCONFIRMED">Still in the field</span>' : Ipd.dt(r.EndDate)}</td>
            <td class="text-end">${Number(r.Hours).toFixed(1)}</td>
            <td class="text-end fw-semibold">${Number(r.Km).toFixed(2)}<div class="small text-muted fw-normal">${r.Points} point(s)${r.MockPoints ? ` · <span class="text-danger">${r.MockPoints} fake</span>` : ''}</div></td>
            <td class="text-end">${r.Visits}<div class="small text-muted">${r.Verified} verified${r.Outside ? ` · ${r.Outside} outside` : ''}${r.Unconfirmed ? ` · ${r.Unconfirmed} unconfirmed` : ''}</div></td>
            <td class="text-end"><button type="button" class="btn btn-sm btn-outline-primary" data-day="${r.DayId}" title="Route and visits on the map"><i class="bi bi-map"></i></button></td></tr>`).join('')
            : '<tr><td colspan="8" class="text-center text-muted py-4"><i class="bi bi-inbox me-1"></i>No field days in this period.</td></tr>';
        $('mfNote').textContent = 'Km covered adds up the steps between the route points recorded about every minute during the field day (readings less accurate than 50 m, steps under 25 m and jumps faster than 150 km/h are left out), so it is the distance along the recorded route, not the road distance.';
    }

    function renderDoctors() {
        const by = s => data.filter(r => s === 'NONE' ? r.PinLat == null : r.PinStatus === s).length;
        $('mfKpis').innerHTML = kpi('#2563eb', 'Doctors', data.length, `${data.filter(r => r.Visits > 0).length} visited`)
            + kpi('#16a34a', 'Clinic location checked', by('OK') + by('CONFIRMED'), 'GPS at the clinic, no warnings')
            + kpi('#d97706', 'From the address', by('UNCONFIRMED'), 'exact location not saved yet')
            + kpi('#dc2626', 'Flagged / not saved', by('FLAGGED') + by('NONE'), `${by('FLAGGED')} flagged`);
        $('mfHead').innerHTML = '<tr><th>Doctor</th><th>Clinic &amp; address</th><th>Executive</th><th>Stage</th><th>Clinic location</th><th class="text-end">Visits</th><th>Last visit</th><th>Added</th><th>Doctor Master</th><th class="text-end">Map</th></tr>';
        $('mfRows').innerHTML = data.length ? data.map((r, i) => `<tr>
            <td><div class="fw-semibold">${E(r.DoctorName)}</div><small class="text-muted">${E([r.SpecialityName, r.DoctorMobile].filter(Boolean).join(' · '))}</small></td>
            <td class="mf-addr"><div>${E(r.ClinicName || '')}</div><small class="text-muted">${E(r.Address || '')}</small>${r.GeoAddress && r.GeoAddress !== r.Address ? `<div class="small text-muted"><i class="bi bi-pin-map me-1"></i>Map: ${E(r.GeoAddress)}</div>` : ''}</td>
            <td><div>${E(r.ExecutiveName)}</div><small class="text-muted">${E(r.ExecutiveCode)}</small></td>
            <td>${E(STAGE[r.Stage] || r.Stage)}</td>
            <td>${pinLabel(r)}${r.PinSource === 'GPS' && r.AddressDistanceM != null ? `<div class="small text-muted">${metres(r.AddressDistanceM)} from the address</div>` : ''}${r.PinFlagReason && r.PinStatus === 'FLAGGED' ? `<div class="mf-warn">${E(r.PinFlagReason)}</div>` : ''}</td>
            <td class="text-end">${r.Visits}<div class="small text-muted">${r.Verified} verified</div></td>
            <td class="text-nowrap">${r.LastVisitDate ? Ipd.date(r.LastVisitDate) + '<div>' + pill(r.LastVisitStatus, STATUS[r.LastVisitStatus]) + '</div>' : '<span class="text-muted">Not visited</span>'}</td>
            <td class="text-nowrap">${Ipd.date(r.CreatedDate)}</td>
            <td>${r.DoctorId ? (r.DoctorActive ? pill('OK', 'Approved') : pill('UNCONFIRMED', 'Waiting')) : '<span class="text-muted small">-</span>'}</td>
            <td class="text-end">${r.PinLat != null || r.GeoLat != null ? `<button type="button" class="btn btn-sm btn-outline-primary" data-doctor="${i}" title="Clinic location and address on the map"><i class="bi bi-map"></i></button>` : ''}</td></tr>`).join('')
            : '<tr><td colspan="10" class="text-center text-muted py-4"><i class="bi bi-inbox me-1"></i>No doctors.</td></tr>';
        $('mfNote').textContent = 'Clinic location: GPS = saved by the executive at the clinic and compared with the address on the map; From the address = the executive was not at the clinic, so visits are not verified until the exact location is saved there.';
    }

    // ── map ────────────────────────────────────────────────────────────────────────────────────────────────────
    const dot = (color, size = 12) => L.divIcon({ className: '', html: `<span style="display:block;width:${size}px;height:${size}px;border-radius:50%;background:${color};border:2px solid #fff;box-shadow:0 0 0 1px rgba(0,0,0,.35)"></span>`, iconSize: [size, size], iconAnchor: [size / 2, size / 2] });
    const COLORS = { clinic: '#7c3aed', address: '#2563eb', phone: '#ea580c', start: '#16a34a', end: '#dc2626', route: '#0d9488' };

    function openMap(title, sub, draw, legend) {
        $('mfMapTitle').textContent = title; $('mfMapSub').textContent = sub || '';
        $('mfMapLegend').innerHTML = legend.map(([c, t]) => `<span class="mf-legend-dot" style="background:${COLORS[c]}"></span>${E(t)}`).join('');
        const modal = bootstrap.Modal.getOrCreateInstance($('mfMapModal'));
        $('mfMapModal').addEventListener('shown.bs.modal', function once() {
            $('mfMapModal').removeEventListener('shown.bs.modal', once);
            if (!map) {
                // a view first: circles need the map's projection to measure their bounds
                map = L.map('mfMap').setView([22.57, 88.36], 11);
                L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '&copy; OpenStreetMap contributors' }).addTo(map);
            }
            if (layer) layer.remove();
            map.invalidateSize();
            layer = L.featureGroup().addTo(map);
            draw(layer);
            const b = layer.getBounds();
            if (b.isValid()) map.fitBounds(b.pad(0.3), { maxZoom: 17 }); else map.setView([22.57, 88.36], 11);
        });
        modal.show();
    }

    const at = (lat, lng) => lat != null && lng != null ? [Number(lat), Number(lng)] : null;

    function visitMap(r) {
        const phone = at(r.VisitLat, r.VisitLng), pin = at(r.PinLat, r.PinLng), addr = at(r.GeoLat, r.GeoLng);
        openMap(r.DoctorName, `${Ipd.dt(r.VisitDate)} · ${r.ExecutiveName} · ${STATUS[r.VisitStatus] || r.VisitStatus}${r.DistanceM != null ? ' · ' + metres(r.DistanceM) + ' from the clinic' : ''}`, g => {
            if (pin) L.marker(pin, { icon: dot(COLORS.clinic, 16) }).bindTooltip('Clinic location (' + (r.PinSource === 'ADDRESS' ? 'from the address' : 'GPS') + ')').addTo(g);
            if (addr && r.PinSource === 'GPS') L.marker(addr, { icon: dot(COLORS.address) }).bindTooltip('The typed address on the map').addTo(g);
            if (phone) {
                L.marker(phone, { icon: dot(COLORS.phone, 16) }).bindTooltip('The phone at the visit').addTo(g);
                if (r.AccuracyM) L.circle(phone, { radius: Number(r.AccuracyM), color: COLORS.phone, weight: 1, fillOpacity: .08 }).addTo(g);
            }
            if (pin) L.circle(pin, { radius: 100, color: COLORS.clinic, weight: 1, dashArray: '4', fillOpacity: .04 }).bindTooltip('100 m around the clinic').addTo(g);
            if (phone && pin) L.polyline([phone, pin], { color: '#64748b', weight: 2, dashArray: '6' }).addTo(g);
        }, [['phone', 'Phone at the visit'], ['clinic', 'Clinic location (circle = 100 m)'], ['address', 'Typed address']]);
    }

    function doctorMap(r) {
        const pin = at(r.PinLat, r.PinLng), addr = at(r.GeoLat, r.GeoLng), phone = at(r.PhoneLatAtPin, r.PhoneLngAtPin);
        openMap(r.DoctorName, [r.ClinicName, r.Address].filter(Boolean).join(' · '), g => {
            if (pin) L.marker(pin, { icon: dot(COLORS.clinic, 16) }).bindTooltip('Clinic location (' + (r.PinSource === 'ADDRESS' ? 'from the address' : 'GPS') + ')').addTo(g);
            if (addr && (!pin || r.PinSource === 'GPS')) L.marker(addr, { icon: dot(COLORS.address) }).bindTooltip('The typed address on the map').addTo(g);
            if (phone) L.marker(phone, { icon: dot(COLORS.phone) }).bindTooltip('Where the phone was when the location was saved from the address').addTo(g);
            if (pin && addr && r.PinSource === 'GPS') L.polyline([pin, addr], { color: '#64748b', weight: 2, dashArray: '6' }).addTo(g);
        }, [['clinic', 'Clinic location'], ['address', 'Typed address'], ['phone', 'Phone when saved (address pin)']]);
    }

    async function dayMap(dayId) {
        try {
            const d = await Ipd.get(P.base + 'RouteData?dayId=' + dayId);
            const day = d.day || {}, pts = (d.points || []).filter(p => !p.IsMock).map(p => [Number(p.Latitude), Number(p.Longitude)]);
            const start = at(day.StartLat, day.StartLng), end = at(day.EndLat, day.EndLng);
            const line = [start, ...pts, end].filter(Boolean);
            openMap(`${day.ExecutiveName} · ${Ipd.date(day.DutyDate)}`, `${Ipd.dt(day.StartDate)} to ${day.EndDate ? Ipd.dt(day.EndDate) : 'still in the field'} · ${(d.points || []).length} route point(s) · ${(d.visits || []).length} visit(s)`, g => {
                if (line.length > 1) L.polyline(line, { color: COLORS.route, weight: 4, opacity: .8 }).addTo(g);
                pts.forEach(p => L.circleMarker(p, { radius: 3, color: COLORS.route, weight: 1, fillOpacity: .9 }).addTo(g));
                if (start) L.marker(start, { icon: dot(COLORS.start, 16) }).bindTooltip('Field day started').addTo(g);
                if (end) L.marker(end, { icon: dot(COLORS.end, 16) }).bindTooltip('Field day ended').addTo(g);
                (d.visits || []).forEach(v => {
                    const ph = at(v.VisitLat, v.VisitLng), pn = at(v.PinLat, v.PinLng);
                    if (pn) L.marker(pn, { icon: dot(COLORS.clinic, 14) }).bindTooltip(`${v.DoctorName} - clinic`).addTo(g);
                    if (ph) L.marker(ph, { icon: dot(COLORS.phone, 12) }).bindTooltip(`${Ipd.dt(v.VisitDate)} · ${v.DoctorName} · ${STATUS[v.VisitStatus] || v.VisitStatus}${v.DistanceM != null ? ' · ' + metres(v.DistanceM) : ''}`).addTo(g);
                });
            }, [['start', 'Start'], ['end', 'End'], ['route', 'Route'], ['phone', 'Visit (phone)'], ['clinic', 'Clinic']]);
        } catch (e) { Ipd.toast(e.message, 'error'); }
    }

    // ── Excel ──────────────────────────────────────────────────────────────────────────────────────────────────
    function exportExcel() {
        if (!data.length) { Ipd.toast('Nothing to export.', 'info'); return; }
        let head, rows;
        if (tab === 'visits') {
            head = ['Date & time', 'Executive', 'Code', 'Doctor', 'Mobile', 'Clinic', 'Address', 'Visit status', 'Distance from clinic (m)', 'GPS accuracy (m)', 'Clinic location', 'Clinic location warning', 'Pin from address (m)', 'Visit warning', 'Outcome', 'Notes', 'Phone lat', 'Phone lng', 'Clinic lat', 'Clinic lng'];
            rows = data.map(r => [Ipd.dt(r.VisitDate), r.ExecutiveName, r.ExecutiveCode, r.DoctorName, r.DoctorMobile, r.ClinicName, r.Address, STATUS[r.VisitStatus] || r.VisitStatus, r.DistanceM, r.AccuracyM,
                r.PinLat == null ? 'Not saved' : (r.PinSource === 'ADDRESS' ? 'From the address' : 'GPS'), r.PinStatus === 'FLAGGED' ? r.PinFlagReason : '', r.AddressDistanceM, r.FlagReason, OUTCOME[r.Outcome] || r.Outcome, r.Notes,
                r.VisitLat, r.VisitLng, r.PinLat, r.PinLng]);
        } else if (tab === 'days') {
            head = ['Date', 'Executive', 'Code', 'Start', 'End', 'Hours', 'Km covered', 'Route points', 'Fake points', 'Visits', 'Verified', 'Unconfirmed', 'Outside'];
            rows = data.map(r => [Ipd.date(r.DutyDate), r.ExecutiveName, r.ExecutiveCode, Ipd.dt(r.StartDate), r.IsOpen ? 'Still in the field' : Ipd.dt(r.EndDate), Number(r.Hours), Number(r.Km), r.Points, r.MockPoints, r.Visits, r.Verified, r.Unconfirmed, r.Outside]);
        } else {
            head = ['Doctor', 'Mobile', 'Speciality', 'Clinic', 'Address', 'Address on the map', 'Executive', 'Code', 'Stage', 'Clinic location', 'Status', 'Warning', 'Pin from address (m)', 'Visits', 'Verified', 'Last visit', 'Added', 'Doctor Master', 'Clinic lat', 'Clinic lng'];
            rows = data.map(r => [r.DoctorName, r.DoctorMobile, r.SpecialityName, r.ClinicName, r.Address, r.GeoAddress, r.ExecutiveName, r.ExecutiveCode, STAGE[r.Stage] || r.Stage,
                r.PinLat == null ? 'Not saved' : (r.PinSource === 'ADDRESS' ? 'From the address' : 'GPS'), PIN[r.PinStatus] || r.PinStatus || '', r.PinStatus === 'FLAGGED' ? r.PinFlagReason : '', r.AddressDistanceM,
                r.Visits, r.Verified, r.LastVisitDate ? Ipd.date(r.LastVisitDate) : '', Ipd.date(r.CreatedDate), r.DoctorId ? (r.DoctorActive ? 'Approved' : 'Waiting') : '', r.PinLat, r.PinLng]);
        }
        const ws = XLSX.utils.aoa_to_sheet([head, ...rows]), wb = XLSX.utils.book_new();
        XLSX.utils.book_append_sheet(wb, ws, { visits: 'Visits', days: 'Field days', doctors: 'Doctors' }[tab]);
        XLSX.writeFile(wb, `Marketing_Field_${tab}_${iso(new Date())}.xlsx`);
    }

    // ── wiring ─────────────────────────────────────────────────────────────────────────────────────────────────
    function setTab(t) {
        tab = t;
        document.querySelectorAll('[data-tab]').forEach(b => b.classList.toggle('active', b.dataset.tab === t));
        document.querySelectorAll('.mf-only-visits').forEach(x => x.classList.toggle('d-none', t !== 'visits'));
        document.querySelectorAll('.mf-only-doctors').forEach(x => x.classList.toggle('d-none', t !== 'doctors'));
        document.querySelectorAll('.mf-dates').forEach(x => x.classList.toggle('d-none', t === 'doctors'));
        document.querySelector('.mf-search').classList.toggle('d-none', t === 'days');
        data = []; load();
    }

    document.addEventListener('DOMContentLoaded', () => {
        const now = new Date();
        $('mfFrom').value = iso(new Date(now.getFullYear(), now.getMonth(), 1));
        $('mfTo').value = iso(now);
        document.querySelectorAll('[data-tab]').forEach(b => b.addEventListener('click', () => setTab(b.dataset.tab)));
        $('mfShow').addEventListener('click', load);
        $('mfSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
        $('mfExport').addEventListener('click', exportExcel);
        $('mfRows').addEventListener('click', e => {
            const b = e.target.closest('button'); if (!b) return;
            if (b.dataset.visit) visitMap(data[+b.dataset.visit]);
            else if (b.dataset.doctor) doctorMap(data[+b.dataset.doctor]);
            else if (b.dataset.day) dayMap(b.dataset.day);
        });
        load();
    });
})();
