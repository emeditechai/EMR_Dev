/* IPD > Discharges (Phase 7, SQLScripts/2557). Config window.DisBoard = { base, canPatient }.
   In progress: each advised discharge with its milestones (advice, clearances, final bill, settled, summary signed, gate pass) and
   the TAT so far against the target. Discharged: the register of the period with TAT. Death register. Page URLs come from the server. */
(function () {
    'use strict';
    const C = window.DisBoard; if (!C) return;
    const E = v => Ipd.esc(v), $ = id => document.getElementById(id);
    const TYPE = { NORMAL: 'Normal', LAMA: 'LAMA', DAMA: 'DAMA', ABSCONDED: 'Absconded', TRANSFER: 'Transfer out', DEATH: 'Death' };
    const MANNER = { NATURAL: 'Natural', ACCIDENT: 'Accident', SUICIDE: 'Suicide', HOMICIDE: 'Homicide', PENDING: 'Pending investigation' };
    const hm = m => m == null ? '—' : (m >= 60 ? Math.floor(m / 60) + ' h ' + (m % 60) + ' m' : m + ' m');
    const today = new Date(), iso = d => d.toISOString().slice(0, 10);
    $('fTo').value = iso(today); $('fFrom').value = iso(new Date(today.getTime() - 30 * 864e5));

    const steps = r => [
        ['Advice', r.AdvisedAt], ['Clearances', r.ClearancesPending === 0 ? (r.ClearedAt || true) : null], ['Final bill', r.BillAt],
        ['Settled', r.BillAt && Number(r.PatientBalance || 0) <= 0.5 && Number(r.PatientBalance || 0) >= -0.5 ? (r.LastPaymentAfterBill || r.BillAt) : null],
        ['Summary', r.SummarySignedAt], ['Gate pass', r.GatePassAt]
    ].map(([t, v]) => `<span class="dis-step ${v ? 'done' : ''}" title="${v && v !== true ? E(Ipd.dt(v)) : 'pending'}"><i class="bi ${v ? 'bi-check-circle-fill' : 'bi-circle'}"></i>${t}</span>`).join('');
    const tat = r => { const over = r.TatMinutes > r.TatTargetMinutes; return `<span class="dis-tat ${over ? 'over' : 'ok'}">${hm(r.TatMinutes)}</span>`; };
    const pt = x => { const r = x.row; return `<div class="fw-semibold">${C.canPatient ? `<a href="${E(x.open)}">${E(r.PatientName)}</a>` : E(r.PatientName)}</div>
        <div class="small text-muted"><span class="font-monospace">${E(r.IpNo)}</span> · ${E(r.PatientCode)} · ${E(r.PhoneNumber)}</div>`; };

    function render(d) {
        const k = (d.kpi || [])[0] || {}, card = (c, label, val, sub) => `<div class="ipdx-kpi"><small>${label}</small><b style="color:${c}">${val}</b><span class="small text-muted">${sub}</span></div>`;
        $('kpis').innerHTML = card('#b45309', 'In progress', k.InProgress || 0, `${k.InProgressOverTarget || 0} over the ${hm(k.TatTargetMinutes)} target`)
            + card('#0f766e', 'Discharged', k.Discharged || 0, 'in the period')
            + card('#1d4ed8', 'Average TAT', hm(k.AvgTatMinutes == null ? null : Math.round(k.AvgTatMinutes)), `cash ${hm(k.AvgTatCash == null ? null : Math.round(k.AvgTatCash))} · insurance ${hm(k.AvgTatInsurance == null ? null : Math.round(k.AvgTatInsurance))}`)
            + card('#15803d', 'Within target', (k.WithinTargetPct ?? 0) + ' %', 'advice to gate pass (NABH)')
            + card('#b91c1c', 'LAMA / DAMA', `${k.LamaDama || 0} · ${k.LamaDamaPct ?? 0} %`, `${k.Absconded || 0} absconded`)
            + card('#111827', 'Deaths', `${k.Deaths || 0} · ${k.MortalityPct ?? 0} %`, 'mortality rate')
            + card('#7c3aed', 'Summary pending', k.SummaryPending || 0, `${k.SummaryBeforeGatePass || 0} signed before gate pass`)
            + card('#9a3412', 'Credit discharges', k.CreditDischarges || 0, 'balance due at gate pass');
        const pg = d.progress || [], dn = d.discharged || [], de = d.deaths || [];
        $('nProgress').textContent = pg.length; $('nDone').textContent = dn.length; $('nDeath').textContent = de.length;
        $('tProgress').innerHTML = pg.length ? `<table class="table ipdx-table mb-0"><thead><tr><th>Patient</th><th>Type</th><th>Ward / bed</th><th>Consultant</th><th>Advised</th><th>Planned</th><th>Milestones</th><th class="text-end">TAT so far</th></tr></thead><tbody>
            ${pg.map(x => { const r = x.row; return `<tr><td>${pt(x)}</td><td><span class="dis-type t-${E(r.DischargeType)}">${E(TYPE[r.DischargeType])}</span><div class="small text-muted">${E(Ipd.payer(r.PayerType))}</div></td>
                <td>${E(r.WardName)}<div class="small text-muted">${E(r.BedNumber)}</div></td><td>${E(r.ConsultantName)}</td><td>${Ipd.dt(r.AdvisedAt)}</td><td>${Ipd.dt(r.PlannedAt)}</td>
                <td><div class="dis-steps">${steps(r)}</div></td><td class="text-end">${tat(r)}</td></tr>`; }).join('')}</tbody></table>`
            : '<div class="text-muted small p-3">No discharge in progress.</div>';
        $('tDone').innerHTML = dn.length ? `<table class="table ipdx-table mb-0"><thead><tr><th>Patient</th><th>Type</th><th>Consultant</th><th>Admitted</th><th>Gate pass</th><th class="text-end">Stay</th><th>Bill</th><th>Summary signed</th><th class="text-end">TAT</th><th></th></tr></thead><tbody>
            ${dn.map(x => { const r = x.row; return `<tr><td>${pt(x)}</td><td><span class="dis-type t-${E(r.DischargeType)}">${E(TYPE[r.DischargeType])}</span>${r.IsCreditDischarge ? `<div class="small text-danger">credit ${Ipd.money(r.CreditAmount)}</div>` : ''}</td>
                <td>${E(r.ConsultantName)}</td><td>${Ipd.dt(r.AdmissionAt)}</td><td>${Ipd.dt(r.GatePassAt)}<div class="small text-muted font-monospace">${E(r.GatePassNo)}</div></td><td class="text-end">${r.StayDays} d</td>
                <td class="font-monospace small">${E(r.BillNo)}</td><td>${r.SummarySignedAt ? Ipd.dt(r.SummarySignedAt) : '<span class="text-danger small">not signed</span>'}</td><td class="text-end">${tat(r)}</td>
                <td class="text-end"><a class="btn btn-sm btn-light border" target="_blank" href="${E(x.summary)}" title="Discharge summary"><i class="bi bi-printer"></i></a></td></tr>`; }).join('')}</tbody></table>`
            : '<div class="text-muted small p-3">No discharge in the period.</div>';
        $('tDeath').innerHTML = de.length ? `<table class="table ipdx-table mb-0"><thead><tr><th>Reg. no.</th><th>Date &amp; time of death</th><th>Deceased</th><th>Age / sex</th><th>Father / husband</th><th>Cause of death (I a / b / c)</th><th>Manner</th><th>MLC / police</th><th>Certified by</th><th>Body handed to</th><th></th></tr></thead><tbody>
            ${de.map(x => { const r = x.row; return `<tr><td class="font-monospace small">${E(r.DeathRegNo)}</td><td>${Ipd.dt(r.DeathAt)}</td><td>${pt(x)}</td><td>${r.AgeYears ?? '—'} / ${E(r.Gender)}</td><td>${E(r.GuardianName)}</td>
                <td>${[r.CauseImmediate, r.CauseAntecedent, r.CauseUnderlying].filter(Boolean).map(E).join(' ← ')}${r.UnderlyingIcd ? ` <span class="badge bg-light text-dark border">${E(r.UnderlyingIcd)}</span>` : ''}</td>
                <td>${E(MANNER[r.MannerOfDeath])}${r.PostMortem ? '<div class="small">post-mortem</div>' : ''}</td><td>${r.IsMlc ? 'MLC' : ''}${r.PoliceIntimated ? `<div class="small">${E(r.PoliceStation)}</div>` : ''}</td>
                <td>${E(r.CertifiedByDoctorName)}</td><td>${E(r.BodyHandedTo)}${r.BodyHandedRelation ? ' (' + E(r.BodyHandedRelation) + ')' : ''}<div class="small text-muted">${Ipd.dt(r.BodyHandedAt)}</div></td>
                <td class="text-end"><a class="btn btn-sm btn-light border" target="_blank" href="${E(x.mccd)}" title="MCCD"><i class="bi bi-printer"></i></a></td></tr>`; }).join('')}</tbody></table>`
            : '<div class="text-muted small p-3">No death in the period.</div>';
        $('asOf').textContent = 'As of ' + Ipd.dt(new Date());
    }

    async function load() {
        const q = new URLSearchParams({ from: $('fFrom').value, to: $('fTo').value, type: $('fType').value, search: $('fSearch').value.trim() });
        try { render(await Ipd.get(C.base + 'BoardData?' + q)); }
        catch (e) { $('tProgress').innerHTML = `<div class="alert alert-danger m-2">${E(e.message)}</div>`; }
    }
    $('go').addEventListener('click', load);
    $('fSearch').addEventListener('keydown', e => { if (e.key === 'Enter') load(); });
    $('printView').addEventListener('click', () => window.print());
    load();
    setInterval(load, 60000);
})();
