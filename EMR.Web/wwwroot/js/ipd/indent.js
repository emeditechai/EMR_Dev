/* IPD Patient workspace > Medicines tab (SQLScripts/2475): the ward raises medicine indents (no stock, no bill),
   cancels what is still open and re-indents what the pharmacy could not issue / the ward did not receive. */
(function () {
    'use strict';
    const P = window.IpdPh; if (!P) return;
    const box = document.querySelector('.ipd-indent-form'), tb = document.querySelector('.ipd-indent-rows');
    if (!box || !tb) return;
    const E = Ipd.esc, cart = [];
    let stores = [], doctors = [];

    const statusPill = s => ({
        PENDING: '<span class="ipd-pill warn">Pending at pharmacy</span>', PARTIAL: '<span class="ipd-pill info">Part issued</span>', ISSUED: '<span class="ipd-pill ok">Issued</span>',
        NOT_ISSUED: '<span class="ipd-pill alert">Not issued</span>', SHORT_CLOSED: '<span class="ipd-pill warn">Part issued, rest not</span>', CANCELLED: '<span class="ipd-pill muted">Cancelled</span>'
    }[s] || E(s));
    // units as the POS: pack (STRIP) or sale unit (TAB); loose only when the item allows it; quantities are kept in sale units
    const conv = x => Number(x.ConversionQty) > 1 ? Number(x.ConversionQty) : 1;
    const q3 = v => Number(Number(v || 0).toFixed(3));
    const askedText = r => {
        const c = conv(r), su = E(r.SaleUom || 'unit');
        if (r.QtyMode === 'P' && c > 1) return `${q3(r.QtyIn)} ${E(r.PurchaseUom || 'pack')}<div class="small text-muted">${q3(r.ReqQty)} ${su}</div>`;
        return `${q3(r.ReqQty)} <span class="small text-muted">${su}</span>`;
    };
    window.IpdIndentUnits = { conv, q3 };
    const priPill = p => p === 'STAT' ? ' <span class="ipd-pill alert">STAT</span>' : p === 'URGENT' ? ' <span class="ipd-pill warn">Urgent</span>' : '';

    async function initForm() {
        if (!P.can.indent) { box.innerHTML = '<div class="small text-muted">You can see the indents; raising one needs the IPD Patient › Raise medicine indent permission.</div>'; return; }
        if (!P.open) { box.innerHTML = '<div class="small text-muted"><i class="bi bi-lock me-1"></i>The patient is not admitted (or the final bill is made): no indent can be raised.</div>'; return; }
        try { doctors = (await Ipd.get(window.IpdBill.base + 'ChargeLookups?id=' + P.id)).doctors || []; } catch { doctors = []; }
        try { stores = (await Ipd.get(P.base + 'IndentItems?id=' + P.id + '&q=')).stores || []; } catch { stores = []; }
        box.innerHTML = `<div class="row g-2 align-items-end">
            <div class="col-12 col-lg-4 position-relative"><label class="form-label small fw-semibold">Find a medicine (name, code or barcode)</label>
                <input class="form-control i-find" autocomplete="off" placeholder="Type at least 2 letters" /><div class="sug-list list-group i-sug"></div></div>
            <div class="col-6 col-lg-2"><label class="form-label small fw-semibold">Pharmacy store</label><select class="form-select i-store">${stores.map(s => `<option value="${s.StoreId}" ${s.IsDefault ? 'selected' : ''}>${E(s.StoreName)}</option>`).join('')}</select></div>
            <div class="col-6 col-lg-2"><label class="form-label small fw-semibold">Prescribed by</label><select class="form-select i-doc"><option value="">—</option>${doctors.map(d => `<option value="${d.Id}" ${d.Id === P.consultant ? 'selected' : ''}>${E(d.Name)}</option>`).join('')}</select></div>
            <div class="col-6 col-lg-1"><label class="form-label small fw-semibold">Priority</label><select class="form-select i-pri"><option value="ROUTINE">Routine</option><option value="URGENT">Urgent</option><option value="STAT">STAT</option></select></div>
            <div class="col-6 col-lg-3"><label class="form-label small fw-semibold">Remarks</label><input class="form-control i-rem" maxlength="300" placeholder="e.g. ward / nursing note" /></div>
            <div class="col-12"><div class="i-cart"></div></div></div>`;
        const q = s => box.querySelector(s), find = q('.i-find'), sug = q('.i-sug');
        let t, hits = [], idx = 0;
        const renderSug = () => {
            sug.innerHTML = hits.map((x, i) => `<button type="button" class="list-group-item list-group-item-action sug py-2 px-3 ${i === idx ? 'active' : ''}" data-i="${i}">
                <b>${E(x.ItemName)}</b> <span class="text-muted small">${E(x.ItemCode || '')} · ${E(x.PackSize || '')}${x.ScheduleCode ? ' · Sch ' + E(x.ScheduleCode) : ''}</span>
                ${x.IsHighAlert ? '<span class="ipd-pill alert ms-1">High alert</span>' : ''}${x.IsLasa ? '<span class="ipd-pill warn ms-1">LASA</span>' : ''}
                <span class="float-end small ${Number(x.Stock) > 0 ? '' : 'text-danger'}">${Number(x.Stock) > 0 ? 'stock ' + Number(x.Stock) : 'no stock'}</span></button>`).join('');
            sug.style.display = hits.length ? 'block' : 'none';
        };
        find.addEventListener('input', () => {
            clearTimeout(t); const v = find.value.trim();
            if (v.length < 2) { hits = []; renderSug(); return; }
            t = setTimeout(async () => { try { hits = (await Ipd.get(P.base + 'IndentItems?id=' + P.id + '&q=' + encodeURIComponent(v) + '&storeId=' + q('.i-store').value)).items || []; } catch { hits = []; } idx = 0; renderSug(); }, 250);
        });
        find.addEventListener('keydown', e => {
            if (sug.style.display !== 'block') return;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); idx = (idx + (e.key === 'ArrowDown' ? 1 : -1) + hits.length) % hits.length; renderSug(); }
            else if (e.key === 'Enter') { e.preventDefault(); pick(hits[idx]); }
            else if (e.key === 'Escape') sug.style.display = 'none';
        });
        sug.addEventListener('mousedown', e => e.preventDefault());
        sug.addEventListener('click', e => { const b = e.target.closest('[data-i]'); if (b) pick(hits[Number(b.dataset.i)]); });
        document.addEventListener('click', e => { if (!sug.contains(e.target) && e.target !== find) sug.style.display = 'none'; });

        function pick(x) {
            if (!x) return;
            find.value = ''; hits = []; renderSug();
            if (cart.some(c => c.ItemId === x.ItemId)) { Ipd.toast('Already in the list: change the quantity', 'info'); return; }
            const c = conv(x);
            cart.push({ ItemId: x.ItemId, Name: x.ItemName, Schedule: x.ScheduleCode, Stock: Number(x.Stock), Qty: 1, Remarks: '', Conv: c, Loose: !!x.AllowLooseSale,
                        SaleUom: x.SaleUom || 'unit', PackUom: x.PurchaseUom || 'pack', Mode: c > 1 ? 'P' : 'U' });
            renderCart();
        }
        function renderCart() {
            q('.i-cart').innerHTML = !cart.length ? '<div class="small text-muted">Pick medicines above. An indent is only a request: the stock and the IP bill change when the pharmacy issues it.</div>' : `
                <table class="table table-sm align-middle mb-2"><thead><tr><th>Medicine</th><th class="text-end">Stock now</th><th style="width:110px">Qty</th><th style="width:120px">Unit</th><th>Dose / instruction</th><th></th></tr></thead><tbody>
                ${cart.map((x, i) => `<tr><td>${E(x.Name)}${x.Schedule ? ` <span class="badge text-bg-light border">Sch ${E(x.Schedule)}</span>` : ''}</td>
                    <td class="text-end ${x.Stock > 0 ? '' : 'text-danger'}">${x.Stock > 0 ? q3(x.Stock) + ' ' + E(x.SaleUom) : 'none'}</td>
                    <td><input type="number" class="form-control form-control-sm text-end i-qty" data-i="${i}" min="1" step="${x.Mode === 'P' || !x.Loose ? 1 : 'any'}" value="${x.Qty}" />
                        ${x.Conv > 1 ? `<div class="small text-muted text-end i-units">${q3(x.Mode === 'P' ? x.Qty * x.Conv : x.Qty)} ${E(x.SaleUom)}</div>` : ''}</td>
                    <td>${x.Conv > 1 ? `<select class="form-select form-select-sm i-mode" data-i="${i}" ${x.Loose ? '' : 'disabled title="Not sold loose (Pharmacy Item Master)"'}>
                            <option value="P" ${x.Mode === 'P' ? 'selected' : ''}>${E(x.PackUom)}</option><option value="U" ${x.Mode === 'U' ? 'selected' : ''}>${E(x.SaleUom)}</option></select>`
                        : `<span class="small">${E(x.SaleUom)}</span>`}</td>
                    <td><input class="form-control form-control-sm i-lrem" data-i="${i}" maxlength="300" placeholder="e.g. 1-0-1 after food" value="${E(x.Remarks)}" /></td>
                    <td class="text-end"><button type="button" class="btn btn-sm btn-light border text-danger i-del" data-i="${i}"><i class="bi bi-x-lg"></i></button></td></tr>`).join('')}
                </tbody></table>
                <div class="d-flex justify-content-end gap-2"><button type="button" class="btn btn-light border i-clear">Clear</button>
                    <button type="button" class="btn btn-success i-save"><i class="bi bi-send me-1"></i>Send indent (${cart.length})</button></div>`;
        }
        q('.i-cart').addEventListener('input', e => {
            const qq = e.target.closest('.i-qty');
            if (qq) { const x = cart[Number(qq.dataset.i)]; x.Qty = Number(qq.value) || 0; const u = qq.parentElement.querySelector('.i-units'); if (u) u.textContent = q3(x.Mode === 'P' ? x.Qty * x.Conv : x.Qty) + ' ' + x.SaleUom; }
            const r = e.target.closest('.i-lrem'); if (r) cart[Number(r.dataset.i)].Remarks = r.value;
        });
        q('.i-cart').addEventListener('change', e => {
            const m = e.target.closest('.i-mode'); if (!m) return;
            const x = cart[Number(m.dataset.i)], units = x.Mode === 'P' ? x.Qty * x.Conv : x.Qty;   // keep the same quantity, shown in the new unit
            x.Mode = m.value; x.Qty = x.Mode === 'P' ? Math.max(1, Math.round(units / x.Conv)) : units; renderCart();
        });
        q('.i-cart').addEventListener('click', async e => {
            if (e.target.closest('.i-del')) { cart.splice(Number(e.target.closest('.i-del').dataset.i), 1); renderCart(); return; }
            if (e.target.closest('.i-clear')) { cart.length = 0; renderCart(); return; }
            const s = e.target.closest('.i-save'); if (!s) return;
            for (const x of cart) {
                if (!(x.Qty > 0)) return Ipd.error('Enter the quantity of ' + x.Name + '.');
                if (x.Mode === 'P' && x.Qty % 1 !== 0) return Ipd.error(`${x.Name}: enter whole ${x.PackUom}s, or choose ${x.SaleUom}.`);
            }
            const pri = q('.i-pri').value;
            if (!await Ipd.confirm('Send this indent to the pharmacy?', `${cart.length} medicine(s)${pri !== 'ROUTINE' ? ' · ' + pri : ''}`, 'Send')) return;
            s.disabled = true;
            try {
                const r = await Ipd.post(P.base + 'IndentSave?id=' + P.id, { lines: cart.map(x => ({ itemId: x.ItemId, qty: x.Qty, mode: x.Mode, remarks: x.Remarks.trim() || null })),
                    storeId: Number(q('.i-store').value) || null, doctorId: Number(q('.i-doc').value) || null, priority: pri, remarks: q('.i-rem').value.trim() || null });
                if (!r.success) { Ipd.error(r.error); return; }
                Ipd.toast('Indent ' + r.data.IndentNo + ' sent to the pharmacy');
                cart.length = 0; q('.i-rem').value = ''; q('.i-pri').value = 'ROUTINE'; renderCart(); loadIndents();
            } finally { s.disabled = false; }
        });
        renderCart();
    }

    async function loadIndents() {
        let rows;
        try { rows = await Ipd.get(P.base + 'Indents?id=' + P.id) || []; } catch (e) { tb.innerHTML = `<tr><td colspan="6" class="text-danger small">${E(e.message)}</td></tr>`; return; }
        if (!rows.length) { tb.innerHTML = '<tr><td colspan="6" class="text-muted small">No indent raised yet.</td></tr>'; return; }
        let last = null;
        tb.innerHTML = rows.map(r => {
            const first = r.IndentId !== last; last = r.IndentId;
            const canCancelAll = first && P.can.indent && rows.some(x => x.IndentId === r.IndentId && x.CanCancel);
            const why = r.Status === 'CANCELLED' ? `Cancelled: ${E(r.CancelReason || '')}`
                : r.NotIssueReason ? `${E(r.NotIssueReasonText || r.NotIssueReason)}${r.NotIssueRemarks ? ': ' + E(r.NotIssueRemarks) : ''}${r.NotIssuedBy ? ' · ' + E(r.NotIssuedBy) : ''}` : '';
            return `<tr class="${first ? 'border-top' : ''}">
                <td>${first ? `<div class="fw-semibold font-monospace small">${E(r.IndentNo)}${priPill(r.Priority)}</div><div class="small text-muted">${Ipd.dt(r.IndentAt)} · ${E(r.RaisedBy || '')}</div>
                    <div class="small text-muted">${E(r.StoreName || '')}${r.DoctorName ? ' · Dr ' + E(r.DoctorName) : ''}</div>${r.IndentRemarks ? `<div class="small">${E(r.IndentRemarks)}</div>` : ''}
                    ${canCancelAll ? `<button type="button" class="btn btn-link btn-sm text-danger p-0 i-cancel" data-indent="${r.IndentId}" data-no="${E(r.IndentNo)}">Cancel open lines</button>` : ''}` : ''}</td>
                <td><div class="fw-semibold">${E(r.ItemName)}${r.ScheduleCode ? ` <span class="badge text-bg-light border">Sch ${E(r.ScheduleCode)}</span>` : ''}</div>
                    <div class="small text-muted">${r.Remarks ? E(r.Remarks) : ''}${r.ReIndentOfNo ? (r.Remarks ? ' · ' : '') + 're-indent of ' + E(r.ReIndentOfNo) : ''}</div>${why ? `<div class="small text-danger">${why}</div>` : ''}</td>
                <td class="text-end">${askedText(r)}</td>
                <td class="text-end">${Number(r.IssuedQty) ? `${q3(r.IssuedQty)} <span class="small text-muted">${E(r.SaleUom || '')}</span>` : '—'}${Number(r.NotIssuedQty) ? `<div class="small text-danger">not ${q3(r.NotIssuedQty)}</div>` : ''}</td>
                <td>${statusPill(r.Status)}</td>
                <td class="text-end text-nowrap">${r.CanReIndent && P.can.indent ? `<button type="button" class="btn btn-sm btn-outline-primary i-reind" data-line="${r.LineId}" data-item="${r.ItemId}" data-name="${E(r.ItemName)}" data-qty="${Number(r.NotIssuedQty) || Number(r.ReqQty)}" data-uom="${E(r.SaleUom || '')}" title="Re-indent"><i class="bi bi-arrow-repeat me-1"></i>Re-indent</button>` : ''}
                    ${r.CanCancel && P.can.indent ? `<button type="button" class="btn btn-sm btn-light border text-danger i-cancel" data-indent="${r.IndentId}" data-line="${r.LineId}" data-no="${E(r.ItemName)}" title="Cancel this line"><i class="bi bi-x-lg"></i></button>` : ''}</td></tr>`;
        }).join('');
    }
    window.IpdIndentReload = loadIndents;

    // re-indent: a new indent of one line, linked to the line not issued / not received
    async function reIndent(o) {
        if (!window.Swal) return;
        const r = await Swal.fire({
            title: 'Re-indent ' + o.name, showCancelButton: true, confirmButtonText: 'Send re-indent',
            html: `<div class="text-start small mb-2">A new indent goes to the pharmacy for this medicine.</div>
                <div class="input-group mb-2"><input id="riq" type="number" class="form-control" min="0.001" step="any" value="${o.qty}" />${o.uom ? `<span class="input-group-text">${E(o.uom)}</span>` : ''}</div>
                <select id="rip" class="form-select mb-2"><option value="ROUTINE">Routine</option><option value="URGENT" selected>Urgent</option><option value="STAT">STAT</option></select>
                <input id="rir" class="form-control" maxlength="300" placeholder="Remarks (optional)" />`,
            preConfirm: () => { const qv = Number(document.getElementById('riq').value); if (!(qv > 0)) { Swal.showValidationMessage('Enter the quantity.'); return false; }
                return { qv, pv: document.getElementById('rip').value, rv: document.getElementById('rir').value.trim() }; }
        });
        if (!r.isConfirmed) return;
        const res = await Ipd.post(P.base + 'IndentSave?id=' + P.id, {
            lines: [{ itemId: o.itemId, qty: r.value.qv, mode: 'U', remarks: r.value.rv || null, reIndentOfLineId: o.lineId || null, reIndentOfIssueLineId: o.issueLineId || null }],
            storeId: Number(box.querySelector('.i-store')?.value) || null, doctorId: Number(box.querySelector('.i-doc')?.value) || P.consultant || null, priority: r.value.pv, remarks: 'Re-indent'
        });
        if (!res.success) return Ipd.error(res.error);
        Ipd.toast('Re-indent ' + res.data.IndentNo + ' sent'); loadIndents();
        if (window.IpdPhReload) window.IpdPhReload();
    }
    window.IpdReIndent = reIndent;

    tb.addEventListener('click', async e => {
        const ri = e.target.closest('.i-reind');
        if (ri) return reIndent({ itemId: Number(ri.dataset.item), name: ri.dataset.name, qty: Number(ri.dataset.qty), uom: ri.dataset.uom, lineId: Number(ri.dataset.line) });
        const c = e.target.closest('.i-cancel'); if (!c) return;
        const reason = await Ipd.reason(c.dataset.line ? `Cancel ${c.dataset.no}?` : `Cancel the open lines of ${c.dataset.no}?`, 'Reason (e.g. doctor stopped it, patient own stock)'); if (!reason) return;
        const r = await Ipd.post(P.base + 'IndentCancel?id=' + P.id, { indentId: Number(c.dataset.indent), lineId: c.dataset.line ? Number(c.dataset.line) : null, reason });
        if (!r.success) return Ipd.error(r.error);
        Ipd.toast('Cancelled'); loadIndents();
    });

    initForm();
    loadIndents();
})();
