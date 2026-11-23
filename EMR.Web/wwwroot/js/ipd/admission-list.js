/* IPD > Admission List (SQLScripts/2478): summary tiles, status pills, more filters with chips, sortable columns,
   row flags and actions, page size / numbers, Excel export. Filters are remembered for the session. */
(function () {
    'use strict';
    const base = (window.IpdPage || {}).base, E = Ipd.esc, $ = id => document.getElementById(id);
    const KEY = 'ipd.admList.v2';
    const S = Object.assign({ status: 'OPEN', search: '', payer: '', ward: '', doctor: '', dept: '', from: '', to: '', flag: '', sort: 'ADMITTED_DESC', page: 1, size: 25 },
        (() => { try { return JSON.parse(sessionStorage.getItem(KEY) || '{}'); } catch { return {}; } })());
    let lookups = false, timer, busy = false;
    const save = () => { try { sessionStorage.setItem(KEY, JSON.stringify(S)); } catch { } };

    const FLAGS = { ICU: 'In ICU', MLC: 'Medico-legal', LOW_DEPOSIT: 'Deposit alert', DUE: 'Balance due', DISCHARGE_DUE: 'Discharge due', PACKAGE: 'On package', INDENT: 'Open medicine indent' };
    const STATUS = { OPEN: 'In hospital', ADMITTED: 'Admitted', DISCHARGE_ADVISED: 'Discharge advised', DISCHARGED: 'Discharged', CANCELLED: 'Cancelled', '': 'All' };

    function params(page, size) {
        return new URLSearchParams({ status: S.status, search: S.search, payerType: S.payer, wardId: S.ward, consultantId: S.doctor, departmentId: S.dept,
            fromDate: S.from, toDate: S.to, flag: S.flag, sort: S.sort, page: page ?? S.page, pageSize: size ?? S.size });
    }

    // ── controls from the state ──
    function syncControls() {
        $('fSearch').value = S.search; $('fSearchClear').classList.toggle('d-none', !S.search);
        document.querySelectorAll('#fStatusPills button').forEach(b => b.classList.toggle('active', b.dataset.v === S.status));
        $('fPayer').value = S.payer; $('fWard').value = S.ward; $('fDoctor').value = S.doctor; $('fDept').value = S.dept; $('fFrom').value = S.from; $('fTo').value = S.to;
        $('fSize').value = String(S.size);
        const more = [S.payer, S.ward, S.doctor, S.dept, S.from || S.to].filter(Boolean).length;
        $('alMoreCount').textContent = more; $('alMoreCount').classList.toggle('d-none', !more);
        const key = S.sort.replace('_DESC', '').replace('_ASC', '');
        document.querySelectorAll('.al-sort').forEach(th => {
            const k = th.dataset.s.replace('_DESC', '');
            th.classList.toggle('on', k === key || (k === 'ADMITTED' && S.sort.startsWith('ADMITTED')));
            th.classList.toggle('asc', S.sort === 'ADMITTED_ASC' && k === 'ADMITTED' || ['NAME', 'BED'].includes(S.sort) && k === S.sort);
        });
        chips();
    }
    function chips() {
        const sel = id => { const el = $(id); return el.value ? el.options[el.selectedIndex].text : ''; };
        const list = [];
        if (S.flag) list.push(['flag', FLAGS[S.flag] || S.flag]);
        if (S.search) list.push(['search', '“' + S.search + '”']);
        if (S.payer) list.push(['payer', sel('fPayer')]);
        if (S.ward) list.push(['ward', sel('fWard')]);
        if (S.doctor) list.push(['doctor', 'Dr ' + sel('fDoctor')]);
        if (S.dept) list.push(['dept', sel('fDept')]);
        if (S.from || S.to) list.push(['dates', `Admitted ${S.from ? Ipd.date(S.from) : '…'} – ${S.to ? Ipd.date(S.to) : '…'}`]);
        $('alChips').innerHTML = list.length ? list.map(([k, t]) => `<span class="al-chip">${E(t)}<button type="button" data-k="${k}" title="Remove">&times;</button></span>`).join('')
            + '<button type="button" class="btn btn-link btn-sm p-0 ms-1" id="alClearAll">Clear all</button>' : '';
    }

    // ── tiles ──
    function tiles(t) {
        t = t || {};
        const tile = (flag, status, label, icon, color, val, sub) => `<button type="button" class="al-tile ${(S.flag === flag && (flag || S.status === status)) ? 'sel' : ''}" style="--al-c:${color}"
            data-flag="${flag}" data-status="${status}"><div class="lbl"><i class="bi ${icon}"></i>${label}</div><div class="val">${val ?? 0}</div><div class="sub">${sub}</div></button>`;
        $('alTiles').innerHTML =
            tile('', 'OPEN', 'In hospital', 'bi-hospital', '#2563eb', t.InHospital, `${t.AdmittedToday ?? 0} admitted today`)
            + tile('', 'DISCHARGE_ADVISED', 'Discharge advised', 'bi-box-arrow-right', '#7c3aed', t.DischargeAdvised, 'awaiting bill / discharge')
            + tile('DISCHARGE_DUE', 'OPEN', 'Discharge due', 'bi-calendar-event', '#d97706', t.DischargeDue, 'expected today or earlier')
            + tile('LOW_DEPOSIT', 'OPEN', 'Deposit alerts', 'bi-exclamation-triangle', '#dc2626', t.DepositAlerts, 'cash, advance running out')
            + tile('DUE', 'OPEN', 'Balance due', 'bi-currency-rupee', '#b91c1c', Ipd.money(t.TotalDue).replace('.00', ''), 'total of in-hospital')
            + tile('ICU', 'OPEN', 'In ICU', 'bi-heart-pulse', '#ea580c', t.InIcu, 'ICU beds now')
            + tile('MLC', 'OPEN', 'Medico-legal', 'bi-shield-exclamation', '#991b1b', t.Mlc, 'MLC cases in hospital')
            + tile('', 'DISCHARGED', 'Discharged today', 'bi-door-open', '#16a34a', t.DischargedToday, 'left the hospital today');
    }

    // ── rows ──
    const initials = n => String(n || '').replace(/^(Mr|Mrs|Ms|Miss|Master|Baby|Dr)\.?\s+/i, '').split(/\s+/).filter(Boolean).slice(0, 2).map(w => w[0]).join('').toUpperCase() || '?';
    function row(r) {
        const open = r.IsOpen, g = String(r.Gender || '').toLowerCase().startsWith('f') ? 'f' : (/^\d+\s*[MD]/.test(r.AgeText || '') || parseInt(r.AgeText) < 13 ? 'c' : '');
        const cover = r.AdvanceCoverPct, coverCls = cover == null ? '' : cover >= 100 ? '' : cover >= 50 ? 'warn' : 'bad';
        const flags = [
            r.IsMlc ? '<span class="al-flag mlc">MLC</span>' : '', r.IsIcu ? '<span class="al-flag icu">ICU</span>' : '',
            r.PackageName ? `<span class="al-flag pkg" title="${E(r.PackageName)}">PACKAGE</span>` : '', r.AdmittedToday ? '<span class="al-flag new">NEW TODAY</span>' : '',
            r.DischargeOverdue ? `<span class="al-flag over" title="Expected ${E(Ipd.dt(r.ExpectedDischargeAt))}">DISCHARGE OVERDUE</span>` : '',
            r.DischargeToday ? '<span class="al-flag due">DISCHARGE TODAY</span>' : '',
            r.OpenIndents ? `<span class="al-flag ind">${r.OpenIndents} INDENT${r.OpenIndents > 1 ? 'S' : ''}</span>` : '',
            r.DepositAlert ? '<span class="al-flag over">DEPOSIT ALERT</span>' : ''].join('');
        const p = base + 'Patient/' + r.AdmissionId;
        return `<tr data-id="${r.AdmissionId}">
            <td class="font-monospace fw-semibold text-nowrap">${E(r.IpNo)}</td>
            <td class="text-nowrap small">${E(Ipd.date(r.AdmissionAt))}<div class="text-muted">${E(new Date(r.AdmissionAt).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' }))}</div></td>
            <td><div class="d-flex gap-2 align-items-center"><span class="al-av ${g}">${E(initials(r.PatientName))}</span><div>
                <div class="fw-semibold">${E(r.PatientName)}</div>
                <div class="small text-muted">${E(r.PatientCode)} · ${E(r.AgeText || '')}${r.Gender ? ' / ' + E(r.Gender) : ''}${r.PhoneNumber ? ` · <a href="tel:${E(r.PhoneNumber)}" class="text-muted text-decoration-none al-stop">${E(r.PhoneNumber)}</a>` : ''}</div>
                ${flags ? `<div class="al-flags">${flags}</div>` : ''}</div></div></td>
            <td>${E(r.WardName || '—')}<div class="small fw-semibold">${E(r.BedNumber || '')}</div></td>
            <td>${E(r.ConsultantDoctorName || '')}<div class="small text-muted">${E(r.DepartmentName || '')}</div></td>
            <td>${E(Ipd.payer(r.PayerType))}<div class="small text-muted">${E(r.TariffCategoryName || '')}</div></td>
            <td class="text-end">${r.DayCount}</td>
            <td class="text-end num">${r.BillNow == null ? '—' : Ipd.money(r.BillNow)}</td>
            <td class="text-end num">${Ipd.money(r.NetAdvance)}${open && cover != null ? `<div class="al-cover ${coverCls}" title="Advance covers ${cover}% of the bill"><span style="width:${Math.min(100, cover)}%"></span></div>` : ''}</td>
            <td class="text-end num al-bal ${r.Status === 'CANCELLED' ? '' : r.BalanceDue > 0 ? 'due' : 'ok'}">${r.Status === 'CANCELLED' ? '' : Ipd.money(r.BalanceDue)}</td>
            <td>${Ipd.status(r.Status)}</td>
            <td class="text-end al-act al-stop"><div class="dropdown">
                <button type="button" class="btn btn-sm btn-light border" data-bs-toggle="dropdown" aria-expanded="false" title="Actions"><i class="bi bi-three-dots-vertical"></i></button>
                <ul class="dropdown-menu dropdown-menu-end shadow-sm">
                    <li><a class="dropdown-item" href="${p}"><i class="bi bi-folder2-open me-2"></i>Open patient</a></li>
                    <li><a class="dropdown-item" href="${p}?tab=billing"><i class="bi bi-receipt me-2"></i>Current bill</a></li>
                    ${open ? `<li><a class="dropdown-item" href="${p}?tab=advance"><i class="bi bi-cash-coin me-2"></i>Collect advance</a></li>
                    <li><a class="dropdown-item" href="${p}?tab=indent"><i class="bi bi-capsule me-2"></i>Medicine indent</a></li>
                    <li><a class="dropdown-item" href="${p}?tab=bed"><i class="bi bi-arrow-left-right me-2"></i>Transfer bed</a></li>` : ''}
                    <li><hr class="dropdown-divider" /></li>
                    <li><a class="dropdown-item" href="${base}PrintFaceSheet/${r.AdmissionId}" target="_blank"><i class="bi bi-printer me-2"></i>Face sheet</a></li>
                    <li><a class="dropdown-item" href="${base}PrintWristband/${r.AdmissionId}" target="_blank"><i class="bi bi-upc me-2"></i>Wristband</a></li>
                </ul></div></td></tr>`;
    }
    const skeleton = () => Array.from({ length: 6 }, () => `<tr class="al-skel">${'<td><span></span></td>'.repeat(12)}</tr>`).join('');

    function pager(total) {
        const pages = Math.max(1, Math.ceil(total / S.size)), cur = Math.min(S.page, pages);
        const item = (p, label, dis, act) => `<li class="page-item ${dis ? 'disabled' : ''} ${act ? 'active' : ''}"><button type="button" class="page-link" data-p="${p}">${label}</button></li>`;
        let out = item(cur - 1, '&lsaquo;', cur <= 1), last = 0;
        for (let p = 1; p <= pages; p++) {
            if (p === 1 || p === pages || Math.abs(p - cur) <= 1) { if (p - last > 1) out += '<li class="page-item disabled"><span class="page-link">…</span></li>'; out += item(p, p, false, p === cur); last = p; }
        }
        $('pager').innerHTML = out + item(cur + 1, '&rsaquo;', cur >= pages);
        $('count').textContent = total ? `${(cur - 1) * S.size + 1}–${Math.min(cur * S.size, total)} of ${total}` : 'No admissions';
    }

    async function load() {
        save(); syncControls();
        if (busy) return; busy = true;
        $('rows').innerHTML = skeleton();
        try {
            const d = await Ipd.get(base + 'ListData?' + params());
            const total = (d.total && d.total[0] && d.total[0].Total) || 0;
            if (!lookups) {
                const fill = (id, rows) => { const el = $(id), keep = el.value; el.insertAdjacentHTML('beforeend', (rows || []).map(x => `<option value="${x.Id}">${E(x.Name)}</option>`).join('')); el.value = keep; };
                fill('fWard', d.wards); fill('fDoctor', d.consultants); fill('fDept', d.departments); lookups = true; syncControls();
            }
            tiles((d.summary || [])[0]);
            $('alTotal').textContent = total;
            const rows = d.rows || [];
            $('rows').innerHTML = rows.map(row).join('') || `<tr><td colspan="12"><div class="al-empty"><i class="bi bi-inbox"></i>No admission matches these filters.
                ${$('alChips').innerHTML || S.status !== 'OPEN' ? '<div><button type="button" class="btn btn-sm btn-outline-secondary mt-2" id="alReset">Reset filters</button></div>' : ''}</div></td></tr>`;
            pager(total);
        } catch (e) { $('rows').innerHTML = `<tr><td colspan="12" class="text-danger text-center py-4">${E(e.message)}</td></tr>`; }
        finally { busy = false; }
    }
    const reload = () => { S.page = 1; load(); };
    const reset = () => { Object.assign(S, { status: 'OPEN', search: '', payer: '', ward: '', doctor: '', dept: '', from: '', to: '', flag: '', sort: 'ADMITTED_DESC', page: 1 }); load(); };

    // ── events ──
    $('fSearch').addEventListener('input', e => { S.search = e.target.value.trim(); $('fSearchClear').classList.toggle('d-none', !S.search); clearTimeout(timer); timer = setTimeout(reload, 300); });
    $('fSearch').addEventListener('keydown', e => { if (e.key === 'Escape') { e.target.value = ''; S.search = ''; reload(); } if (e.key === 'Enter') { const f = document.querySelector('#rows tr[data-id]'); if (f && document.querySelectorAll('#rows tr[data-id]').length === 1) location.href = base + 'Patient/' + f.dataset.id; } });
    $('fSearchClear').addEventListener('click', () => { S.search = ''; reload(); $('fSearch').focus(); });
    $('fStatusPills').addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; S.status = b.dataset.v; S.flag = ''; reload(); });
    [['fPayer', 'payer'], ['fWard', 'ward'], ['fDoctor', 'doctor'], ['fDept', 'dept'], ['fFrom', 'from'], ['fTo', 'to']].forEach(([id, k]) => $(id).addEventListener('change', e => { S[k] = e.target.value; reload(); }));
    document.querySelectorAll('.al-range').forEach(b => b.addEventListener('click', () => {
        const t = new Date(), iso = d => d.toISOString().substring(0, 10), r = b.dataset.r;
        const loc = d => { const x = new Date(d); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return iso(x); };
        if (r === 'today') { S.from = S.to = loc(t); } else if (r === '7') { const f = new Date(t); f.setDate(f.getDate() - 6); S.from = loc(f); S.to = loc(t); }
        else if (r === 'month') { S.from = loc(new Date(t.getFullYear(), t.getMonth(), 1)); S.to = loc(t); } else { S.from = S.to = ''; }
        if (r && S.status === 'OPEN') S.status = '';   // admissions of a period: discharged ones too
        reload();
    }));
    $('fSize').addEventListener('change', e => { S.size = Number(e.target.value) || 25; reload(); });
    $('pager').addEventListener('click', e => { const b = e.target.closest('[data-p]'); if (!b || b.parentElement.classList.contains('disabled')) return; S.page = Number(b.dataset.p); load(); window.scrollTo({ top: 0, behavior: 'smooth' }); });
    document.querySelector('.al-table thead').addEventListener('click', e => {
        const th = e.target.closest('.al-sort'); if (!th) return;
        const s = th.dataset.s;
        S.sort = s === 'ADMITTED' ? (S.sort === 'ADMITTED_DESC' ? 'ADMITTED_ASC' : 'ADMITTED_DESC') : (S.sort === s ? 'ADMITTED_DESC' : s);
        reload();
    });
    $('alTiles').addEventListener('click', e => { const t = e.target.closest('.al-tile'); if (!t) return;
        const same = S.flag === t.dataset.flag && S.status === t.dataset.status;
        S.flag = same && t.dataset.flag ? '' : t.dataset.flag; S.status = t.dataset.status; reload(); });
    document.addEventListener('click', e => {
        const c = e.target.closest('.al-chip button');
        if (c) { const k = c.dataset.k; if (k === 'dates') { S.from = S.to = ''; } else S[k] = ''; reload(); return; }
        if (e.target.closest('#alClearAll') || e.target.closest('#alReset')) { reset(); return; }
    });
    $('rows').addEventListener('click', e => {
        if (e.target.closest('.al-stop, a, button')) return;
        const tr = e.target.closest('tr[data-id]'); if (!tr) return;
        const url = base + 'Patient/' + tr.dataset.id;
        if (e.ctrlKey || e.metaKey) window.open(url, '_blank'); else location.href = url;
    });
    $('alRefresh').addEventListener('click', load);
    $('alExport').addEventListener('click', () => { const q = params(1, 2000); q.delete('page'); q.delete('pageSize'); window.location.href = base + 'ListExport?' + q; });
    document.addEventListener('keydown', e => { if (e.key === '/' && !/input|select|textarea/i.test(document.activeElement.tagName)) { e.preventDefault(); $('fSearch').focus(); } });
    setInterval(() => { if (!document.hidden && !document.querySelector('.al-act .dropdown-menu.show')) load(); }, 120000);

    if (S.payer || S.ward || S.doctor || S.dept || S.from || S.to) new bootstrap.Collapse($('alMore'), { toggle: true });
    load();
})();
