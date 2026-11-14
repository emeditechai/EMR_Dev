// moved from Views/LabReporting/_LabReportingMixedTypeScripts.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    (function () {
        const editors = new Map();   // samplecollection id -> Quill

        function rowById(id) { return $('.test-item-row[data-samplecollection-id="' + id + '"]'); }

        // Hooks the page's save calls: the narrative text goes with the row, and is the new baseline once saved.
        window.labEntryHooks = {
            templateHtml: function ($row) {
                const q = editors.get(String($row.data('samplecollection-id')));
                return q ? q.root.innerHTML : null;
            },
            onSaved: function (id) {
                const q = editors.get(String(id));
                if (!q) return;
                const $row = rowById(id);
                $row.attr('data-initial-html', q.root.innerHTML).removeAttr('data-html-dirty');
            }
        };

        // Runs fn whenever the page locks / unlocks / disables the hidden value input.
        function watchLock(input, fn) {
            new MutationObserver(fn).observe(input, { attributes: true, attributeFilter: ['readonly', 'disabled'] });
        }

        // ── Select (picklist): flag from the chosen option's Is_Abnormal ─────────────
        function applyPickFlag($row) {
            const $h = $row.find('.txt-test-val.is-picklist');
            const $sel = $row.find('.picklist-select');
            const val = $h.val() || '';
            const abnormal = val.length > 0 && $sel.find('option:selected').attr('data-abnormal') === '1';
            const flag = val.length === 0 ? '' : (abnormal ? 'Abnormal' : 'Normal');
            $row.find('.flag-badge')
                .attr('class', 'badge flag-badge ' + (flag === '' ? 'flag-none' : (abnormal ? 'flag-h' : 'flag-normal')) + ' fs-8 px-2 py-1')
                .text(flag === '' ? '—' : flag);
            $row.attr('data-current-flag', flag);
            $sel.toggleClass('is-abnormal', abnormal).toggleClass('is-normal', val.length > 0 && !abnormal);
        }

        function initPicklist($row) {
            const $h = $row.find('.txt-test-val.is-picklist');
            const $sel = $row.find('.picklist-select');

            watchLock($h[0], function () {
                const off = $h.prop('disabled') || $h.prop('readonly');
                if ($h.prop('disabled')) $sel.val('');
                else $sel.val($h.val() || '');
                $sel.prop('disabled', off).toggleClass('bg-light text-dark', off);
                applyPickFlag($row);
            });

            $sel.on('change', function () {
                $h.val($sel.val() || '').trigger('change');
            });

            // A parameter not reported yet starts on its default answer (Lab Parameter Option Master > Is Default).
            const def = $h.attr('data-default-pick') || '';
            if (!$h.val() && def && !$h.prop('disabled') && !$h.prop('readonly')) {
                $sel.val(def);
                if ($sel.val() === def) $h.val(def).trigger('change');
            }
            applyPickFlag($row);
        }

        // ── Narrative (Descriptive / Image / other types): Quill editor ──────────────
        function initNarrative($row) {
            const id = String($row.data('samplecollection-id'));
            const $h = $row.find('.txt-test-val.is-narrative');
            const $box = $row.find('.narrative-box');
            const defaultHtml = $box.find('.narrative-default').val() || '';

            const q = new Quill($box.find('.narrative-editor')[0], {
                theme: 'snow',
                placeholder: 'Write the report…',
                modules: { toolbar: [[{ header: [false, 3, 4] }], ['bold', 'italic', 'underline'], [{ list: 'ordered' }, { list: 'bullet' }], ['clean']] }
            });
            const startHtml = $box.find('.narrative-start').val() || '';
            if (startHtml) q.clipboard.dangerouslyPasteHTML(startHtml, 'silent');
            editors.set(id, q);
            $row.attr('data-initial-html', q.root.innerHTML);

            let wasDisabled = $h.prop('disabled');
            function applyLock() {
                const disabled = $h.prop('disabled');
                const locked = disabled || $h.prop('readonly');
                if (disabled) {
                    q.setText('', 'silent');                      // re-collect / rejected: the result was cleared
                } else if (wasDisabled && q.getText().trim().length === 0 && defaultHtml) {
                    q.clipboard.dangerouslyPasteHTML(defaultHtml, 'silent');   // back to Collected: start from the template
                    $row.attr('data-initial-html', '');
                }
                wasDisabled = disabled;
                q.enable(!locked);
                $box.toggleClass('is-locked', locked);
                $box.find('.btn-narrative-reset').toggleClass('d-none', locked || !defaultHtml);
            }
            watchLock($h[0], applyLock);
            applyLock();

            q.on('text-change', function (delta, old, source) {
                if (source !== 'user') return;
                const html = q.root.innerHTML;
                if (html !== $row.attr('data-initial-html')) $row.attr('data-html-dirty', '1');
                else $row.removeAttr('data-html-dirty');
                $h.val(q.getText().trim().length ? 'Report Entered' : '').trigger('change');
            });

            $box.find('.btn-narrative-reset').on('click', function () {
                Swal.fire({
                    title: 'Reset to template?',
                    text: 'The text written for this test is replaced with its template.',
                    icon: 'warning',
                    showCancelButton: true,
                    confirmButtonText: 'Yes, reset'
                }).then(function (r) {
                    if (!r.isConfirmed) return;
                    q.setContents([], 'silent');
                    q.clipboard.dangerouslyPasteHTML(defaultHtml, 'user');
                });
            });

            // A template-filled, not yet reported narrative counts as entered (like a picklist default), to Submit as is or edit.
            if (!$h.val() && !$h.prop('disabled') && !$h.prop('readonly') && q.getText().trim().length) {
                $h.val('Report Entered').trigger('change');
            }
        }

        $(function () {
            $('.test-item-row').each(function () {
                const $row = $(this);
                if ($row.find('.txt-test-val.is-picklist').length) initPicklist($row);
                else if ($row.find('.txt-test-val.is-narrative').length) initNarrative($row);
            });

            // Registered after the page's own handler, so the picklist flag replaces the numeric evaluation.
            $(document).on('input change', '.txt-test-val.is-picklist', function () {
                applyPickFlag($(this).closest('.test-item-row'));
            });

            // An edited narrative of a submitted / validated row is "Modified (Unsaved)" (its marker value does not change).
            $(document).on('input change', '.txt-test-val.is-narrative', function () {
                const $row = $(this).closest('.test-item-row');
                const statusId = parseInt($row.attr('data-report-status-id')) || 0;
                if (statusId >= 2 && $row.attr('data-html-dirty') === '1') {
                    $row.find('.row-status-badge')
                        .attr('class', 'badge fs-9 row-status-badge bg-warning-subtle text-warning-emphasis border border-warning-subtle')
                        .text('Modified (Unsaved)');
                }
            });
        });
    })();
