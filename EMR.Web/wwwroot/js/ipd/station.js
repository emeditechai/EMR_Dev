/* IPD > Nursing Station (Phase 3, SQLScripts/2564): the patients of a station (ward), highest NEWS2 first, with what is due.
   A card opens the patient's Nursing tab. Config window.IpdStation = { base, canPatient }. */
(function () {
    'use strict';
    const C = window.IpdStation, U = window.IpdClinUi;
    if (!C || !U) return;
    const { E, $ } = U;
    const KEY = 'ipd.nursingStation';
    let D = null, first = true;

    async function load() {
        const sid = $('nsStation').value;
        try { D = await Ipd.get(`${C.base}StationData${sid ? '?stationId=' + sid : ''}`); render(); }
        catch (e) { $('nsBody').innerHTML = `<div class="col-12"><div class="alert alert-danger">${E(e.message)}</div></div>`; }
    }

    function render() {
        if (first) {
            first = false;
            const saved = localStorage.getItem(KEY) || '';
            $('nsStation').innerHTML = '<option value="">All wards</option>' + (D.stations || []).map(s => `<option value="${s.NursingStationId}">${E(s.StationName)} · ${E(s.WardName || '')} (${s.Patients})</option>`).join('');
            if (saved && (D.stations || []).some(s => String(s.NursingStationId) === saved)) { $('nsStation').value = saved; load(); return; }
        }
        const q = $('nsSearch').value.trim().toLowerCase();
        const ps = (D.patients || []).filter(p => !q || [p.PatientName, p.BedNumber, p.IpNo, p.PatientCode].join(' ').toLowerCase().includes(q));
        const links = Object.fromEntries((D.links || []).map(l => [l.id, l.url]));
        const all = D.patients || [], now = new Date();
        const sum = f => all.reduce((a, p) => a + (Number(f(p)) || 0), 0);
        $('nsKpi').innerHTML = `<div><small>Patients</small><b>${all.length}</b></div>
            <div><small>NEWS2 medium / high</small><b class="${all.some(p => p.News2Risk === 'HIGH' || p.News2Risk === 'MEDIUM') ? 'text-danger' : ''}">${all.filter(p => p.News2Risk === 'HIGH' || p.News2Risk === 'MEDIUM').length}</b></div>
            <div><small>Vitals due</small><b>${all.filter(p => new Date(p.VitalsDueAt) < now).length}</b></div>
            <div><small>Doses overdue · due in 2 h</small><b><span class="${sum(p => p.Overdue) ? 'text-danger' : ''}">${sum(p => p.Overdue)}</span> · ${sum(p => p.DueNext)}</b></div>
            <div><small>New orders · to countersign</small><b>${sum(p => p.NewOrders)} · ${sum(p => p.ToCountersign)}</b></div>
            <div><small>Samples pending</small><b>${sum(p => p.PendingSamples)}</b></div>`;
        if (!ps.length) { $('nsBody').innerHTML = '<div class="col-12"><div class="ipd-soon py-4"><div class="small">No admitted patients here.</div></div></div>'; return; }
        $('nsBody').innerHTML = ps.map(p => {
            const tags = [];
            if (p.Overdue) tags.push(`<span class="bad">${p.Overdue} dose(s) overdue</span>`);
            if (p.DueNext) tags.push(`<span class="warn">${p.DueNext} dose(s) due</span>`);
            if (new Date(p.VitalsDueAt) < now) tags.push(`<span class="${p.News2Risk === 'HIGH' || p.News2Risk === 'MEDIUM' ? 'bad' : 'warn'}">vitals ${U.dueText(p.VitalsDueAt)}</span>`);
            if (p.NewOrders) tags.push(`<span class="warn">${p.NewOrders} new order(s)</span>`);
            if (p.CountersignOverdue) tags.push(`<span class="bad">${p.CountersignOverdue} countersign overdue</span>`);
            else if (p.ToCountersign) tags.push(`<span>${p.ToCountersign} to countersign</span>`);
            if (p.PendingSamples) tags.push(`<span class="warn">${p.PendingSamples} sample(s) to collect</span>`);
            if (p.NursingAssessOverdue) tags.push('<span class="bad">nursing assessment overdue</span>');
            if (p.DoctorAssessOverdue) tags.push('<span class="bad">doctor assessment overdue</span>');
            if (p.FallRisk === 'HIGH') tags.push('<span class="bad">high fall risk</span>');
            if (p.PressureRisk === 'HIGH' || p.PressureRisk === 'VERY_HIGH') tags.push('<span class="bad">pressure-ulcer risk</span>');
            if (p.ConsultsWaiting) tags.push(`<span>${p.ConsultsWaiting} consult(s) waiting</span>`);
            if (p.OpenIncidents) tags.push(`<span class="warn">${p.OpenIncidents} open incident(s)</span>`);
            if (p.Status === 'DISCHARGE_ADVISED' || p.Status === 'BILL_FINAL') tags.push(`<span>${p.Status === 'BILL_FINAL' ? 'bill final' : 'discharge advised'}</span>`);
            const url = C.canPatient ? links[p.AdmissionId] : null;
            return `<div class="col-12 col-md-6 col-xl-4"><div class="ns-card risk-${E(p.News2Risk || '')}" ${url ? `data-url="${E(url)}" role="link" tabindex="0"` : ''}>
                <div class="d-flex justify-content-between gap-2"><div><b>${E(p.BedNumber)}</b> · ${E(p.PatientName)}<div class="small text-muted">${E(p.IpNo)} · ${E(p.WardName || '')} · ${E(p.ConsultantName || '')}</div></div>
                <div class="text-end">${U.news2Badge(p.News2, p.News2Risk)}<div class="small text-muted">${p.LastVitalsAt ? U.ago(p.LastVitalsAt) : 'no vitals'}</div></div></div>
                ${p.KnownAllergies ? `<div class="small text-danger mt-1"><i class="bi bi-exclamation-triangle me-1"></i>${E(p.KnownAllergies)}</div>` : ''}
                ${p.Diet ? `<div class="small text-muted">${E(p.Diet)}</div>` : ''}
                <div class="ns-tags">${tags.join('') || '<span>nothing due</span>'}</div></div></div>`;
        }).join('');
    }

    $('nsStation').addEventListener('change', () => { localStorage.setItem(KEY, $('nsStation').value); load(); });
    $('nsSearch').addEventListener('input', () => D && render());
    $('nsRefresh').addEventListener('click', load);
    $('nsBody').addEventListener('click', e => { const c = e.target.closest('[data-url]'); if (c) location.href = c.dataset.url; });
    $('nsBody').addEventListener('keydown', e => { const c = e.target.closest('[data-url]'); if (c && e.key === 'Enter') location.href = c.dataset.url; });
    load();
    setInterval(() => { if (!document.hidden) load(); }, 60000);
})();
