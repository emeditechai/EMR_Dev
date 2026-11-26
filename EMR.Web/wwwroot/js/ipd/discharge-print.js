/* IPD discharge prints (Phase 7, SQLScripts/2557). Data: window.DisPrint (IpdDischargeController.Print*), kind =
   summary (discharge / death summary, NABH) | lama (LAMA / DAMA form) | death (MCCD Form 4 / 4A) | gatepass. */
(function () {
    'use strict';
    const P = window.DisPrint || {}, h = P.header || {}, box = document.getElementById('disPrint');
    const E = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const pre = v => E(v).replace(/\n/g, '<br>');
    const dt = v => v ? new Date(v).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
    const dd = v => v ? new Date(v).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '';
    const rs = v => '₹' + Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const one = r => (r || [])[0] || null;
    const s = one(P.summary), d = one(P.discharge), l = one(P.lama), r = one(P.death), bill = one(P.bill), fu = P.followUps || [];
    const TYPE = { NORMAL: 'Normal', LAMA: 'LAMA', DAMA: 'DAMA', ABSCONDED: 'Absconded', TRANSFER: 'Transfer to another hospital', DEATH: 'Death' };
    const COND = { STABLE: 'Stable', IMPROVED: 'Improved', UNCHANGED: 'Unchanged', DETERIORATED: 'Deteriorated', CRITICAL: 'Critical', EXPIRED: 'Expired' };
    const row = (k1, v1, k2, v2) => `<tr><td class="k">${k1}</td><td>${v1 || ''}</td><td class="k">${k2}</td><td>${v2 || ''}</td></tr>`;
    const patient = () => `<table class="info">${row('Patient', '<b>' + E(h.PatientName) + '</b>', 'UHID / IP No.', `<span class="mono">${E(h.PatientCode)} / ${E(h.IpNo)}</span>`)}
        ${row('Age / Sex', E(h.AgeText) + ' / ' + E(h.Gender), 'Ward / bed', E([h.WardName, h.BedNumber].filter(Boolean).join(' / ')))}
        ${row('Consultant', E(h.ConsultantName), 'Department', E(h.DepartmentName))}
        ${row('Admitted', dt(h.AdmissionAt), (d && d.DischargeType === 'DEATH') ? 'Died' : 'Discharged', dt(r ? r.DeathAt : h.DischargeAt) || (d && d.PlannedAt ? 'planned ' + dt(d.PlannedAt) : ''))}
        ${row('Discharge type', E(d ? TYPE[d.DischargeType] : ''), h.IsMlc ? 'MLC No.' : 'Payer', h.IsMlc ? E(h.MlcNo) : E(h.PayerType))}</table>`;
    const sec = (t, body) => body && String(body).trim() ? `<div class="sec-h">${t}</div><div>${body}</div>` : '';
    const signImg = p => p ? `<img src="${E(p)}" style="max-height:40px;display:block;margin:0 auto 2px" alt="" />` : '';

    function summary() {
        if (!s) return '<p>No discharge summary is written yet.</p>';
        const dx = s.Diagnoses ? JSON.parse(s.Diagnoses) : [], meds = s.Medicines ? JSON.parse(s.Medicines) : [];
        const K = { PRIMARY: 'Primary', SECONDARY: 'Secondary', COMORBID: 'Co-morbidity' };
        let x = patient();
        x += `<div class="sec-h">Final diagnosis</div><table class="grid"><tr><th style="width:18%">Type</th><th style="width:14%">ICD-10</th><th>Diagnosis</th></tr>
            ${dx.map(z => `<tr><td>${K[z.kind] || ''}</td><td class="mono">${E(z.code)}</td><td>${E(z.title)}</td></tr>`).join('')}</table>`;
        x += sec('Presenting complaints / reason for admission', pre(s.PresentingComplaints)) + sec('History of present illness', pre(s.HistoryOfIllness)) + sec('Past history', pre(s.PastHistory))
           + sec('Allergies', E(s.Allergies) || 'No known allergies') + sec('Examination at admission', pre(s.Examination)) + sec('Key investigations', pre(s.Investigations))
           + sec('Procedures / surgeries', pre(s.Procedures)) + sec('Course in hospital', pre(s.CourseInHospital))
           + sec('Condition at ' + (s.SummaryType === 'DEATH' ? 'death' : 'discharge'), `<b>${E(COND[s.ConditionAtDischarge] || '')}</b>${s.ConditionNotes ? ' – ' + pre(s.ConditionNotes) : ''}`);
        if (r) x += sec('Cause of death', `I (a) ${E(r.CauseImmediate)}${r.CauseAntecedent ? '<br>&nbsp;&nbsp;(b) due to ' + E(r.CauseAntecedent) : ''}${r.CauseUnderlying ? '<br>&nbsp;&nbsp;(c) due to ' + E(r.CauseUnderlying) : ''}${r.OtherConditions ? '<br>II ' + E(r.OtherConditions) : ''} · time of death ${dt(r.DeathAt)}`);
        if (meds.length) x += `<div class="sec-h">Medicines on discharge</div><table class="grid"><tr><th>#</th><th>Drug</th><th>Dose</th><th>Route</th><th>Frequency</th><th>Duration</th><th>Instructions</th></tr>
            ${meds.map((m, i) => `<tr><td>${i + 1}</td><td><b>${E(m.drug)}</b></td><td>${E(m.dose)}</td><td>${E(m.route)}</td><td>${E(m.frequency)}</td><td>${E(m.duration)}</td><td>${E(m.instructions)}</td></tr>`).join('')}</table>`;
        x += sec('Diet', E(s.Diet)) + sec('Activity', E(s.Activity)) + sec('Advice on discharge', pre(s.Advice)) + sec('Come back at once if', pre(s.WarningSigns));
        const fus = fu.map(f => `${dd(f.FollowUpDate)}${f.SlotTime ? ' at ' + E(f.SlotTime) : ''} – ${E(f.DoctorName)}${f.Notes ? ' (' + E(f.Notes) + ')' : ''}`).join('<br>');
        x += sec('Follow-up', fus || E(s.FollowUp)) + sec('Emergency contact', `<b>${E(s.EmergencyContact)}</b>`);
        x += `<div class="sign"><div>Patient / attendant<br>(summary received and explained)</div><div>${signImg((P.signUrls || {}).summary)}${E(s.SignedByDoctorName || h.ConsultantName)}${s.SignedByRegNo ? '<br>Reg. No. ' + E(s.SignedByRegNo) : ''}<br>Consultant${s.SignedAt ? ' · signed ' + dt(s.SignedAt) : ''}${s.SignedOnBehalf ? '<br><i>e-signed on behalf by ' + E(s.SignedByUserName) + ' (' + E(s.OnBehalfReason) + ')</i>' : ''}</div></div>
            <div class="note">Version ${s.Version}${s.AmendReason ? ' · amended: ' + E(s.AmendReason) : ''} · ${s.Status === 'SIGNED' ? 'signed' : s.Status === 'DRAFT' ? 'DRAFT – not signed' : 'superseded by a later version'}</div>`;
        return x;
    }

    function lama() {
        if (!l) return '<p>No LAMA / DAMA form is recorded.</p>';
        const what = l.Kind === 'LAMA' ? 'leave the hospital against medical advice' : 'be discharged against medical advice';
        return patient() + `<div class="sec-h">Declaration</div>
            <p>I, <b>${E(l.SignedByName)}</b>${l.SignedByRelation ? ' (' + E(l.SignedByRelation) + ' of the patient)' : ''}, wish to ${what} on ${dt(l.RecordedAt)}, for the following reason:</p>
            <p style="border:1px solid #d1d5db;padding:6px">${pre(l.Reason)}</p>
            <div class="sec-h">Risks explained to me by ${E(l.ExplainedByDoctorName)}${l.ExplainedByRegNo ? ' (Reg. No. ' + E(l.ExplainedByRegNo) + ')' : ''}</div>
            <p style="border:1px solid #d1d5db;padding:6px">${pre(l.RisksExplained)}</p>
            <p>The risks have been explained to me in a language I understand. I take the decision of my own free will and accept full responsibility for its consequences.</p>
            <div class="sign"><div>${signImg(l.SignaturePath)}${E(l.SignedByName)}<br>Patient / attendant (signature or thumb impression)</div>
            <div>${signImg(l.WitnessSignaturePath)}${E(l.WitnessName)}<br>Witness</div><div>${signImg(l.DoctorSignaturePath)}${E(l.ExplainedByDoctorName)}<br>Doctor</div></div>`;
    }

    function mccd() {
        if (!r) return '<p>No death is recorded.</p>';
        const M = { NATURAL: 'Natural', ACCIDENT: 'Accident', SUICIDE: 'Suicide', HOMICIDE: 'Homicide', PENDING: 'Pending investigation' };
        const PG = { NOT_PREGNANT: 'Not pregnant', PREGNANT: 'Pregnant at the time of death', WITHIN_42D: 'Within 42 days of delivery / abortion', NA: 'Not applicable' };
        return `<div class="c b">FORM No. ${E(r.FormType)} · ${r.FormType === '4A' ? 'non-institutional deaths' : 'hospital in-patient deaths'} (See Rule 7 of the Registration of Births and Deaths Rules)</div>
            <table class="info" style="margin-top:6px">${row('Name of the deceased', '<b>' + E(h.PatientName) + '</b>', 'Death register no.', `<span class="mono">${E(r.DeathRegNo)}</span>`)}
            ${row('Sex', E(h.Gender), 'Age', E(h.AgeText))}${row('Father / husband', E(h.GuardianName), 'UHID / IP No.', `<span class="mono">${E(h.PatientCode)} / ${E(h.IpNo)}</span>`)}
            ${row('Address', E(h.Address), 'Date &amp; time of death', '<b>' + dt(r.DeathAt) + '</b>')}${row('Admitted', dt(h.AdmissionAt), 'Ward / bed', E([h.WardName, h.BedNumber].filter(Boolean).join(' / ')))}</table>
            <div class="sec-h">Cause of death</div><table class="grid"><tr><th style="width:42%"></th><th>Disease or condition</th><th style="width:20%">Interval between onset and death</th></tr>
            <tr><td><b>I.</b> Immediate cause<br><small>disease or condition directly leading to death</small></td><td>(a) ${E(r.CauseImmediate)}</td><td>${E(r.IntervalImmediate)}</td></tr>
            <tr><td>Antecedent cause<br><small>morbid conditions giving rise to the above cause</small></td><td>(b) due to ${E(r.CauseAntecedent)}</td><td>${E(r.IntervalAntecedent)}</td></tr>
            <tr><td>Underlying cause<br><small>stating the underlying condition last</small></td><td>(c) due to ${E(r.CauseUnderlying)}${r.UnderlyingIcd ? ` <span class="mono">[${E(r.UnderlyingIcd)}]</span>` : ''}</td><td>${E(r.IntervalUnderlying)}</td></tr>
            <tr><td><b>II.</b> Other significant conditions contributing to the death, not related to the disease causing it</td><td colspan="2">${E(r.OtherConditions)}</td></tr></table>
            <table class="info" style="margin-top:6px">${row('Manner of death', E(M[r.MannerOfDeath]), 'Post-mortem', r.PostMortem ? 'Yes' : 'No')}
            ${row('Police intimated', r.PoliceIntimated ? 'Yes – ' + E(r.PoliceStation) : 'No', 'Medico-legal case', h.IsMlc ? 'Yes – ' + E(h.MlcNo) : 'No')}
            ${/^f/i.test(h.Gender || '') ? row('If female, pregnancy', E(PG[r.PregnancyStatus]), 'Delivery involved', r.DeliveryInvolved ? 'Yes' : 'No') : ''}
            ${row('Body handed over to', E(r.BodyHandedTo) + (r.BodyHandedRelation ? ' (' + E(r.BodyHandedRelation) + ')' : ''), 'Handed over at', dt(r.BodyHandedAt))}</table>
            <p class="note">I hereby certify that to the best of my knowledge and belief the cause of death is as stated above.</p>
            <div class="sign"><div>Received the body: ${E(r.BodyHandedTo)}</div><div>${signImg((P.signUrls || {}).death)}${E(r.CertifiedByDoctorName)}${r.CertifiedByRegNo ? '<br>Reg. No. ' + E(r.CertifiedByRegNo) : ''}<br>Medical attendant certifying the cause of death</div></div>`;
    }

    function gatePass() {
        if (!d || !d.GatePassNo) return '<p>The gate pass is not issued yet.</p>';
        return `<div class="page-body"><table class="info">${row('Gate pass no.', `<b class="mono">${E(d.GatePassNo)}</b>`, 'Date &amp; time', '<b>' + dt(d.GatePassAt) + '</b>')}
            ${row('Patient', '<b>' + E(h.PatientName) + '</b>', 'UHID / IP No.', `<span class="mono">${E(h.PatientCode)} / ${E(h.IpNo)}</span>`)}
            ${row('Age / Sex', E(h.AgeText) + ' / ' + E(h.Gender), 'Ward / bed', E([h.WardName, h.BedNumber].filter(Boolean).join(' / ')))}
            ${row('Admitted', dt(h.AdmissionAt), 'Discharge type', E(TYPE[d.DischargeType]))}
            ${row('Handed over to', E(d.HandedOverTo) + (d.HandedOverRelation ? ' (' + E(d.HandedOverRelation) + ')' : ''), 'Phone', E(d.HandedOverPhone))}
            ${row('Transport', E(d.TransportMode), 'Final bill', bill ? `<span class="mono">${E(bill.BillNo)}</span> ${rs(bill.Net)}` : '')}
            ${row('Billing', d.IsCreditDischarge ? `<b>CREDIT DISCHARGE</b> – ${rs(d.CreditAmount)} due: ${E(d.CreditReason)}` : 'Cleared – no dues', 'Remarks', E(d.GatePassRemarks))}</table>
            <div class="note">All clearances (pharmacy, LAB, nursing${h.PayerType === 'INSURANCE' ? ', TPA' : ''}) and the final bill were completed before this pass was issued. Security: allow the patient / attendant to leave.</div>
            <div class="sign"><div>Patient / attendant</div><div>Billing / discharge desk<br>${E(d.GatePassByName)}</div><div>Security</div></div></div>`;
    }

    box.innerHTML = P.kind === 'lama' ? lama() : P.kind === 'death' ? mccd() : P.kind === 'gatepass' ? gatePass() : summary();
})();
