// moved from Views/Shared/_IdDocumentPreview.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    window.IdDocPreview = (function () {
        const kind = path => { const e = (path.split('?')[0].split('.').pop() || '').toLowerCase(); return e === 'pdf' ? 'pdf' : ['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(e) ? 'img' : ''; };

        function open(path) {
            if (!path) return;
            const img = document.getElementById('idDocPreviewImg'), frame = document.getElementById('idDocPreviewFrame'),
                  fb = document.getElementById('idDocPreviewFallback'), k = kind(path);
            document.getElementById('idDocPreviewOpen').href = path;
            img.style.display = k === 'img' ? '' : 'none'; img.src = k === 'img' ? path : '';
            frame.style.display = k === 'pdf' ? '' : 'none'; frame.src = k === 'pdf' ? path : '';
            fb.style.display = k ? 'none' : '';
            bootstrap.Modal.getOrCreateInstance(document.getElementById('idDocPreviewModal')).show();
        }

        // show (or hide, with no path) the uploaded document of the patient under the upload box
        function set(slotId, path) {
            const slot = document.getElementById(slotId);
            if (!slot) return;
            slot.dataset.path = path || '';
            if (!path) { slot.innerHTML = ''; slot.classList.add('d-none'); return; }
            const name = decodeURIComponent(path.split('/').pop() || '').replace(/^[0-9a-f-]{20,}_?/i, '') || 'ID document';
            slot.innerHTML = `<div class="idp-row"><i class="bi bi-file-earmark-check"></i><span>Already uploaded${kind(path) ? ' (' + kind(path).replace('img', 'image').toUpperCase() + ')' : ''}</span>
                <button type="button" class="btn btn-sm btn-outline-primary py-0 px-2 idp-preview"><i class="bi bi-eye me-1"></i>Preview</button></div>
                <div class="idp-new d-none"><i class="bi bi-info-circle me-1"></i>The new file you chose replaces it when you save.</div>`;
            slot.classList.remove('d-none');
            slot.querySelector('.idp-preview').addEventListener('click', () => open(slot.dataset.path));
        }

        document.addEventListener('DOMContentLoaded', function () {
            // slots rendered with a path (the page reloaded with an existing patient)
            document.querySelectorAll('.id-doc-existing[data-path]').forEach(s => set(s.id, s.dataset.path));
            // a new file chosen while one is on record: say it will replace it
            document.querySelectorAll('input[type=file][name=identificationFile]').forEach(inp => inp.addEventListener('change', () => {
                document.querySelectorAll('.id-doc-existing .idp-new').forEach(n => n.classList.toggle('d-none', !inp.files.length));
            }));
            document.getElementById('idDocPreviewModal')?.addEventListener('hidden.bs.modal', () => {
                document.getElementById('idDocPreviewFrame').src = ''; document.getElementById('idDocPreviewImg').src = '';
            });
        });
        return { set, open };
    })();
