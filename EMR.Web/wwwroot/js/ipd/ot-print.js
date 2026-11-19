/* OT record print (Phase 8, SQLScripts/2492): booking, team, times, consents, checklists, anaesthesia record, surgery note,
   implants and OT charges of one booking. Data: window.OtPrint (IpdOtController.PrintRecord). */
(function () {
    'use strict';
    const P = window.OtPrint || {}, h = P.header || {}, id = P.bookingId;
    const E = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const dt = v => v ? new Date(v).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
    const rs = v => '₹' + Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const mine = rows => (rows || []).filter(r => r.OtBookingId === id);
    const b = mine(P.bookings)[0];
    const box = document.getElementById('otPrint');
    if (!b) { box.innerHTML = '<p>The OT booking was not found.</p>'; return; }
    const row = (k1, v1, k2, v2) => `<tr><td class="k">${k1}</td><td>${v1 || ''}</td><td class="k">${k2}</td><td>${v2 || ''}</td></tr>`;
    const PH = { PREOP: 'Pre-op checklist', SIGNIN: 'WHO Sign In', TIMEOUT: 'WHO Time Out', SIGNOUT: 'WHO Sign Out' };
    let x = `<table class="info">${row('Patient', '<b>' + E(h.PatientName) + '</b>', 'UHID / IP No.', `<span class="mono">${E(h.PatientCode)} / ${E(h.IpNo)}</span>`)}
        ${row('Age / Sex', E(h.AgeText) + ' / ' + E(h.Gender), 'Bed', E([h.WardName, h.BedNumber].filter(Boolean).join(' / ')))}
        ${row('Booking', `<span class="mono">${E(b.BookingNo)}</span> · ${E(b.Status)}`, 'OT', E(b.OtName))}
        ${row('Procedure', '<b>' + E(b.ProcedureName) + '</b>' + (b.Laterality && b.Laterality !== 'NA' ? ' (' + E(b.Laterality.toLowerCase()) + ')' : ''), 'Type', E(b.SurgeryType) + (b.IsUnplannedReturn ? ' · unplanned return: ' + E(b.ReturnReason) : ''))}
        ${row('Surgeon', E(b.SurgeonName), 'Assistant', E(b.AssistantName))}
        ${row('Anaesthetist', E(b.AnaesthetistName), 'Anaesthesia', E(b.AnaesthesiaType))}
        ${row('Scrub nurse', E(b.ScrubNurse), 'Circulating nurse', E(b.CirculatingNurse))}
        ${row('Scheduled', dt(b.ScheduledStart) + ' – ' + dt(b.ScheduledEnd), 'Pre-op diagnosis', E(b.PreOpDiagnosis))}</table>`;
    x += `<div class="sec-h">Times</div><table class="grid"><tr>${['In OT', 'Anaesthesia start', 'Incision', 'Closure', 'Anaesthesia end', 'Out of OT', 'Out of recovery'].map(t => `<th>${t}</th>`).join('')}</tr>
        <tr>${['InOtAt', 'AnaesStartAt', 'IncisionAt', 'ClosureAt', 'AnaesEndAt', 'OutOtAt', 'RecoveryOutAt'].map(k => `<td>${dt(b[k])}</td>`).join('')}</tr></table>
        <div class="note">Surgery time ${b.SurgeryMinutes ?? '—'} min · OT time ${b.OtMinutes ?? '—'} min</div>`;
    const cons = mine(P.consents);
    x += `<div class="sec-h">Consents</div>${cons.length ? `<table class="grid"><tr><th>Consent</th><th>Signed by</th><th>Date &amp; time</th></tr>${cons.map(c => `<tr><td>${E(c.ConsentType)}</td><td>${E(c.SignedByName)} ${c.SignedByRelation ? '(' + E(c.SignedByRelation) + ')' : ''}</td><td>${dt(c.SignedAt)}</td></tr>`).join('')}</table>` : '<div class="note">None recorded.</div>'}`;
    const ck = mine(P.checklists);
    x += `<div class="sec-h">Pre-op checklist and WHO Surgical Safety Checklist</div><table class="grid"><tr><th>Checklist</th><th>Completed</th><th>By</th><th>Answers</th></tr>
        ${['PREOP', 'SIGNIN', 'TIMEOUT', 'SIGNOUT'].map(p => { const c = ck.find(z => z.Phase === p); const a = c ? JSON.parse(c.Answers || '[]') : [];
            return `<tr><td>${PH[p]}</td><td>${c ? dt(c.CompletedAt) : '<i>not done</i>'}</td><td>${E(c ? c.CompletedByName : '')}</td><td style="font-size:9.5px">${a.map(q => `${E(q.code)}: <b>${E(q.answer)}</b>${q.note ? ' (' + E(q.note) + ')' : ''}`).join(' · ')}</td></tr>`; }).join('')}</table>`;
    const an = mine(P.anaesthesia)[0];
    if (an) {
        const drugs = an.Drugs ? JSON.parse(an.Drugs) : [], mon = an.Monitoring ? JSON.parse(an.Monitoring) : [];
        x += `<div class="sec-h">Anaesthesia record ${an.SignedAt ? '· signed by ' + E(an.SignedByName) + ' on ' + dt(an.SignedAt) : '· not signed'}</div><table class="info">
            ${row('Anaesthesia', E(an.AnaesthesiaType), 'ASA / Mallampati', E(an.AsaGrade) + ' / ' + E(an.Mallampati))}${row('NPO since', dt(an.NpoSince), 'Airway device', E(an.AirwayDevice))}
            ${row('Airway', E(an.Airway), 'Co-morbidities', E(an.Comorbidities))}${row('Technique', E(an.Technique), 'Pre-anaesthetic notes', E(an.PreAnaesNotes))}
            ${row('Fluids / blood given', (an.FluidsMl ?? '—') + ' / ' + (an.BloodGivenMl ?? '—') + ' ml', 'Urine / blood loss', (an.UrineMl ?? '—') + ' / ' + (an.BloodLossMl ?? '—') + ' ml')}
            ${row('Complications', E(an.Complications), 'Aldrete score', E(an.AldreteScore))}${row('Recovery', E(an.RecoveryNotes), '', '')}</table>
            ${drugs.length ? `<table class="grid" style="margin-top:4px"><tr><th>Time</th><th>Drug</th><th>Dose</th><th>Route</th></tr>${drugs.map(d => `<tr><td>${E(d.at)}</td><td>${E(d.drug)}</td><td>${E(d.dose)}</td><td>${E(d.route)}</td></tr>`).join('')}</table>` : ''}
            ${mon.length ? `<table class="grid" style="margin-top:4px"><tr><th>Time</th><th>HR</th><th>BP</th><th>SpO2</th><th>EtCO2</th><th>Temp</th></tr>${mon.map(m => `<tr><td>${E(m.at)}</td><td>${E(m.hr)}</td><td>${E(m.sbp)}/${E(m.dbp)}</td><td>${E(m.spo2)}</td><td>${E(m.etco2)}</td><td>${E(m.temp)}</td></tr>`).join('')}</table>` : ''}`;
    }
    const n = mine(P.notes)[0];
    if (n) {
        const pre = t => E(t).replace(/\n/g, '<br>');
        x += `<div class="sec-h">Surgery note ${n.Status === 'SIGNED' ? '· signed by ' + E(n.SignedByName) + ' on ' + dt(n.SignedAt) + (n.Version > 1 ? ' (version ' + n.Version + ')' : '') : '· DRAFT'}</div><table class="info">
            ${row('Procedure performed', '<b>' + E(n.ProcedurePerformed) + '</b>', 'Post-op diagnosis', E(n.PostOpDiagnosis))}${row('Indication', E(n.Indication), 'Condition', E(n.PatientCondition))}</table>
            <table class="info" style="margin-top:4px"><tr><td class="k">Findings</td><td>${pre(n.Findings)}</td></tr><tr><td class="k">Procedure details</td><td>${pre(n.ProcedureDetails)}</td></tr>
            <tr><td class="k">Specimens</td><td>${E(n.Specimens)}${n.SpecimenToHistopath ? ' · sent to histopathology' : ''}</td></tr><tr><td class="k">Drains / blood loss</td><td>${E(n.Drains)} · ${n.BloodLossMl ?? '—'} ml</td></tr>
            <tr><td class="k">Complications</td><td>${E(n.Complications)}</td></tr><tr><td class="k">Closure</td><td>${E(n.Closure)}</td></tr><tr><td class="k">Post-op plan</td><td>${pre(n.PostOpPlan)}</td></tr></table>`;
    }
    const imp = mine(P.implants).filter(i => i.Status === 'ACTIVE');
    if (imp.length) x += `<div class="sec-h">Implants, surgical items and consumables</div><table class="grid"><tr><th>Item</th><th>Manufacturer / catalogue</th><th>Batch</th><th>Serial</th><th>Expiry</th><th class="r">Qty</th></tr>
        ${imp.map(i => `<tr><td>${E(i.ItemName)} <small>(${{ IMPLANT: 'implant', SURGICAL: 'surgical', CONSUMABLE: 'consumable' }[i.ItemType] || ''})</small></td><td>${E([i.Manufacturer, i.CatalogueNo].filter(Boolean).join(' / '))}</td><td>${E(i.BatchNo)}</td><td>${E(i.SerialNo)}</td><td>${i.ExpiryDate ? new Date(i.ExpiryDate).toLocaleDateString('en-GB') : ''}</td><td class="r">${Number(i.Qty)}</td></tr>`).join('')}</table>`;
    const ch = (P.charges || []).filter(c => c.OtBookingId === id && c.Status === 'POSTED');
    if (ch.length) x += `<div class="sec-h">OT charges on the IP bill</div><table class="grid"><tr><th>Charge</th><th class="r">Net</th></tr>${ch.map(c => `<tr><td>${E(c.ItemName)}${c.IsPackageItem ? ' (in package)' : ''}</td><td class="r">${rs(c.Net)}</td></tr>`).join('')}
        <tr><td class="b">Total</td><td class="r b">${rs(ch.reduce((a, c) => a + Number(c.Net), 0))}</td></tr></table>`;
    x += `<div class="sign"><div>Surgeon<br>${E(b.SurgeonName)}</div><div>Anaesthetist<br>${E(b.AnaesthetistName || '')}</div><div>OT nurse<br>${E(b.ScrubNurse || '')}</div></div>`;
    box.innerHTML = x;
})();
