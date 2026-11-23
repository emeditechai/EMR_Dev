/* IPD > ICU Board (Phase 8, SQLScripts/2493). Config window.IcuBoard = { base, patient, canPatient }. Refreshes every minute. */
(function () {
    'use strict';
    const P = window.IcuBoard, E = v => Ipd.esc(v), $ = id => document.getElementById(id);
    const ABN = { Hr: [50, 120], Sbp: [90, 180], Map: [65, 110], Rr: [10, 30], SpO2: [92, 100], TempC: [36, 38.3], Gcs: [9, 15] };
    const bad = (k, x) => x != null && ABN[k] && (Number(x) < ABN[k][0] || Number(x) > ABN[k][1]);
    const vt = (label, k, val, raw) => `<div><small>${label}</small><span class="${bad(k, raw) ? 'abn' : ''}">${val == null || val === '' ? '—' : E(val)}</span></div>`;

    async function load() {
        let D;
        try { D = await Ipd.get(P.base + 'BoardData'); } catch (e) { $('cards').innerHTML = `<div class="alert alert-danger">${E(e.message)}</div>`; return; }
        const pts = D.patients || [], beds = (D.beds || [])[0] || {}, rets = D.returns || [];
        const late = pts.filter(p => p.MinutesSinceObs == null || p.MinutesSinceObs > 60);
        const k = (c, label, val, sub) => `<div class="ipdx-kpi"><small>${label}</small><b style="color:${c}">${val}</b><span class="small text-muted">${sub}</span></div>`;
        $('kpis').innerHTML = k('#6d28d9', 'ICU patients', pts.length, `${beds.Occupied || 0} of ${beds.IcuBeds || 0} ICU beds`)
            + k('#7c3aed', 'On ventilator', pts.filter(p => p.OnVentilator).length, 'ventilator / NIV')
            + k('#1d4ed8', 'On infusions', pts.filter(p => p.RunningInfusions > 0).length, 'running infusions')
            + k('#b45309', 'Observation due', late.length, 'none in the last hour')
            + k('#b91c1c', 'Returns < 48 h', rets.length, 'last 30 days');
        $('cards').innerHTML = pts.length ? pts.map(p => `<div class="icu-card ${p.IsReturn48h ? 'ret' : (p.MinutesSinceObs == null || p.MinutesSinceObs > 60) ? 'late' : ''}" data-id="${p.AdmissionId}">
            <div class="d-flex justify-content-between"><span class="bed">${E(p.WardName || '')} · ${E(p.BedNumber)}</span><span class="small text-muted">${Number(p.IcuHours || 0).toFixed(0)} h in ICU</span></div>
            <div class="name">${E(p.PatientName)} <small class="text-muted fw-normal">${E(p.AgeText || '')} ${E(p.Gender || '')}</small></div>
            <div class="sub">${E(p.IpNo)} · ${E(p.ConsultantName || '')}${p.ProvisionalDiagnosis ? ' · ' + E(p.ProvisionalDiagnosis) : ''}</div>
            <div class="mt-1">${p.OnVentilator ? '<span class="icu-badge vent">Ventilator</span> ' : ''}${p.RunningInfusions ? `<span class="icu-badge vent" title="${E(p.InfusionDrugs)}">${p.RunningInfusions} infusion(s)</span> ` : ''}
                ${p.IsReturn48h ? '<span class="icu-badge ret">Return &lt; 48 h</span> ' : ''}${p.MinutesSinceObs == null ? '<span class="icu-badge late">No observation</span>' : p.MinutesSinceObs > 60 ? `<span class="icu-badge late">Last obs ${p.MinutesSinceObs} min ago</span>` : ''}</div>
            <div class="icu-vitals">${vt('HR', 'Hr', p.Hr, p.Hr)}${vt('BP', 'Sbp', p.Sbp != null ? p.Sbp + '/' + p.Dbp : null, p.Sbp)}${vt('MAP', 'Map', p.Map, p.Map)}${vt('SpO2', 'SpO2', p.SpO2 != null ? Number(p.SpO2) : null, p.SpO2)}
                ${vt('RR', 'Rr', p.Rr, p.Rr)}${vt('Temp', 'TempC', p.TempC != null ? Number(p.TempC) : null, p.TempC)}${vt('GCS', 'Gcs', p.Gcs, p.Gcs)}${vt('FiO2', '', p.FiO2 != null ? p.FiO2 + (p.VentMode ? ' ' + p.VentMode : '') : null, null)}</div>
          </div>`).join('') : '<div class="alert alert-light border">No patient in an ICU bed.</div>';
        $('returns').innerHTML = rets.length ? rets.map(r => `<tr><td>${E(r.PatientName)}</td><td>${E(r.IpNo)}</td><td>${Ipd.dt(r.PrevOutAt)}</td><td>${Ipd.dt(r.InAt)}</td><td class="text-end">${Number(r.HoursSincePrev).toFixed(1)}</td></tr>`).join('')
            : '<tr><td colspan="5" class="text-muted small">None in the last 30 days.</td></tr>';
        $('asOf').textContent = 'As of ' + new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
    }
    $('cards').addEventListener('click', e => { const c = e.target.closest('.icu-card'); if (c && P.canPatient) window.location.href = P.patient + c.dataset.id + '?tab=icu'; });
    $('refresh').addEventListener('click', load);
    load(); setInterval(load, 60000);
})();
