/* IPD > Pre-Authorisations (Phase 6, SQLScripts/2539-2542): worklist with the IRDAI clock; record the TPA's answer. Config: window.PreAuthPage */
(function () {
    'use strict';
    const P = window.PreAuthPage, $ = id => document.getElementById(id), esc = v => Ipd.esc(v), money = v => Ipd.money(v);
    let rows = [], links = {}, tpasLoaded = false;

    async function load() {
        const q = new URLSearchParams({ view: $('fView').value });
        if ($('fTpa').value) q.set('insuranceTpaId', $('fTpa').value);
        if ($('fQ').value.trim()) q.set('search', $('fQ').value.trim());
        if ($('fView').value === 'ALL') { if ($('fFrom').value) q.set('fromDate', $('fFrom').value); if ($('fTo').value) q.set('toDate', $('fTo').value); }
        try {
            const d = await Ipd.get(P.base + 'PreAuthList?' + q);
            rows = d.rows || []; links = d.links || {};
            if (!tpasLoaded) { $('fTpa').insertAdjacentHTML('beforeend', (d.tpas || []).map(t => `<option value="${t.InsuranceTpaId}">${esc(t.Name)}</option>`).join('')); tpasLoaded = true; }
            kpis(d.kpi || {}); render();
            $('asOf').textContent = '· as of ' + new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
        } catch (e) { $('rows').innerHTML = `<tr><td colspan="9" class="text-danger small p-3">${esc(e.message)}</td></tr>`; }
    }

    function kpis(k) {
        const pct = k.DecidedThisMonth ? Math.round(100 * (k.DecidedInTime || 0) / k.DecidedThisMonth) : null;
        const t = (c, label, val, sub) => `<div class="ipdx-kpi"><small>${label}</small><b style="color:${c}">${val}</b><span class="small text-muted">${sub}</span></div>`;
        $('kpis').innerHTML = t('#1d4ed8', 'Waiting for TPA', k.WaitingTpa || 0, 'request / enhancement / final')
            + t('#b91c1c', 'Past the time limit', k.Breached || 0, '1 h decision · 3 h final')
            + t('#b45309', 'Open TPA queries', k.OpenQueries || 0, 'reply needed')
            + t('#475569', 'Drafts', k.Drafts || 0, 'request not sent yet')
            + t('#166534', 'Decided in 1 h', pct == null ? '–' : pct + ' %', `this month${k.AvgDecisionMinutes != null ? ' · avg ' + Math.round(k.AvgDecisionMinutes) + ' min' : ''}`)
            + t('#3730a3', 'Final authorisation', k.AvgFinalMinutes != null ? Math.round(k.AvgFinalMinutes) + ' min' : '–', 'average this month');
    }

    function render() {
        if (!rows.length) { $('rows').innerHTML = '<tr><td colspan="9" class="text-muted small p-3">Nothing here.</td></tr>'; return; }
        $('rows').innerHTML = rows.map((r, i) => {
            const steps = P.can.record ? Tpa.nextSteps({ ...r, IsLive: !['REJECTED', 'CANCELLED'].includes(r.Status), UsedByBill: false })
                .filter(s => ['APPROVAL', 'QUERY', 'QUERY_REPLY', 'REJECTION', 'FINAL_APPROVAL'].includes(s))
                .map(s => `<button type="button" class="btn btn-sm ${Tpa.STEPS[s].cls} py-0" data-i="${i}" data-step="${s}" title="${esc(Tpa.STEPS[s].title)}"><i class="bi ${Tpa.STEPS[s].icon}"></i></button>`).join(' ') : '';
            const open = links[r.AdmissionId] && P.can.patient ? `<a class="btn btn-sm btn-light border py-0" href="${esc(links[r.AdmissionId])}" title="Open the patient's Insurance / TPA tab"><i class="bi bi-box-arrow-up-right"></i></a>` : '';
            const decided = r.DecisionMinutes != null ? `<div class="small text-muted">decided in ${Tpa.minutes(r.DecisionMinutes)}</div>` : '';
            return `<tr class="${r.Breached ? 'table-danger' : ''}">
                <td><b>${esc(r.PreAuthNo)}</b>${r.TpaRefNo ? `<div class="small text-muted">${esc(r.TpaRefNo)}</div>` : ''}</td>
                <td>${esc(r.PatientName)}<div class="small text-muted">${esc(r.IpNo)} · ${esc(r.PatientCode)}${r.BedNumber ? ' · bed ' + esc(r.BedNumber) : ''}</div></td>
                <td>${esc(r.PayerName || '')}<div class="small text-muted">${esc(r.PayerKind || '')}</div></td>
                <td>${Tpa.pill(r.Status)}</td>
                <td>${Tpa.clock(r.WaitingMinutes, r.SlaMinutes) || decided}</td>
                <td class="text-end">${money(r.FinalRequestedAmount || r.EnhancementRequested || r.RequestedAmount)}</td>
                <td class="text-end">${money(r.FinalApprovedAmount || r.ApprovedAmount)}</td>
                <td class="small">${esc(r.LastQuery || '')}</td>
                <td class="text-end text-nowrap no-print">${steps} ${open}</td></tr>`;
        }).join('');
        document.querySelectorAll('#rows [data-step]').forEach(b => b.addEventListener('click', () => {
            const r = rows[+b.dataset.i];
            const hint = { APPROVAL: r.EnhancementRequested || r.RequestedAmount, FINAL_APPROVAL: r.FinalRequestedAmount }[b.dataset.step] ?? '';
            Tpa.stepDialog(b.dataset.step, r, { url: P.base, admissionId: r.AdmissionId, amountHint: hint, onDone: load });
        }));
    }

    $('fView').addEventListener('change', () => { const all = $('fView').value === 'ALL'; $('fFrom').classList.toggle('d-none', !all); $('fTo').classList.toggle('d-none', !all); load(); });
    ['fTpa', 'fFrom', 'fTo'].forEach(id => $(id).addEventListener('change', load));
    let t; $('fQ').addEventListener('input', () => { clearTimeout(t); t = setTimeout(load, 350); });
    $('reload').addEventListener('click', load);
    load();
    setInterval(() => { if (!document.hidden && !document.querySelector('.swal2-container')) load(); }, 60000);   // the clock moves
})();
