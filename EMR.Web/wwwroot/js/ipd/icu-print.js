/* ICU chart print (Phase 8, SQLScripts/2493): flowsheet of the window, infusions, devices, ICU stays and intake / output.
   Data: window.IcuPrint (IpdIcuController.PrintChart). */
(function () {
    'use strict';
    const P = window.IcuPrint || {}, h = P.header || {}, c = P.chart || {};
    const E = v => String(v ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
    const dt = v => v ? new Date(v).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : '';
    const ABN = { Hr: [50, 120], Sbp: [90, 180], Map: [65, 110], Rr: [10, 30], SpO2: [92, 100], TempC: [36, 38.3], Gcs: [9, 15], Glucose: [70, 250] };
    const bad = (k, x) => x != null && ABN[k] && (Number(x) < ABN[k][0] || Number(x) > ABN[k][1]);
    const s = (c.state || [])[0] || {}, obs = c.observations || [];
    const rows = [['Hr', 'HR'], ['BP', 'BP'], ['Map', 'MAP'], ['Rr', 'RR'], ['SpO2', 'SpO2'], ['TempC', 'Temp'], ['Cvp', 'CVP'], ['EtCo2', 'EtCO2'], ['Gcs', 'GCS'], ['Rass', 'RASS'],
        ['PainScore', 'Pain'], ['Glucose', 'Glucose'], ['IntakeMl', 'Intake ml'], ['UrineMl', 'Urine ml'], ['OtherOutputMl', 'Other out ml'], ['VentMode', 'Vent mode'],
        ['FiO2', 'FiO2'], ['Peep', 'PEEP'], ['TidalVolume', 'Vt'], ['SetRate', 'Set rate'], ['Pip', 'PIP'], ['PressureSupport', 'PS'], ['RecordedByName', 'By']];
    const val = (o, k) => k === 'BP' ? (o.Sbp != null ? o.Sbp + '/' + o.Dbp : '') : k === 'Gcs' ? (o.Gcs != null ? `${o.Gcs} (${o.GcsE}/${o.GcsV}/${o.GcsM})` : '') : (o[k] == null ? '' : (typeof o[k] === 'number' ? Number(o[k]) : o[k]));
    let x = `<table class="info"><tr><td class="k">Patient</td><td class="b">${E(h.PatientName)}</td><td class="k">UHID / IP No.</td><td class="mono">${E(h.PatientCode)} / ${E(h.IpNo)}</td></tr>
        <tr><td class="k">Age / Sex</td><td>${E(h.AgeText)} / ${E(h.Gender)}</td><td class="k">Consultant</td><td>${E(h.ConsultantDoctorName)}</td></tr>
        <tr><td class="k">Bed</td><td>${E(s.BedNumber || h.BedNumber)} · ${E(s.WardName || h.WardName)}</td><td class="k">Chart window</td><td>${dt(s.FromAt)} – ${dt(s.ToAt)}</td></tr></table>`;
    x += `<div class="sec-h">Flowsheet</div>`;
    x += obs.length ? `<table class="grid"><tr><th></th>${obs.map(o => `<th class="${o.Status === 'STRUCK' ? 'struck' : ''}">${dt(o.ObservedAt)}</th>`).join('')}</tr>
        ${rows.filter(([k]) => obs.some(o => val(o, k) !== '')).map(([k, l]) => `<tr><th>${l}</th>${obs.map(o => `<td class="${o.Status === 'STRUCK' ? 'struck' : (bad(k === 'BP' ? 'Sbp' : k, k === 'BP' ? o.Sbp : o[k]) ? 'abn' : '')}">${E(val(o, k))}</td>`).join('')}</tr>`).join('')}</table>
        ${obs.some(o => o.Status === 'STRUCK') ? `<div class="note">Struck-out entries: ${obs.filter(o => o.Status === 'STRUCK').map(o => dt(o.ObservedAt) + ' – ' + E(o.StruckReason) + ' (' + E(o.StruckByName) + ')').join('; ')}</div>` : ''}
        ${obs.some(o => o.Notes) ? `<div class="note">Notes: ${obs.filter(o => o.Notes).map(o => dt(o.ObservedAt) + ': ' + E(o.Notes)).join('; ')}</div>` : ''}` : '<div class="note">No observation in this window.</div>';
    const inf = c.infusions || [];
    if (inf.length) x += `<div class="sec-h">Infusions</div><table class="grid"><tr><th>Drug</th><th>Concentration</th><th class="r">Rate ml/h</th><th>Dose</th><th>Started</th><th>Stopped</th></tr>
        ${inf.map(i => `<tr><td>${E(i.Drug)}</td><td>${E(i.Concentration)}</td><td class="r">${Number(i.RateMlHr)}</td><td>${E(i.Dose)}</td><td>${dt(i.StartAt)}</td><td>${dt(i.StopAt)}</td></tr>`).join('')}</table>`;
    const dev = (c.devices || []).filter(d => d.Status === 'ACTIVE');
    if (dev.length) x += `<div class="sec-h">Devices</div><table class="grid"><tr><th>Device</th><th>Started</th><th>Stopped</th><th class="r">Hours</th></tr>
        ${dev.map(d => `<tr><td>${E(d.HeadName)}</td><td>${dt(d.StartAt)}</td><td>${d.StopAt ? dt(d.StopAt) : 'in use'}</td><td class="r">${Number(d.Hours).toFixed(1)}</td></tr>`).join('')}</table>`;
    const io = c.io || [];
    if (io.length) x += `<div class="sec-h">Intake / output (08:00 – 08:00)</div><table class="grid"><tr><th>Day</th><th class="r">Intake</th><th class="r">Urine</th><th class="r">Other</th><th class="r">Balance</th></tr>
        ${io.map(r => `<tr><td>${new Date(r.Day).toLocaleDateString('en-GB')}</td><td class="r">${r.IntakeMl}</td><td class="r">${r.UrineMl}</td><td class="r">${r.OtherOutputMl}</td><td class="r b">${r.BalanceMl}</td></tr>`).join('')}</table>`;
    const st = c.stays || [];
    if (st.length) x += `<div class="sec-h">ICU stays</div><table class="grid"><tr><th>#</th><th>In</th><th>Out</th><th class="r">Hours</th><th>Return within 48 h</th></tr>
        ${st.map(z => `<tr><td>${z.StayNo}</td><td>${dt(z.InAt)}</td><td>${z.OutAt ? dt(z.OutAt) : 'in ICU'}</td><td class="r">${Number(z.Hours).toFixed(1)}</td><td>${z.IsReturn48h ? 'Yes (' + Number(z.HoursSincePrev).toFixed(1) + ' h)' : ''}</td></tr>`).join('')}</table>`;
    x += `<div class="sign"><div>ICU nurse</div><div>Intensivist</div><div>Consultant</div></div>`;
    document.getElementById('icuPrint').innerHTML = x;
})();
