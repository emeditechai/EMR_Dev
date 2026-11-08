/* IPD Patient workspace, Phase 5 (SQLScripts/2434): Procedures, Other Charges, Doctor Visits, Package and Billing tabs. */
(function () {
    'use strict';
    const B = window.IpdBill; if (!B) return;
    const $ = id => document.getElementById(id);
    const can = B.can, url = B.base;
    let lk = null, preview = null;
    const chargeable = () => B.open && (B.status === 'ADMITTED' || B.status === 'DISCHARGE_ADVISED') && !(preview && preview.totals && preview.totals[0] && preview.totals[0].BillId);
    const heads = { PROCEDURE: ['PROCEDURE'], SERVICE: ['SERVICE', 'CONSUMABLE', 'OT', 'RADIOLOGY'], DOCTOR: ['DOCTOR'] };

    async function lookups() {
        if (!lk) lk = await Ipd.get(url + 'ChargeLookups?id=' + B.id);
        return lk;
    }
    const opt = (v, t, extra = '') => `<option value="${Ipd.esc(v)}" ${extra}>${Ipd.esc(t)}</option>`;
    const rateTxt = r => r == null ? 'no rate' : Ipd.money(r);

    // ── charge forms ────────────────────────────────────────────────────────────────────────────────────────
    function formHtml(kind) {
        const pick = kind === 'PROCEDURE' ? 'Procedure' : kind === 'DOCTOR' ? 'Doctor' : 'Service';
        const manual = kind === 'SERVICE' && can.rate;
        return `<div class="row g-2 align-items-end">
            ${manual ? `<div class="col-12"><div class="btn-group btn-group-sm" role="group">
                <input type="radio" class="btn-check" name="cm-${kind}" id="cmM-${kind}" value="master" checked><label class="btn btn-outline-secondary" for="cmM-${kind}">From master</label>
                <input type="radio" class="btn-check" name="cm-${kind}" id="cmX-${kind}" value="manual"><label class="btn btn-outline-secondary" for="cmX-${kind}">Other charge (enter rate)</label></div></div>` : ''}
            <div class="col-12 col-lg-4 c-master"><label class="form-label small fw-semibold">${pick}</label><select class="form-select c-item"><option value="">Loading…</option></select></div>
            ${manual ? `<div class="col-6 col-lg-2 c-manual d-none"><label class="form-label small fw-semibold">Head</label><select class="form-select c-head">
                ${opt('SERVICE', 'Other services')}${opt('CONSUMABLE', 'Consumables')}${opt('OT', 'Operation theatre')}${opt('RADIOLOGY', 'Radiology')}</select></div>
                <div class="col-6 col-lg-2 c-manual d-none"><label class="form-label small fw-semibold">Name</label><input class="form-control c-name" maxlength="250" /></div>` : ''}
            ${kind === 'PROCEDURE' ? `<div class="col-6 col-lg-2"><label class="form-label small fw-semibold">Performed by</label><select class="form-select c-doc"><option value="">—</option></select></div>` : ''}
            ${kind === 'DOCTOR' ? `<div class="col-6 col-lg-2"><label class="form-label small fw-semibold">Visit</label><select class="form-select c-visit">${opt('ROUTINE', 'Routine round')}${opt('EMERGENCY', 'Emergency visit')}${opt('CROSS', 'Cross consultation')}${opt('NIGHT', 'Night visit')}</select></div>` : ''}
            <div class="col-6 col-lg-2"><label class="form-label small fw-semibold">Date &amp; time</label><input type="datetime-local" class="form-control c-at" /></div>
            <div class="col-3 col-lg-1"><label class="form-label small fw-semibold">Qty</label><input type="number" class="form-control c-qty" min="0.001" step="any" value="1" /></div>
            <div class="col-4 col-lg-1"><label class="form-label small fw-semibold">Rate</label><input type="number" class="form-control c-rate" min="0" step="0.01" ${can.rate && kind !== 'DOCTOR' ? '' : 'readonly tabindex="-1"'} ${kind === 'DOCTOR' ? 'title="From Master › IPD Master › IPD Doctor Visit Charges"' : ''} /></div>
            ${manual ? `<div class="col-3 col-lg-1 c-manual d-none"><label class="form-label small fw-semibold">GST %</label><input type="number" class="form-control c-gst" min="0" max="28" value="0" /></div>` : ''}
            ${can.discount ? `<div class="col-4 col-lg-1"><label class="form-label small fw-semibold">Discount</label><input type="number" class="form-control c-disc" min="0" step="0.01" value="0" /></div>` : ''}
            <div class="col-12 col-lg"><button type="button" class="btn btn-primary w-100 c-add"><i class="bi bi-plus-lg me-1"></i>Add</button></div>
            <div class="col-12 small text-muted c-hint"></div>
        </div>`;
    }

    async function initForm(box) {
        const kind = box.dataset.kind;
        if (!can.charge) { box.innerHTML = '<div class="small text-muted">You can see the charges; adding them needs the IPD Patient › Add charges permission.</div>'; return; }
        if (!chargeable()) { box.innerHTML = '<div class="small text-muted"><i class="bi bi-lock me-1"></i>The final bill is made (or the stay is closed): cancel the bill to add charges.</div>'; return; }
        box.innerHTML = formHtml(kind);
        const q = s => box.querySelector(s);
        q('.c-at').value = Ipd.local();
        let data;
        try { data = await lookups(); } catch (e) { q('.c-hint').textContent = e.message; return; }
        const list = kind === 'PROCEDURE' ? data.procedures : kind === 'DOCTOR' ? data.doctors : data.services;
        const docs = (data.doctors || []).slice().sort((a, b) => (b.IsIpd - a.IsIpd) || a.Name.localeCompare(b.Name));
        // doctor visits: the rate is the IPD visit charge of the chosen visit type (IPD > Doctor Visit Charges)
        const vKey = { ROUTINE: 'RoutineRate', EMERGENCY: 'EmergencyRate', CROSS: 'CrossRate', NIGHT: 'NightRate' };
        let items = [];
        const rated = x => x.Rate != null && Number(x.Rate) > 0;
        const fillItems = () => {
            const keep = q('.c-item').value;
            items = kind === 'DOCTOR' ? docs.map(d => Object.assign({}, d, { Rate: d[vKey[q('.c-visit').value]] })) : (list || []);
            const sorted = items.filter(rated).concat(items.filter(x => !rated(x)));
            q('.c-item').innerHTML = '<option value="">Choose…</option>' + sorted.map(x => opt(x.Id, `${x.Name}${x.Code ? ' · ' + x.Code : ''} — ${rated(x) ? Ipd.money(x.Rate) : 'no rate (cannot be charged)'}`, rated(x) ? '' : 'disabled')).join('');
            const k = items.find(x => String(x.Id) === keep);
            q('.c-item').value = k && rated(k) ? keep : '';
            q('.c-rate').value = k && rated(k) ? k.Rate : '';
            q('.c-hint').innerHTML = items.some(rated) ? '' : kind === 'DOCTOR'
                ? '<span class="text-danger">No doctor has an IPD visit charge: add it in Master › IPD Master › IPD Doctor Visit Charges.</span>'
                : '<span class="text-danger">No item here has a rate for this patient’s tariff category: add the rates in the master tariff.</span>';
        };
        fillItems();
        if (q('.c-visit')) q('.c-visit').addEventListener('change', fillItems);
        if (q('.c-doc')) q('.c-doc').innerHTML = '<option value="">—</option>' + docs.map(d => opt(d.Id, d.Name)).join('');
        const find = () => items.find(x => String(x.Id) === q('.c-item').value);
        q('.c-item').addEventListener('change', () => {
            const x = find(); if (x && !rated(x)) { q('.c-item').value = ''; return Ipd.error(kind === 'DOCTOR' ? 'This doctor has no IPD visit charge (Master › IPD Master › IPD Doctor Visit Charges).' : 'This item has no rate for the patient’s tariff category and cannot be charged.'); }
            q('.c-rate').value = x && x.Rate != null ? x.Rate : '';
            q('.c-hint').innerHTML = !x ? '' : x.Rate == null ? '<span class="text-danger">No tariff rate for this patient’s tariff category' + (can.rate ? ': enter the rate.' : ' (Master tariff, or a user with the rate-edit right).') + '</span>'
                : (x.UsedFallback ? '<span class="text-warning">Rate of the default tariff category (no rate for the patient’s category).</span>' : '')
                + (kind === 'PROCEDURE' && x.SurgeonFee != null ? ` Surgeon ${Ipd.money(x.SurgeonFee)} · OT ${Ipd.money(x.OtCharges)} · anaesthetist ${Ipd.money(x.AnaesthetistFee)} · consumables ${Ipd.money(x.ConsumableCharges)}` : '')
                + (x.GstPercent ? ` GST ${x.GstPercent}%` : '');
        });
        box.querySelectorAll(`input[name="cm-${kind}"]`).forEach(r => r.addEventListener('change', () => {
            const man = box.querySelector(`input[name="cm-${kind}"]:checked`).value === 'manual';
            box.querySelectorAll('.c-manual').forEach(e => e.classList.toggle('d-none', !man));
            box.querySelectorAll('.c-master').forEach(e => e.classList.toggle('d-none', man));
            q('.c-rate').value = ''; q('.c-hint').textContent = '';
        }));
        q('.c-add').addEventListener('click', async () => {
            const man = !!box.querySelector(`input[name="cm-${kind}"]:checked`) && box.querySelector(`input[name="cm-${kind}"]:checked`).value === 'manual';
            const line = {
                kind: man ? 'MANUAL' : kind, qty: Number(q('.c-qty').value) || 0, chargeAt: q('.c-at').value || null,
                rate: q('.c-rate').value === '' ? null : Number(q('.c-rate').value), discount: q('.c-disc') ? Number(q('.c-disc').value) || 0 : 0
            };
            if (man) {
                line.head = q('.c-head').value; line.itemName = q('.c-name').value.trim(); line.gstPercent = Number(q('.c-gst').value) || 0;
                if (!line.itemName) return Ipd.error('Enter the name of the charge.');
                if (line.rate == null) return Ipd.error('Enter the rate.');
            } else {
                line.refId = Number(q('.c-item').value) || null;
                const sel = find(); if (sel && !rated(sel)) return Ipd.error('This item has no rate and cannot be charged.');
                if (!line.refId) return Ipd.error('Choose the ' + (kind === 'DOCTOR' ? 'doctor' : kind === 'PROCEDURE' ? 'procedure' : 'service') + '.');
            }
            if (q('.c-doc') && q('.c-doc').value) line.doctorId = Number(q('.c-doc').value);
            if (q('.c-visit')) line.visitType = q('.c-visit').value;
            if (line.qty <= 0) return Ipd.error('The quantity must be more than zero.');
            const btn = q('.c-add'); btn.disabled = true;
            try {
                const r = await Ipd.post(url + 'AddCharges?id=' + B.id, [line]);
                if (!r.success) return Ipd.error(r.error);
                Ipd.toast('Charge added'); q('.c-item').value = ''; q('.c-rate').value = ''; q('.c-qty').value = 1; if (q('.c-disc')) q('.c-disc').value = 0; if (q('.c-name')) q('.c-name').value = '';
                q('.c-hint').textContent = '';
                loadRows(); loadBill();
            } finally { btn.disabled = false; }
        });
    }

    async function loadRows() {
        const tbodies = document.querySelectorAll('.ipd-charge-rows');
        let rows;
        const showCancelled = [...document.querySelectorAll('.ipd-show-cancelled')].some(c => c.checked);
        try { rows = await Ipd.get(url + 'Charges?id=' + B.id + '&includeCancelled=' + showCancelled) || []; }
        catch (e) { tbodies.forEach(t => t.innerHTML = `<tr><td colspan="9" class="text-danger small">${Ipd.esc(e.message)}</td></tr>`); return; }
        tbodies.forEach(t => {
            const own = heads[t.dataset.kind] || [];
            const mine = rows.filter(r => own.includes(r.Head));
            const total = mine.filter(r => r.Status === 'POSTED').reduce((s, r) => s + (Number(r.Net) || 0), 0);
            t.innerHTML = mine.length ? mine.map(r => {
                const x = r.Status !== 'POSTED';
                return `<tr class="${x ? 'text-decoration-line-through text-muted' : ''}">
                <td><div class="fw-semibold">${Ipd.date(r.ChargeAt)}</div><div class="small text-muted">${new Date(r.ChargeAt).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })}</div></td>
                <td><div class="fw-semibold">${Ipd.esc(r.ItemName)}</div><div class="small text-muted">${Ipd.esc(r.HeadName || r.Head)}${r.DoctorName && r.Head !== 'DOCTOR' ? ' · Dr ' + Ipd.esc(r.DoctorName) : ''}${r.Remarks ? ' · ' + Ipd.esc(r.Remarks) : ''}
                    ${r.IsPackageItem ? ' <span class="ipd-pill muted">in package</span>' : ''}${r.MasterRate != null && Number(r.MasterRate) !== Number(r.Rate) ? ` <span class="ipd-pill muted" title="Master rate ${Ipd.money(r.MasterRate)}">rate changed</span>` : ''}
                    ${x ? `<div class="text-danger" style="text-decoration:none">Cancelled: ${Ipd.esc(r.CancelReason || '')} (${Ipd.esc(r.CancelledByName || '')})</div>` : ''}</div></td>
                <td class="text-end">${Number(r.Qty)}</td><td class="text-end">${Ipd.num(r.Rate)}</td><td class="text-end">${Ipd.num(r.Discount)}</td><td class="text-end">${Ipd.num(r.GstAmount)}</td>
                <td class="text-end fw-semibold">${Ipd.num(r.Net)}</td><td class="small">${Ipd.esc(r.CreatedByName || '')}</td>
                <td>${!x && can.cancel && chargeable() && (r.SourceModule || 'IPD') === 'IPD' ? `<button type="button" class="btn btn-sm btn-light border text-danger c-cancel" data-id="${r.ChargeId}" title="Cancel charge"><i class="bi bi-x-lg"></i></button>` : ''}</td></tr>`;
            }).join('') + `<tr><td colspan="6" class="text-end fw-semibold">Total</td><td class="text-end fw-bold">${Ipd.num(total)}</td><td colspan="2"></td></tr>`
                : '<tr><td colspan="9" class="text-muted small">No charges yet.</td></tr>';
        });
    }
    document.addEventListener('click', async e => {
        const b = e.target.closest('.c-cancel'); if (!b) return;
        const reason = await Ipd.reason('Cancel this charge?', 'Reason'); if (!reason) return;
        const r = await Ipd.post(url + 'CancelCharge?chargeId=' + b.dataset.id, { reason });
        if (!r.success) return Ipd.error(r.error);
        Ipd.toast('Charge cancelled'); loadRows(); loadBill();
    });
    document.querySelectorAll('.ipd-show-cancelled').forEach(c => c.addEventListener('change', () => { document.querySelectorAll('.ipd-show-cancelled').forEach(o => o.checked = c.checked); loadRows(); }));

    // ── package ─────────────────────────────────────────────────────────────────────────────────────────────
    const headName = { BED: 'Bed days', DOCTOR: 'Doctor visits', PROCEDURE: 'Procedures', OT: 'OT', CONSUMABLE: 'Consumables', SERVICE: 'Services' };
    async function initPackage() {
        const sel = $('pkgSel'); if (!sel) return;
        let data; try { data = await lookups(); } catch (e) { $('pkgInfo').textContent = e.message; return; }
        sel.innerHTML = '<option value="">No package</option>' + (data.packages || []).map(p => opt(p.Id, `${p.Name} — ${Ipd.money(p.Amount)}`, String(p.Id) === String(B.packageId) ? 'selected' : '')).join('');
        const info = () => {
            const p = (data.packages || []).find(x => String(x.Id) === sel.value);
            $('pkgInfo').innerHTML = p ? `Includes: ${(p.Heads || '').split(',').filter(Boolean).map(h => headName[h] || h).join(', ') || '—'}${p.BedDays ? ` · <b>${p.BedDays}</b> bed day(s)` : ''}` : 'No package: everything is billed at the tariff.';
        };
        sel.addEventListener('change', info); info();
        const items = data.packageItems || [];
        $('pkgRows').innerHTML = items.length ? items.map(r => `<tr><td>${Ipd.esc(r.DetailHeadType)}</td><td>${Ipd.esc(r.ItemName || '')}</td><td class="text-end">${Number(r.Quantity || 0)}</td><td>${Ipd.esc(r.BillingFrequency || '')}</td><td class="text-end">${Ipd.num(r.Amount)}</td><td class="small text-muted">${Ipd.esc(r.Remarks || '')}</td></tr>`).join('')
            : '<tr><td colspan="6" class="text-muted small">No package on this admission.</td></tr>';
        const btn = $('pkgSave');
        if (!can.package || !chargeable()) { btn.disabled = true; sel.disabled = true; $('pkgReason').disabled = true; if (!can.package) $('pkgInfo').innerHTML += '<div>Changing the package needs the IPD Patient › Package permission.</div>'; return; }
        btn.addEventListener('click', async () => {
            const packageId = sel.value ? Number(sel.value) : null;
            if (!await Ipd.confirm(packageId ? 'Apply this package?' : 'Remove the package?', 'Charges of the included heads are re-priced.', 'Apply')) return;
            btn.disabled = true;
            try {
                const r = await Ipd.post(url + 'SetPackage?id=' + B.id, { packageId, reason: $('pkgReason').value.trim() || null });
                if (!r.success) return Ipd.error(r.error);
                Ipd.toast('Package updated'); setTimeout(() => location.reload(), 600);
            } finally { btn.disabled = false; }
        });
    }

    // ── billing ─────────────────────────────────────────────────────────────────────────────────────────────
    const kpi = (l, v, sub, cls) => `<div class="ipdx-kpi ${cls || ''}"><small>${l}</small><b class="num">${v}</b><span>${sub || ''}</span></div>`;
    function renderBill() {
        const t = (preview.totals || [])[0] || {}, hs = preview.heads || [];
        const billed = !!t.BillId;
        // banner money strip follows every charge added / cancelled
        const due = (Number(t.Net) || 0) - (Number(t.AdvanceHeld) || 0);
        if ($('bmBill')) $('bmBill').textContent = Ipd.money(t.Net);
        if ($('kBill')) $('kBill').textContent = Ipd.money(t.Net);
        if ($('bmDue')) {
            $('bmDue').textContent = Ipd.money(Math.abs(due));
            $('bmDueLbl').textContent = due > 0 ? 'Balance due' : due < 0 ? 'Refundable' : 'Balance';
            $('bmDueSub').textContent = due > 0 ? 'to collect' : due < 0 ? 'advance exceeds bill' : 'settled to date';
            $('bmDueBox').classList.toggle('due', due > 0); $('bmDueBox').classList.toggle('ok', due <= 0);
        }
        $('billKpis').innerHTML = kpi(billed ? 'Bill amount' : 'Bill if billed now', Ipd.money(t.Net), billed ? 'final' : `${t.Lines || 0} line(s), live`, 'accent')
            + kpi('Advance held', Ipd.money(t.AdvanceHeld), billed ? `adjusted ${Ipd.money(t.AdvanceAdjusted)}` : '', 'good')
            + kpi('Balance due', Ipd.money(t.BalanceDue), '', t.BalanceDue > 0 ? 'bad' : 'good')
            + kpi('Refundable', Ipd.money(t.RefundDue), '', '');
        $('billHeads').innerHTML = hs.filter(h => h.Lines > 0).map(h => `<tr><td>${Ipd.esc(h.HeadName)}</td><td class="text-end">${h.Lines}</td><td class="text-end">${Ipd.num(h.Gross)}</td><td class="text-end">${Ipd.num(h.Discount)}</td><td class="text-end">${Ipd.num(h.Gst)}</td><td class="text-end fw-semibold">${Ipd.num(h.Net)}</td></tr>`).join('')
            || '<tr><td colspan="6" class="text-muted small">Nothing billed yet.</td></tr>';
        $('billFoot').innerHTML = `<tr><td colspan="5" class="text-end">Gross</td><td class="text-end">${Ipd.num(t.Gross)}</td></tr>
            ${(t.ItemDiscount + t.BillDiscount) > 0 ? `<tr><td colspan="5" class="text-end">Discount${t.BillDiscount > 0 ? ` (bill ${Ipd.money(t.BillDiscount)})` : ''}</td><td class="text-end">- ${Ipd.num(t.ItemDiscount + t.BillDiscount)}</td></tr>` : ''}
            ${t.Gst > 0 ? `<tr><td colspan="5" class="text-end">GST</td><td class="text-end">${Ipd.num(t.Gst)}</td></tr>` : ''}
            ${t.RoundOff ? `<tr><td colspan="5" class="text-end">Round off</td><td class="text-end">${Ipd.num(t.RoundOff)}</td></tr>` : ''}
            <tr><td colspan="5" class="text-end fw-bold">Bill amount</td><td class="text-end fw-bold">${Ipd.money(t.Net)}</td></tr>`;
        const prints = [];
        if (billed) prints.push(`<a class="btn btn-sm btn-light border" target="_blank" href="${url}PrintBill/${t.BillId}"><i class="bi bi-printer me-1"></i>Bill</a>`, `<a class="btn btn-sm btn-light border" target="_blank" href="${url}PrintBill/${t.BillId}?format=detail"><i class="bi bi-list-ul me-1"></i>Detailed</a>`);
        else if (can.estimate) prints.push(`<a class="btn btn-sm btn-light border" target="_blank" href="${B.estBase}Print/${B.id}?format=head"><i class="bi bi-printer me-1"></i>Interim bill</a>`);
        $('billPrints').innerHTML = prints.join('');
        $('finalBox').classList.toggle('d-none', billed);
        $('billedBox').classList.toggle('d-none', !billed);
        if (billed) {
            $('bbNo').textContent = t.BillNo || '';
            $('bbSub').textContent = `Made ${Ipd.dt(t.BillAt)} · billed up to ${Ipd.dt(t.UpTo)}`;
            $('bbBody').innerHTML = `<table class="table table-sm mb-0"><tbody>
                <tr><td>Bill amount</td><td class="text-end fw-semibold">${Ipd.money(t.Net)}</td></tr>
                <tr><td>Advance adjusted</td><td class="text-end">${Ipd.money(t.AdvanceAdjusted)}</td></tr>
                ${t.SettleTotal > 0 ? `<tr><td>Paid against the bill</td><td class="text-end">${Ipd.money(t.SettleTotal)}</td></tr>` : ''}
                <tr><td class="fw-bold">${t.RefundDue > 0 ? 'Refundable' : 'Balance due'}</td><td class="text-end fw-bold ${t.BalanceDue > 0 ? 'text-danger' : 'text-success'}">${Ipd.money(t.RefundDue > 0 ? t.RefundDue : t.BalanceDue)}</td></tr></tbody></table>`;
            $('bbCollect').classList.toggle('d-none', !(t.BalanceDue > 0 && can.advance && B.open));
            $('bbRefund').classList.toggle('d-none', !(t.RefundDue > 0 && can.refund));
            $('bbCancel').classList.toggle('d-none', !can.billCancel || B.status === 'DISCHARGED');
        } else {
            const ok = can.finalBill && chargeable();
            ['fbUpTo', 'fbDiscType', 'fbDiscVal', 'fbDiscReason', 'fbRemarks', 'fbSave'].forEach(i => $(i).disabled = !ok);
            if (!can.discount) { $('fbDiscType').disabled = $('fbDiscVal').disabled = $('fbDiscReason').disabled = true; }
            if (!can.backdate) $('fbUpTo').readOnly = true;
            $('fbMsg').innerHTML = t.Error ? `<span class="text-danger">${Ipd.esc(t.Error)}</span>`
                : t.NoTariff ? '<span class="text-danger">A bed day has no tariff: add the rate (Master › IPD › Bed / Room Tariff) before the final bill.</span>'
                : !can.finalBill ? '<span class="text-muted">Making the final bill needs the IPD Patient › Final bill permission.</span>'
                : !chargeable() ? '<span class="text-muted">The stay is closed.</span>' : '';
        }
    }
    function billQuery() {
        const q = new URLSearchParams({ id: B.id });
        if ($('fbUpTo').value) q.set('upTo', $('fbUpTo').value);
        if ($('fbDiscType').value && Number($('fbDiscVal').value) > 0) { q.set('discountType', $('fbDiscType').value); q.set('discountValue', $('fbDiscVal').value); }
        return q;
    }
    async function loadBill() {
        if (!$('billKpis')) return;
        try { preview = await Ipd.get(url + 'Preview?' + billQuery()); renderBill(); }
        catch (e) { $('billHeads').innerHTML = `<tr><td colspan="6" class="text-danger small">${Ipd.esc(e.message)}</td></tr>`; }
    }
    function initBilling() {
        if (!$('fbUpTo')) return;
        $('fbUpTo').value = Ipd.local();
        $('fbPreview').addEventListener('click', loadBill);
        $('fbSave').addEventListener('click', async () => {
            await loadBill();
            const t = (preview.totals || [])[0] || {};
            if (t.Error) return Ipd.error(t.Error);
            const html = `Bill amount <b>${Ipd.money(t.Net)}</b>${t.BillDiscount > 0 ? ` after a discount of ${Ipd.money(t.BillDiscount)}` : ''}.<br>Advance adjusted ${Ipd.money(t.AdvanceAdjusted)}; ${t.RefundDue > 0 ? 'refundable ' + Ipd.money(t.RefundDue) : 'balance due ' + Ipd.money(t.BalanceDue)}.<br><small class="text-muted">No charges can be added after this (cancel the bill to reopen).</small>`;
            if (!await Ipd.confirm('Make the final bill?', html, 'Make final bill')) return;
            const b = $('fbSave'); b.disabled = true;
            try {
                const disc = $('fbDiscType').value && Number($('fbDiscVal').value) > 0;
                const r = await Ipd.post(url + 'Finalise?id=' + B.id, {
                    upTo: $('fbUpTo').value || null, discountType: disc ? $('fbDiscType').value : null, discountValue: disc ? Number($('fbDiscVal').value) : 0,
                    discountReason: $('fbDiscReason').value.trim() || null, remarks: $('fbRemarks').value.trim() || null
                });
                if (!r.success) return Ipd.error(r.error);
                Ipd.toast('Final bill ' + r.data.BillNo + ' made');
                window.open(url + 'PrintBill/' + r.data.BillId, '_blank');
                setTimeout(() => location.reload(), 800);
            } finally { b.disabled = false; }
        });
        $('bbCollect').addEventListener('click', e => { e.preventDefault(); const m = $('advanceModal'); if (m) bootstrap.Modal.getOrCreateInstance(m).show(); });
        $('bbRefund').addEventListener('click', e => { e.preventDefault(); const m = $('refundModal'); if (m) bootstrap.Modal.getOrCreateInstance(m).show(); });
        $('bbCancel').addEventListener('click', async () => {
            const t = (preview.totals || [])[0] || {};
            const reason = await Ipd.reason('Cancel bill ' + (t.BillNo || '') + '?', 'Reason (the accounts are reversed; money paid on it stays as advance)'); if (!reason) return;
            const r = await Ipd.post(url + 'CancelBill?billId=' + t.BillId, { reason });
            if (!r.success) return Ipd.error(r.error);
            Ipd.toast('Bill cancelled'); setTimeout(() => location.reload(), 600);
        });
    }

    (async function start() {
        initBilling();
        await loadBill();
        document.querySelectorAll('.ipd-charge-form').forEach(initForm);
        loadRows();
        initPackage();
    })();
})();
