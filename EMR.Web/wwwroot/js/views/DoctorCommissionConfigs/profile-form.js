// OPD > Doctor Commission Configuration (SQLScripts/2518): the share lines of a commission profile.
// Each line = what it applies to (Consultation, Service, ...), the services of a Service line (none = all services),
// calculation, basis and share. Sent to the server as JSON (LinesJson); the server validates the profile again.
(function () {
    const dataEl = document.getElementById('dcFormData'), body = document.getElementById('dcLines');
    const form = document.getElementById('commissionForm');
    if (!dataEl || !body || !form) return;
    const D = JSON.parse(dataEl.textContent || '{}');
    const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const opts = (list, sel) => list.map(v => `<option value="${esc(v)}"${v === sel ? ' selected' : ''}>${esc(v)}</option>`).join('');
    const pickers = new Map();   // row -> TomSelect of its services

    function rowHtml(l) {
        const svc = l.revenueType === 'Service';
        return `<td><select class="form-select form-select-sm dc-rev">${opts(D.revenueTypes || [], l.revenueType)}</select></td>
            <td class="dc-svc-cell">${svc ? `<select multiple class="dc-svc" placeholder="All services - or pick services">${(D.services || []).map(s =>
                `<option value="${esc(s.id)}"${(l.serviceIds || []).map(String).includes(String(s.id)) ? ' selected' : ''}>${esc(s.text)}</option>`).join('')}</select>`
                : '<span class="text-muted small">—</span>'}</td>
            <td><select class="form-select form-select-sm dc-calc">${opts(D.calcTypes || [], l.calculationType)}</select></td>
            <td><select class="form-select form-select-sm dc-basis">${opts(D.bases || [], l.commissionBasis || 'Net Collected')}</select></td>
            <td><div class="input-group input-group-sm"><input type="number" min="0" step="0.01" class="form-control text-end fw-bold text-success dc-share" value="${esc(l.doctorShare ?? '')}" />
                <span class="input-group-text dc-unit"></span></div></td>
            <td class="text-end"><button type="button" class="btn btn-sm btn-outline-danger dc-del" title="Remove this line"><i class="bi bi-x-lg"></i></button></td>`;
    }

    function refresh(tr) {
        const fixed = tr.querySelector('.dc-calc').value === 'Fixed Amount';
        tr.querySelector('.dc-unit').textContent = fixed ? '₹' : '%';
        tr.querySelector('.dc-basis').disabled = fixed;                       // a fixed amount needs no basis
        tr.classList.toggle('dc-is-service', tr.querySelector('.dc-rev').value === 'Service');
    }

    function mountPicker(tr) {
        const sel = tr.querySelector('.dc-svc');
        if (sel && window.TomSelect && !pickers.has(tr)) pickers.set(tr, new TomSelect(sel, {
            plugins: ['remove_button'], maxOptions: 500, hideSelected: true,
            // drawn on the page (not inside the table's scroll box, which would clip the list)
            dropdownParent: 'body'
        }));
    }

    function addRow(l) {
        const tr = document.createElement('tr');
        tr.dataset.id = l.commissionConfigId || '';
        tr.innerHTML = rowHtml(l);
        body.appendChild(tr);
        mountPicker(tr); refresh(tr); empty();
        return tr;
    }

    function readRow(tr) {
        const ts = pickers.get(tr);
        return {
            commissionConfigId: Number(tr.dataset.id) || null,
            revenueType: tr.querySelector('.dc-rev').value,
            calculationType: tr.querySelector('.dc-calc').value,
            commissionBasis: tr.querySelector('.dc-basis').value,
            doctorShare: Number(tr.querySelector('.dc-share').value) || 0,
            serviceIds: ts ? ts.getValue().map(Number) : []
        };
    }

    function empty() { document.getElementById('dcLinesEmpty')?.classList.toggle('d-none', body.children.length > 0); }

    // changing what a line applies to rebuilds its services cell (a Service line gets the picker)
    body.addEventListener('change', e => {
        const tr = e.target.closest('tr'); if (!tr) return;
        if (e.target.classList.contains('dc-rev')) {
            const l = readRow(tr);
            pickers.get(tr)?.destroy(); pickers.delete(tr);
            tr.innerHTML = rowHtml(l); mountPicker(tr);
        }
        refresh(tr);
    });
    body.addEventListener('click', e => {
        const b = e.target.closest('.dc-del'); if (!b) return;
        const tr = b.closest('tr'); pickers.get(tr)?.destroy(); pickers.delete(tr); tr.remove(); empty();
    });
    document.getElementById('btnAddConsult')?.addEventListener('click', () =>
        addRow({ revenueType: 'Consultation', calculationType: 'Percentage', commissionBasis: 'Net Collected', doctorShare: '' }).querySelector('.dc-share').focus());
    document.getElementById('btnAddService')?.addEventListener('click', () =>
        addRow({ revenueType: 'Service', calculationType: 'Percentage', commissionBasis: 'Net Collected', doctorShare: '', serviceIds: [] }).querySelector('.dc-share').focus());
    document.getElementById('btnAddOther')?.addEventListener('click', () =>
        addRow({ revenueType: (D.revenueTypes || []).find(r => r !== 'Consultation' && r !== 'Consultant' && r !== 'Service') || 'Procedure',
                 calculationType: 'Percentage', commissionBasis: 'Net Collected', doctorShare: '' }).querySelector('.dc-rev').focus());

    // the same rules as the server, told before sending
    function problem(lines) {
        if (!lines.length) return 'Add at least one share line.';
        if (lines.some(l => !(l.doctorShare > 0))) return 'Each share line needs a share above 0.';
        if (lines.some(l => l.calculationType !== 'Fixed Amount' && l.doctorShare > 100)) return 'A percentage share cannot be above 100.';
        const kinds = lines.filter(l => l.revenueType !== 'Service').map(l => l.revenueType === 'Consultant' ? 'Consultation' : l.revenueType);
        const dup = kinds.find((k, i) => kinds.indexOf(k) !== i);
        if (dup) return `Only one ${dup} line per profile.`;
        if (kinds.includes('All Services') && (kinds.includes('Consultation') || lines.some(l => l.revenueType === 'Service')))
            return 'An "All Services" line already shares the whole bill - remove it, or remove the Consultation / Service lines.';
        const svc = lines.filter(l => l.revenueType === 'Service');
        if (svc.filter(l => !l.serviceIds.length).length > 1) return 'Only one Service line can be for all services - pick the services of the others.';
        const ids = svc.flatMap(l => l.serviceIds);
        const twice = ids.find((x, i) => ids.indexOf(x) !== i);
        if (twice) return `The service ${(D.services || []).find(s => Number(s.id) === twice)?.text || twice} is in two Service lines - keep it in one.`;
        return null;
    }

    form.addEventListener('submit', e => {
        const lines = [...body.children].map(readRow);
        const p = problem(lines);
        if (p) {
            e.preventDefault();
            if (window.Swal) Swal.fire({ icon: 'warning', title: 'Check the commission shares', text: p }); else alert(p);
            return;
        }
        document.getElementById('linesJson').value = JSON.stringify(lines);
    });

    (D.lines || []).forEach(addRow);
    empty();
})();
