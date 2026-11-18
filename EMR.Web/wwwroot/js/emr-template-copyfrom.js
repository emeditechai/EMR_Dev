/* Create EMR Template > Start from an existing template (SQLScripts/2483): pick a speciality (and, if wanted, a doctor: the
   template that doctor uses is chosen for you), then Copy - the editor opens with all sections and fields as a new template. */
$(function () {
    'use strict';
    const box = document.getElementById('etCopy'); if (!box) return;
    const $spec = $('#cfSpec'), $doc = $('#cfDoc'), list = document.getElementById('cfList'), btn = document.getElementById('cfCopy');
    const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    let picked = null, data = null, req = 0;

    // the specialities of the template form
    $('#SelectedSpecialityIds option').each((_, o) => { if (o.value) $spec.append(new Option(o.text, o.value)); });
    $spec.select2({ theme: 'bootstrap-5', width: '100%', placeholder: $spec.data('placeholder'), allowClear: true });
    $doc.select2({ theme: 'bootstrap-5', width: '100%' });

    function render() {
        const rows = (data && data.templates) || [];
        if (!$spec.val()) { list.innerHTML = '<div class="text-muted small">Choose a speciality to see its templates.</div>'; return; }
        if (!rows.length) { list.innerHTML = '<div class="text-muted small"><i class="bi bi-inbox me-1"></i>This speciality has no template yet. Start from a blank canvas below.</div>'; return; }
        const docId = $doc.val();
        // a doctor chosen: only their own template; no doctor: every template of the speciality
        const shown = docId ? rows.filter(t => t.templateId === data.usedTemplateId) : rows;
        list.innerHTML = (docId ? `<div class="small mb-2 text-success"><i class="bi bi-person-check me-1"></i>The doctor's own template.
                <button type="button" class="btn btn-link btn-sm p-0 align-baseline" id="cfAll">Show all templates of the speciality</button></div>` : '')
            + shown.map(t => `<label class="et-copy-card ${picked === t.templateId ? 'sel' : ''} ${t.isActive ? '' : 'inactive'}">
                <input type="radio" name="cfPick" value="${t.templateId}" ${picked === t.templateId ? 'checked' : ''} />
                <div class="flex-grow-1">
                    <div class="d-flex flex-wrap align-items-center gap-2"><span class="fw-semibold">${esc(t.templateName)}</span>
                        ${t.kind === 'DOCTOR' ? '<span class="badge text-bg-warning">Doctor-specific</span>' : '<span class="badge text-bg-info">Speciality default</span>'}
                        ${t.isActive ? '' : '<span class="badge text-bg-secondary">Inactive</span>'}
                        ${docId && data.usedTemplateId === t.templateId ? '<span class="badge text-bg-success"><i class="bi bi-person-check me-1"></i>this doctor\'s template</span>' : ''}</div>
                    <div class="small text-muted">${t.sections} section(s) · ${t.fields} field(s)${t.doctors && t.doctors.length ? ' · Dr ' + t.doctors.map(esc).join(', Dr ') : ''}${t.description ? ' · ' + esc(t.description) : ''}</div>
                </div></label>`).join('');
        btn.disabled = !picked;
    }

    async function load() {
        const spec = $spec.val(), mine = ++req;
        picked = null; btn.disabled = true;
        if (!spec) { data = null; $doc.prop('disabled', true).empty().append(new Option('Any doctor - all templates of the speciality', '')).trigger('change.select2'); render(); return; }
        list.innerHTML = '<div class="text-muted small">Loading…</div>';
        let d = null;
        try { const r = await fetch(box.dataset.url + '?' + new URLSearchParams({ specialityId: spec, doctorId: $doc.val() || '' }), { headers: { 'X-Requested-With': 'XMLHttpRequest' } }); d = r.ok ? await r.json() : null; } catch { d = null; }
        if (mine !== req) return;
        data = d || { templates: [] };
        // doctors who have their own template in this speciality (kept when only the doctor changed)
        if (!$doc.data('spec') || String($doc.data('spec')) !== String(spec)) {
            const keep = $doc.val(), docs = data.doctors || [];
            $doc.empty().append(new Option(docs.length ? 'Any doctor - all templates of the speciality' : 'No doctor-specific template in this speciality', ''));
            docs.forEach(x => $doc.append(new Option(`${x.name} · ${x.templateName || 'own template'}${x.doctorActive ? '' : ' (inactive doctor)'}`, x.doctorId, false, String(x.doctorId) === String(keep))));
            $doc.data('spec', spec).prop('disabled', !docs.length).trigger('change.select2');
        }
        picked = data.usedTemplateId || ((data.templates || []).length === 1 ? data.templates[0].templateId : null);
        render();
    }

    $spec.on('change', () => { $doc.data('spec', ''); $doc.val(''); load(); });
    $doc.on('change', load);
    list.addEventListener('click', e => { if (e.target.closest('#cfAll')) { $doc.val('').trigger('change'); } });
    list.addEventListener('change', e => { if (e.target.name === 'cfPick') { picked = Number(e.target.value); render(); } });
    btn.addEventListener('click', async () => {
        if (!picked) return;
        const hasWork = document.querySelectorAll('#sectionsContainer .field-row').length > 0;
        if (hasWork && window.Swal) {
            const r = await Swal.fire({ icon: 'question', title: 'Copy this template?', text: 'The canvas below is replaced by the copied sections and fields. Nothing is saved until you click Save Template.',
                showCancelButton: true, confirmButtonText: 'Copy' });
            if (!r.isConfirmed) return;
        }
        window.location.href = box.dataset.create + '?copyFromId=' + picked;
    });
})();
