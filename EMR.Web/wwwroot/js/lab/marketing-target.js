/* LAB > Marketing Executive Sales Target (SQLScripts/2447). Per branch + financial year; buckets by frequency. The same
   rules are checked again in usp_Api_MktTarget_Save (every bucket, 0 or more, whole visits, at least one target). */
(function () {
    'use strict';
    const P = window.MtPage, $ = id => document.getElementById(id), E = Ipd.esc;
    const FREQ = { MONTHLY: 'Monthly', QUARTERLY: 'Quarterly', HALFYEARLY: 'Half-yearly', YEARLY: 'Yearly' };
    const modal = () => bootstrap.Modal.getOrCreateInstance($('mtModal'));
    let list = [], cur = null, fy = '';

    function bar(pct) {
        if (pct == null) return '<span class="text-muted small">—</span>';
        const c = pct >= 100 ? '#16a34a' : pct >= 60 ? '#d97706' : '#dc2626';
        return `<div class="d-flex align-items-center gap-2"><div class="mt-bar flex-fill"><i style="width:${Math.min(100, pct)}%;background:${c}"></i></div><b style="color:${c}" class="small">${pct.toFixed(1)}%</b></div>`;
    }

    async function load(fyStart) {
        try {
            const d = await Ipd.get(P.base + 'ListData' + (fyStart ? '?fyStart=' + fyStart : ''));
            fy = d.fyStart; list = d.rows || []; window.__mtAll = list.length;
            $('mtFy').innerHTML = (d.years || []).map(y => `<option value="${String(y.FyStart).slice(0, 10)}"${String(y.FyStart).slice(0, 10) === fy ? ' selected' : ''}>FY ${E(y.FyLabel)}${y.IsCurrent ? ' (current)' : ''}</option>`).join('');
            const sel = $('mtfExec'), keep = sel.value;
            sel.length = 1; list.forEach(x => sel.add(new Option(`${x.ExecutiveName} (${x.ExecutiveCode})`, x.ExecutiveId)));
            sel.value = list.some(x => String(x.ExecutiveId) === keep) ? keep : '';
            render();
        } catch (e) { $('mtRows').innerHTML = `<tr><td colspan="6" class="text-center text-danger py-4">${E(e.message)}</td></tr>`; }
    }

    // filters (executive, frequency, status) apply to the cards and the table
    function shown() {
        const ex = $('mtfExec').value, fq = $('mtfFreq').value, st = $('mtfStatus').value;
        return list.filter(r => (!ex || String(r.ExecutiveId) === ex)
            && (!fq || (fq === 'NONE' ? !r.TargetId : r.Frequency === fq))
            && (st === '' || (r.IsActive ? '1' : '0') === st));
    }

    function render() {
        const list = shown(), filtered = list.length !== window.__mtAll;
        const set = list.filter(r => r.TargetId), s = set.reduce((a, r) => a + Number(r.SalesTarget || 0), 0), v = set.reduce((a, r) => a + Number(r.VisitTarget || 0), 0);
        const k = (c, l, val, sub) => `<div class="col-6 col-lg-3"><div class="mt-kpi" style="--c:${c}"><small>${l}</small><b>${val}</b><span class="small text-muted">${sub}</span></div></div>`;
        $('mtKpis').innerHTML = k('#2563eb', 'LAB executives', list.length, 'active, or with a target') + k('#16a34a', 'Targets set', set.length, `${list.length - set.length} without a target`)
            + k('#c2410c', 'Sales target (year)', Ipd.money(s), 'all executives') + k('#7c3aed', 'Doctor visits (year)', v.toLocaleString('en-IN'), 'all executives');
        $('mtRows').innerHTML = list.length ? list.map(r => `<tr>
            <td><div class="fw-semibold">${E(r.ExecutiveName)}${r.IsActive ? '' : ' <span class="badge bg-secondary-subtle text-secondary">Inactive</span>'}</div><small class="text-muted">${E(r.ExecutiveCode)}</small></td>
            <td>${r.TargetId ? `<span class="badge text-bg-primary">${FREQ[r.Frequency] || E(r.Frequency)}</span> <small class="text-muted">${r.Buckets} period(s)</small>` : '<span class="badge bg-warning-subtle text-warning-emphasis border">Not set</span>'}</td>
            <td class="mt-num fw-semibold">${r.TargetId ? Ipd.money(r.SalesTarget) : '—'}</td><td class="mt-num">${r.TargetId ? Number(r.VisitTarget).toLocaleString('en-IN') : '—'}</td>
            <td class="small text-muted">${r.LastChanged ? Ipd.dt(r.LastChanged) + (r.ModifiedByName ? ' · ' + E(r.ModifiedByName) : '') : ''}</td>
            <td class="text-end"><button type="button" class="btn btn-sm ${P.canEdit ? 'btn-outline-primary' : 'btn-outline-secondary'}" data-id="${r.ExecutiveId}">
                <i class="bi ${P.canEdit ? 'bi-pencil' : 'bi-eye'} me-1"></i>${P.canEdit ? (r.TargetId ? 'Change' : 'Set target') : 'View'}</button></td></tr>`).join('')
            : filtered ? '<tr><td colspan="6" class="text-center text-muted py-4">No executive matches the filters.</td></tr>' : '<tr><td colspan="6" class="text-center text-muted py-4">No LAB marketing executives. Add them in Master &gt; Marketing Executive Master (type LAB).</td></tr>';
    }

    async function open(execId, freq) {
        try { cur = await Ipd.get(P.base + 'Get?' + new URLSearchParams({ executiveId: execId, fyStart: fy, frequency: freq || '' })); }
        catch (e) { return Ipd.error(e.message); }
        const h = cur.header, edit = P.canEdit && !h.IsOwnView;
        $('mtTitle').textContent = `${h.ExecutiveName} (${h.ExecutiveCode}) · FY ${h.FyLabel}`;
        $('mtSub').textContent = `${Ipd.date(h.FyStart)} – ${Ipd.date(h.FyEnd)}` + (h.SavedFrequency ? ` · saved as ${FREQ[h.SavedFrequency]}` : ' · no target saved yet');
        document.querySelector(`#mtFreq input[value="${h.Frequency}"]`).checked = true;
        document.querySelectorAll('#mtFreq input').forEach(i => i.disabled = !edit);
        document.querySelectorAll('.mt-edit').forEach(x => x.classList.toggle('d-none', !edit));
        if (!freq) $('mtRemarks').value = h.Remarks || '';
        $('mtRemarks').disabled = !edit;
        $('mtAudit').innerHTML = h.CreatedDate ? `Set ${Ipd.dt(h.CreatedDate)}${h.CreatedByName ? ' by ' + E(h.CreatedByName) : ''}${h.ModifiedDate ? ` · last changed ${Ipd.dt(h.ModifiedDate)}${h.ModifiedByName ? ' by ' + E(h.ModifiedByName) : ''}` : ''}` : '';
        if (h.SavedFrequency && h.Frequency !== h.SavedFrequency) $('mtAudit').innerHTML = `<span class="text-warning-emphasis"><i class="bi bi-exclamation-triangle me-1"></i>Saving replaces the saved ${FREQ[h.SavedFrequency]} targets with these ${FREQ[h.Frequency]} ones.</span>`;
        $('mtBuckets').tBodies[0].innerHTML = cur.buckets.map(b => {
            const pct = Number(b.SalesTarget) > 0 && (b.IsPast || b.IsCurrent) ? Number(b.SalesActual) * 100 / Number(b.SalesTarget) : null;
            return `<tr class="${b.IsCurrent ? 'cur' : b.IsPast ? 'past' : ''}" data-no="${b.BucketNo}">
            <td class="fw-semibold">${E(b.PeriodLabel)}${b.IsCurrent ? ' <span class="badge text-bg-info">Now</span>' : ''}</td><td class="small">${Ipd.date(b.FromDate)} – ${Ipd.date(b.ToDate)}</td>
            <td><input type="number" class="form-control form-control-sm b-s" min="0" step="any" value="${Number(b.SalesTarget)}" ${edit ? '' : 'disabled'} /><div class="invalid-feedback text-end">0 or more</div></td>
            <td><input type="number" class="form-control form-control-sm b-v" min="0" step="1" value="${b.VisitTarget}" style="max-width:100px" ${edit ? '' : 'disabled'} /><div class="invalid-feedback text-end">Whole number</div></td>
            <td class="mt-num">${b.IsPast || b.IsCurrent ? Ipd.money(b.SalesActual) : '—'}</td><td style="min-width:130px">${bar(pct)}</td>
            <td class="mt-num">${b.IsPast || b.IsCurrent ? b.VisitActual + (Number(b.VisitTarget) > 0 ? ` <small class="text-muted">/ ${b.VisitTarget}</small>` : '') : '—'}</td></tr>`;
        }).join('');
        totals();
        if (!$('mtModal').classList.contains('show')) modal().show();
    }

    function totals() {
        let s = 0, v = 0;
        $('mtBuckets').querySelectorAll('tbody tr').forEach(tr => { s += Number(tr.querySelector('.b-s').value) || 0; v += Number(tr.querySelector('.b-v').value) || 0; });
        $('mtBuckets').tFoot.innerHTML = `<tr><td colspan="2">Year total</td><td class="mt-num">${Ipd.money(s)}</td><td class="mt-num">${v.toLocaleString('en-IN')}</td><td colspan="3"></td></tr>`;
    }

    function valid() {
        let ok = true;
        $('mtBuckets').querySelectorAll('.b-s').forEach(i => { const bad = i.value === '' || isNaN(+i.value) || +i.value < 0; i.classList.toggle('is-invalid', bad); ok = ok && !bad; });
        $('mtBuckets').querySelectorAll('.b-v').forEach(i => { const bad = i.value === '' || !/^\d+$/.test(i.value); i.classList.toggle('is-invalid', bad); ok = ok && !bad; });
        return ok;
    }

    $('mtRows').addEventListener('click', e => { const b = e.target.closest('button[data-id]'); if (b) open(+b.dataset.id); });
    $('mtFy').addEventListener('change', e => load(e.target.value));
    ['mtfExec', 'mtfFreq', 'mtfStatus'].forEach(id => $(id).addEventListener('change', render));
    $('mtfReset').addEventListener('click', () => { ['mtfExec', 'mtfFreq', 'mtfStatus'].forEach(id => $(id).value = ''); render(); });
    $('mtFreq').addEventListener('change', e => open(cur.header.ExecutiveId, e.target.value));
    $('mtBuckets').addEventListener('input', e => { e.target.classList.remove('is-invalid'); totals(); });
    $('mtFill').addEventListener('click', () => {
        const s = $('mtFillS').value, v = $('mtFillV').value;
        if (s === '' && v === '') return Ipd.toast('Enter the sales or visit target to fill', 'info');
        $('mtBuckets').querySelectorAll('tbody tr').forEach(tr => { if (s !== '') tr.querySelector('.b-s').value = s; if (v !== '') tr.querySelector('.b-v').value = v; });
        totals();
    });
    $('mtSave').addEventListener('click', async () => {
        if (!valid()) { $('mtBuckets').querySelector('.is-invalid')?.focus(); return; }
        const buckets = [...$('mtBuckets').querySelectorAll('tbody tr')].map(tr => ({ bucketNo: +tr.dataset.no, salesTarget: +tr.querySelector('.b-s').value, visitTarget: +tr.querySelector('.b-v').value }));
        if (!buckets.some(b => b.salesTarget > 0 || b.visitTarget > 0)) return Ipd.error('Enter at least one sales or doctor-visit target.');
        const h = cur.header;
        if (h.SavedFrequency && h.SavedFrequency !== h.Frequency
            && !await Ipd.confirm('Change the frequency?', `The saved <b>${FREQ[h.SavedFrequency]}</b> targets of FY ${E(h.FyLabel)} are replaced by these <b>${FREQ[h.Frequency]}</b> ones.`, 'Replace')) return;
        const btn = $('mtSave'); btn.disabled = true;
        try {
            const r = await Ipd.post(P.base + 'Save', { executiveId: h.ExecutiveId, fyStart: String(h.FyStart).slice(0, 10), frequency: h.Frequency, buckets, remarks: $('mtRemarks').value.trim() || null });
            if (!r.success) return Ipd.error(r.error);
            modal().hide(); Ipd.toast('Target saved'); load(fy);
        } finally { btn.disabled = false; }
    });
    load();
})();
