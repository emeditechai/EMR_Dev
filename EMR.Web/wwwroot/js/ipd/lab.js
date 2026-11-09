/* IPD Patient workspace > LAB and Radiology tabs (Phase 4, SQLScripts/2436): order at IPD rates, follow sample / report, cancel. */
(function () {
    'use strict';
    const P = window.IpdLab; if (!P) return;
    const E = Ipd.esc;
    const cart = { LAB: [], RAD: [] }, items = {};
    let doctors = null;

    const statusPill = s => ({
        ORDERED: '<span class="ipd-pill warn">Ordered</span>', COLLECTED: '<span class="ipd-pill info">Sample collected</span>',
        RECOLLECT: '<span class="ipd-pill alert">Re-collect / rejected</span>', IN_PROCESS: '<span class="ipd-pill info">Result entry</span>',
        VALIDATED: '<span class="ipd-pill info">Validated</span>', REPORTED: '<span class="ipd-pill st-ADMITTED">Reported</span>', CANCELLED: '<span class="ipd-pill st-CANCELLED">Cancelled</span>'
    }[s] || E(s));

    async function loadDoctors() {
        if (doctors) return doctors;
        try { const d = await Ipd.get(window.IpdBill.base + 'ChargeLookups?id=' + P.id); doctors = d.doctors || []; } catch { doctors = []; }
        return doctors;
    }

    async function initForm(box) {
        const kind = box.dataset.kind;
        if (!P.can.order) { box.innerHTML = '<div class="small text-muted">You can see the orders; ordering needs the IPD Patient › Order LAB tests permission.</div>'; return; }
        if (!P.open) { box.innerHTML = '<div class="small text-muted"><i class="bi bi-lock me-1"></i>The patient is not admitted (or the final bill is made): tests cannot be ordered.</div>'; return; }
        let data;
        try { data = await Ipd.get(P.base + 'LabItems?id=' + P.id + '&kind=' + kind); } catch (e) { box.innerHTML = `<div class="text-danger small">${E(e.message)}</div>`; return; }
        if (!(data.hasRateList && data.hasRateList[0] && data.hasRateList[0].HasRateList)) {
            box.innerHTML = '<div class="alert alert-warning py-2 small mb-0"><i class="bi bi-exclamation-triangle me-1"></i>This branch has no IPD LAB Rate List in force today: add it in Master › IPD Master › IPD LAB Rate List.</div>'; return;
        }
        items[kind] = data.items || [];
        const docs = await loadDoctors();
        box.innerHTML = `<div class="row g-2 align-items-end">
            <div class="col-12 col-lg-6 position-relative"><label class="form-label small fw-semibold">Find a test / profile / package</label>
                <input class="form-control l-find" placeholder="${items[kind].length} item(s) on the IPD rate list · type code or name" autocomplete="off" />
                <div class="sug-list list-group l-sug"></div></div>
            <div class="col-6 col-lg-3"><label class="form-label small fw-semibold">Ordering doctor</label>
                <select class="form-select l-doc"><option value="">—</option>${docs.map(d => `<option value="${d.Id}" ${d.Id === P.consultant ? 'selected' : ''}>${E(d.Name)}</option>`).join('')}</select></div>
            <div class="col-6 col-lg-3"><label class="form-label small fw-semibold">Clinical note</label><input class="form-control l-rem" maxlength="300" placeholder="e.g. fever since 3 days" /></div>
            <div class="col-12"><div class="l-cart"></div></div>
        </div>`;
        const q = s => box.querySelector(s);
        const sug = q('.l-sug'), find = q('.l-find');
        let hits = [], idx = 0;
        const renderSug = () => {
            sug.innerHTML = hits.map((x, i) => `<button type="button" class="list-group-item list-group-item-action sug py-2 px-3 ${i === idx ? 'active' : ''}" data-i="${i}">
                <span class="badge text-bg-light border me-1">${E(x.ItemType)}</span><b>${E(x.Name)}</b> <span class="text-muted small">${E(x.Code || '')}${x.DepartmentName ? ' · ' + E(x.DepartmentName) : ''}</span>
                <span class="float-end fw-semibold">${Ipd.money(x.Rate)}</span></button>`).join('');
            sug.style.display = hits.length ? 'block' : 'none';
        };
        const add = x => {
            if (!x) return;
            if (cart[kind].some(c => c.ItemType === x.ItemType && c.ItemId === x.ItemId)) { Ipd.toast('Already in the list', 'info'); return; }
            cart[kind].push({ ItemType: x.ItemType, ItemId: x.ItemId, Name: x.Name, Code: x.Code, Rate: Number(x.Rate), IsUrgent: false });
            find.value = ''; hits = []; renderSug(); renderCart();
        };
        find.addEventListener('input', () => {
            const v = find.value.trim().toLowerCase();
            hits = v.length < 1 ? [] : items[kind].filter(x => (x.Name || '').toLowerCase().includes(v) || (x.Code || '').toLowerCase().includes(v)).slice(0, 25);
            idx = 0; renderSug();
        });
        find.addEventListener('keydown', e => {
            if (sug.style.display !== 'block') return;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); idx = (idx + (e.key === 'ArrowDown' ? 1 : -1) + hits.length) % hits.length; renderSug(); }
            else if (e.key === 'Enter') { e.preventDefault(); add(hits[idx]); }
            else if (e.key === 'Escape') sug.style.display = 'none';
        });
        sug.addEventListener('mousedown', e => e.preventDefault());
        sug.addEventListener('click', e => { const b = e.target.closest('[data-i]'); if (b) add(hits[Number(b.dataset.i)]); });
        document.addEventListener('click', e => { if (!sug.contains(e.target) && e.target !== find) sug.style.display = 'none'; });

        function renderCart() {
            const c = cart[kind], total = c.reduce((s, x) => s + x.Rate, 0);
            q('.l-cart').innerHTML = !c.length ? '<div class="small text-muted">Add tests above; they are ordered together as one LAB bill.</div>' : `
                <table class="table table-sm align-middle mb-2"><thead><tr><th>Item</th><th class="text-end">IPD rate</th><th class="text-center">Urgent</th><th></th></tr></thead><tbody>
                ${c.map((x, i) => `<tr><td><span class="badge text-bg-light border me-1">${E(x.ItemType)}</span>${E(x.Name)} <span class="text-muted small">${E(x.Code || '')}</span></td>
                    <td class="text-end">${Ipd.money(x.Rate)}</td>
                    <td class="text-center"><input type="checkbox" class="form-check-input l-urg" data-i="${i}" ${x.IsUrgent ? 'checked' : ''}></td>
                    <td class="text-end"><button type="button" class="btn btn-sm btn-light border text-danger l-del" data-i="${i}"><i class="bi bi-x-lg"></i></button></td></tr>`).join('')}
                </tbody><tfoot><tr><td class="fw-bold">${c.length} item(s)</td><td class="text-end fw-bold">${Ipd.money(total)}</td><td colspan="2"></td></tr></tfoot></table>
                <div class="d-flex gap-2 justify-content-end"><button type="button" class="btn btn-light border l-clear">Clear</button>
                <button type="button" class="btn btn-primary l-save"><i class="bi bi-send me-1"></i>Order ${c.length} item(s) · ${Ipd.money(total)}</button></div>`;
        }
        q('.l-cart').addEventListener('change', e => { const u = e.target.closest('.l-urg'); if (u) cart[kind][Number(u.dataset.i)].IsUrgent = u.checked; });
        q('.l-cart').addEventListener('click', async e => {
            if (e.target.closest('.l-del')) { cart[kind].splice(Number(e.target.closest('.l-del').dataset.i), 1); renderCart(); return; }
            if (e.target.closest('.l-clear')) { cart[kind] = []; renderCart(); return; }
            const b = e.target.closest('.l-save'); if (!b) return;
            const c = cart[kind];
            if (!await Ipd.confirm('Order these tests?', `${c.length} item(s), ${Ipd.money(c.reduce((s, x) => s + x.Rate, 0))}, charged to the IP bill.`, 'Order')) return;
            b.disabled = true;
            try {
                const r = await Ipd.post(P.base + 'Order?id=' + P.id, { items: c.map(x => ({ itemType: x.ItemType, itemId: x.ItemId, isUrgent: x.IsUrgent })), doctorId: Number(q('.l-doc').value) || null, remarks: q('.l-rem').value.trim() || null });
                if (!r.success) { Ipd.error(r.error); return; }
                Ipd.toast(`Ordered: LAB bill ${r.data.BillNo}${r.data.TokenNo ? ', token ' + r.data.TokenNo : ''}`);
                cart[kind] = []; q('.l-rem').value = ''; renderCart(); loadRows();
                if (window.IpdBillRefresh) window.IpdBillRefresh();
            } finally { b.disabled = false; }
        });
        renderCart();
    }

    async function loadRows() {
        const inc = [...document.querySelectorAll('.ipd-lab-cancelled')].some(c => c.checked);
        for (const tb of document.querySelectorAll('.ipd-lab-rows')) {
            const kind = tb.dataset.kind;
            let rows;
            try { rows = await Ipd.get(P.base + 'LabOrders?id=' + P.id + '&kind=' + kind + '&includeCancelled=' + inc) || []; }
            catch (e) { tb.innerHTML = `<tr><td colspan="7" class="text-danger small">${E(e.message)}</td></tr>`; continue; }
            tb.innerHTML = rows.length ? rows.map(r => `<tr class="${r.IsActive ? '' : 'text-muted'}">
                <td><div class="fw-semibold">${Ipd.date(r.OrderDate)}</div><div class="small text-muted">${new Date(r.OrderDate).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })}</div></td>
                <td><div class="fw-semibold">${E(r.ItemName)}${r.IsUrgent ? ' <span class="ipd-pill alert">Urgent</span>' : ''}</div>
                    <div class="small text-muted">${E(r.ItemType)} · ${E(r.ItemCode || '')}${r.DepartmentName ? ' · ' + E(r.DepartmentName) : ''}${r.IpdRemarks ? ' · ' + E(r.IpdRemarks) : ''}</div>
                    ${!r.IsActive && r.CancelReason ? `<div class="small text-danger">Cancelled: ${E(r.CancelReason)}</div>` : ''}</td>
                <td><span class="font-monospace small">${E(r.BillNo)}</span><div class="small text-muted">${E(r.TokenNo || '')}${r.BarcodeNo ? ' · ' + E(r.BarcodeNo) : ''}</div></td>
                <td class="small">${E(r.OrderedByDoctor || '—')}<div class="text-muted">${E(r.OrderedByUser || '')}</div></td>
                <td class="text-end fw-semibold">${Ipd.money(r.Price)}</td>
                <td>${statusPill(r.ItemStatus)}${r.Samples ? `<div class="small text-muted">${r.Collected || 0}/${r.Samples} sample(s)</div>` : ''}</td>
                <td class="text-nowrap text-end">${r.ItemStatus === 'REPORTED' || r.ItemStatus === 'VALIDATED' ? `<a class="btn btn-sm btn-light border" target="_blank" href="${P.report}?labOrderId=${r.LabOrderId}" title="Report"><i class="bi bi-file-earmark-medical"></i></a>` : ''}
                    ${r.CanCancel && P.can.cancel ? `<button type="button" class="btn btn-sm btn-light border text-danger l-cancel" data-id="${r.LabOrderItemId}" title="Cancel test"><i class="bi bi-x-lg"></i></button>` : ''}</td></tr>`).join('')
                : '<tr><td colspan="7" class="text-muted small">No tests ordered yet.</td></tr>';
        }
    }
    document.addEventListener('click', async e => {
        const b = e.target.closest('.l-cancel'); if (!b) return;
        const reason = await Ipd.reason('Cancel this test?', 'Reason (only a test whose sample is not collected can be cancelled)'); if (!reason) return;
        const r = await Ipd.post(P.base + 'CancelItem?itemId=' + b.dataset.id, { reason });
        if (!r.success) return Ipd.error(r.error);
        Ipd.toast('Test cancelled: removed from the IP bill'); loadRows();
        if (window.IpdBillRefresh) window.IpdBillRefresh();
    });
    document.querySelectorAll('.ipd-lab-cancelled').forEach(c => c.addEventListener('change', () => { document.querySelectorAll('.ipd-lab-cancelled').forEach(o => o.checked = c.checked); loadRows(); }));

    document.querySelectorAll('.ipd-lab-form').forEach(initForm);
    loadRows();
})();
