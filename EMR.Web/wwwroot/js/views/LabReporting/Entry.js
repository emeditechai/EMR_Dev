/* Lab Report Entry / Microbiology Report Entry (Views/LabReporting/Entry.cshtml): moved from the page's inline <script>
   so the browser caches it. The page's values come from window.labEntryCfg (set by the page just before this file):
   labOrderId, pathologistApprovalRequired, formulaUrl, saveUrl, sampleStatusUrl. Behaviour unchanged. */
        $(document).ready(function () {
            toastr.options = {
                closeButton: true,
                progressBar: true,
                positionClass: "toast-top-right",
                timeOut: "3500"
            };

            const labOrderId = window.labEntryCfg.labOrderId;
            const PATHOLOGIST_APPROVAL_REQUIRED = window.labEntryCfg.pathologistApprovalRequired === true;

            // Initialize Bootstrap Tooltips for Special Remarks (i) icon
            var tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
            var tooltipList = tooltipTriggerList.map(function (tooltipTriggerEl) {
                return new bootstrap.Tooltip(tooltipTriggerEl);
            });

            // ── Status column tooltip: date/time of each stage reached (small font) ────────
            // Times come from the row's data-time-* attributes (server-rendered, and stamped after a save).
            // The tooltip is derived from the badge's current text so every existing badge update stays in sync.
            const STATUS_TIP_STAGES = [
                { id: 1, key: 'drafted',   label: 'Drafted' },
                { id: 2, key: 'submitted', label: 'Submitted' },
                { id: 3, key: 'validated', label: 'Validated' },
                { id: 5, key: 'approved',  label: 'Approved' }
            ];
            const STATUS_TIP_BY_TEXT = { 'draft': 1, 'entered': 2, 'validated': 3, 'approved': 5 };

            function refreshStatusTip(badgeEl) {
                const $badge = $(badgeEl);
                const existing = bootstrap.Tooltip.getInstance(badgeEl);
                if (existing) existing.dispose();
                $badge.removeAttr('data-bs-toggle title data-bs-original-title');

                const currentStage = STATUS_TIP_BY_TEXT[$badge.text().trim().toLowerCase()];
                if (!currentStage) return; // Pending / unsaved / re-collect states have no date to show

                const lines = STATUS_TIP_STAGES
                    .filter(function (st) { return st.id <= currentStage && $badge.attr('data-time-' + st.key); })
                    .map(function (st) {
                        return '<div><span class="status-tip-label">' + st.label + ':</span> ' + escapeHtml($badge.attr('data-time-' + st.key)) + '</div>';
                    });
                if (!lines.length) return;

                $badge.attr('data-bs-toggle', 'tooltip');
                new bootstrap.Tooltip(badgeEl, {
                    html: true,
                    title: lines.join(''),
                    placement: 'top',
                    container: 'body',
                    customClass: 'status-time-tooltip'
                });
            }

            const statusTipObserver = new MutationObserver(function (mutations) {
                const badges = new Set();
                mutations.forEach(function (m) {
                    const el = m.target.nodeType === 1 ? m.target : m.target.parentElement;
                    const badge = el && el.closest ? el.closest('.row-status-badge') : null;
                    if (badge) badges.add(badge);
                });
                badges.forEach(refreshStatusTip);
            });
            document.querySelectorAll('.row-status-badge').forEach(function (badgeEl) {
                refreshStatusTip(badgeEl);
                statusTipObserver.observe(badgeEl, { childList: true, characterData: true, subtree: true });
            });

            // ── Report progress strip (read-only): counts rows by the state shown on their status badge ──
            const WF_KEYS = ['approved', 'validated', 'submitted', 'draft', 'recollect', 'pending'];

            function classifyRowStatus(text) {
                const t = (text || '').trim().toLowerCase();
                if (t === 'approved') return 'approved';
                if (t === 'validated') return 'validated';
                if (t === 'entered') return 'submitted';
                if (t === 'draft' || t.indexOf('unsaved') !== -1) return 'draft';
                if (t.indexOf('re-collect') !== -1 || t.indexOf('rejected') !== -1) return 'recollect';
                return 'pending';
            }

            // Print Report is available once any test is Validated/Approved; amber "Not Approved" while a printed test is unapproved.
            function syncPrintButtons(counts) {
                const printable = counts.validated + counts.approved;
                // Part approved / part validated => two prints: approved tests (clean) + not-approved tests (watermarked)
                const split = counts.approved > 0 && counts.validated > 0;
                const provisional = counts.validated > 0 && !split;
                const $btns = $('#btnHeaderPrint, #btnStickyPrint');
                $btns.toggle(printable > 0)
                     .toggleClass('is-provisional', provisional)
                     .attr('data-scope', split ? 'approved' : 'all')
                     .attr('title', split ? 'Preview and print the approved tests' : 'Preview and print the lab report')
                     .find('.print-btn-label').text(provisional ? 'Print (Not Approved)' : 'Print Report');
                $('#btnHeaderPrintPending, #btnStickyPrintPending').toggle(split);
            }

            function refreshWorkflowProgress() {
                const counts = { approved: 0, validated: 0, submitted: 0, draft: 0, recollect: 0, pending: 0 };
                let total = 0;
                $('.test-item-row .row-status-badge').each(function () {
                    counts[classifyRowStatus($(this).text())]++;
                    total++;
                });

                WF_KEYS.forEach(function (k) {
                    $('#wfCount_' + k).text(counts[k]);
                    $('.wf-chip[data-wf="' + k + '"]').toggleClass('is-zero', counts[k] === 0);
                    $('.wf-seg[data-wf="' + k + '"]').css('width', total ? (counts[k] / total * 100) + '%' : '0%');
                });

                syncPrintButtons(counts);

                const pct = total ? Math.round(counts.approved / total * 100) : 0;
                $('#wfPercent').text(total ? (counts.approved + ' of ' + total + ' tests approved (' + pct + '%)') : '');
                $('#wfBar').attr('aria-valuenow', pct);
            }

            let wfFrameQueued = false;
            function queueWorkflowProgress() {
                if (wfFrameQueued) return;
                wfFrameQueued = true;
                requestAnimationFrame(function () { wfFrameQueued = false; refreshWorkflowProgress(); });
            }

            const workflowObserver = new MutationObserver(queueWorkflowProgress);
            document.querySelectorAll('.row-status-badge').forEach(function (badgeEl) {
                workflowObserver.observe(badgeEl, { childList: true, characterData: true, subtree: true });
            });
            refreshWorkflowProgress();

            // ── Live Flag, Delta Check & Auto-calc Evaluator ─────────────────
            function evaluateRow($row, isUserTyping) {
                const testCode = $row.data('test-code');
                const lowVal = parseFloat($row.data('low-val'));
                const highVal = parseFloat($row.data('high-val'));
                const prevVal = parseFloat($row.data('prev-val'));
                // Critical / Panic tier of the matched reference range: beyond these limits the result is
                // flagged 'Critical' / 'Panic' (checked before the normal L / H range).
                const tier = $row.attr('data-tier') || '';
                const lowThr = parseFloat($row.attr('data-low-thr'));
                const highThr = parseFloat($row.attr('data-high-thr'));
                const $valInput = $row.find('.txt-test-val');
                const $flagBadge = $row.find('.flag-badge');
                const $deltaContainer = $row.find('.delta-check-container');
                const $deltaDiff = $row.find('.delta-diff-display');
                const $statusBadge = $row.find('.row-status-badge');
                const isAutoCalc = testCode === 'TST0045' || testCode === 'TST0046';

                const rawVal = $valInput.val()?.trim() || '';
                const numVal = parseFloat(rawVal);
                const isNumeric = !isNaN(numVal) && rawVal.length > 0;

                let flag = 'Normal';
                let flagText = 'Normal';
                let flagClass = 'flag-normal';

                $valInput.removeClass('is-flagged-l is-flagged-h');

                if (isNumeric) {
                    const isThresholdTier = tier === 'Critical Value' || tier === 'Panic Value';
                    const thrDir = !isThresholdTier ? ''
                        : (!isNaN(lowThr) && numVal < lowThr ? 'L' : (!isNaN(highThr) && numVal > highThr ? 'H' : ''));

                    if (thrDir) {
                        const isPanic = tier === 'Panic Value';
                        flag = isPanic ? 'Panic' : 'Critical';
                        flagText = flag + ' ' + thrDir;
                        flagClass = isPanic ? 'flag-panic' : 'flag-critical';
                        $valInput.addClass(thrDir === 'L' ? 'is-flagged-l' : 'is-flagged-h');
                    } else if (!isNaN(lowVal) && numVal < lowVal) {
                        flag = 'L';
                        flagText = 'L';
                        flagClass = 'flag-l';
                        $valInput.addClass('is-flagged-l');
                    } else if (!isNaN(highVal) && numVal > highVal) {
                        flag = 'H';
                        flagText = 'H';
                        flagClass = 'flag-h';
                        $valInput.addClass('is-flagged-h');
                    }

                    // Delta Check
                    if (!isNaN(prevVal) && prevVal > 0 && isNumeric) {
                        const deltaPct = Math.round(Math.abs(numVal - prevVal) / prevVal * 100);
                        $deltaContainer.show();
                        if (deltaPct >= 25) {
                            $deltaDiff.html(`&bull; <span class="text-warning-emphasis fw-bold font-monospace">&Delta; ${deltaPct}% &mdash; delta check flagged</span>`);
                        } else {
                            $deltaDiff.html(`&bull; <span class="text-secondary font-monospace">&Delta; ${deltaPct}%</span>`);
                        }
                    } else if (!isNaN(prevVal)) {
                        $deltaContainer.show();
                        $deltaDiff.empty();
                    }
                } else {
                    flag = '';
                    flagText = '—';
                    flagClass = 'flag-none';
                    $deltaDiff.empty();
                }

                $flagBadge.attr('class', `badge flag-badge ${flagClass} fs-8 px-2 py-1`).text(flagText);
                $row.attr('data-current-flag', flag);

                // Update row status badge if actively typing
                if (isUserTyping) {
                    const isApprovedRow = $statusBadge.text().trim().toLowerCase().includes('approved');
                    if (!isApprovedRow) {
                        const initialVal = ($row.attr('data-initial-val') ?? '').trim();
                        const reportStatusId = parseInt($row.attr('data-report-status-id')) || 0;
                        if (rawVal.length === 0) {
                            $statusBadge.attr('class', 'badge fs-9 row-status-badge bg-secondary-subtle text-secondary border border-secondary-subtle').text('Pending entry');
                        } else if (reportStatusId >= 2 && rawVal !== initialVal) {
                            $statusBadge.attr('class', 'badge fs-9 row-status-badge bg-warning-subtle text-warning-emphasis border border-warning-subtle').text('Modified (Unsaved)');
                        } else if (reportStatusId < 2) {
                            $statusBadge.attr('class', 'badge fs-9 row-status-badge bg-warning-subtle text-warning-emphasis border border-warning-subtle').text('Entered (Unsaved)');
                        } else if (reportStatusId === 3) {
                            $statusBadge.attr('class', 'badge fs-9 row-status-badge bg-success-subtle text-success border border-success-subtle').text('Validated');
                        } else {
                            $statusBadge.attr('class', 'badge fs-9 row-status-badge status-entered').text('Entered');
                        }
                    }
                }

                // Calculated parameters are refreshed from the server after a typed change
                if (isUserTyping && !$row.find('.txt-test-val').hasClass('is-formula')) {
                    cascadeCalculations();
                }
            }

            // ── Calculated parameters (Lab Master > Lab Formula Component) ──────────────
            // The value of every configured target test is worked out on the server from its formula,
            // so the browser never decides the result. It runs while the technician types, debounced.
            const formulaUrl = window.labEntryCfg.formulaUrl;
            const hasFormulaRows = $('.txt-test-val.is-formula').length > 0;
            let formulaTimer = null;
            let formulaInFlight = false;

            function currentEntryValues() {
                const values = [];
                $('.test-item-row').each(function () {
                    const code = $(this).data('test-code');
                    if (!code) return;
                    const $inp = $(this).find('.txt-test-val');
                    if (!$inp.length || $inp.hasClass('is-formula')) return;   // only typed values feed a formula
                    values.push({ testCode: String(code), value: $inp.val() ?? '' });
                });
                return values;
            }

            function applyFormulaResult(r, markDirty) {
                const $row = $('tr[data-test-code="' + r.targetTestCode + '"]');
                if (!$row.length) return;
                const $inp = $row.find('.txt-test-val');
                if (!$inp.length || $inp.prop('disabled')) return;

                // an approved / validated value is never overwritten
                const reportStatusId = parseInt($row.attr('data-report-status-id')) || 0;
                if (reportStatusId >= 3) return;

                const $note = $row.find('.formula-note');
                const newVal = r.value ?? '';
                const changed = ($inp.val() ?? '') !== newVal;

                if (changed) {
                    $inp.val(newVal);
                    if (markDirty && newVal !== '') {
                        isPageDirty = true;
                        $row.find('.row-status-badge')
                            .attr('class', 'badge fs-9 row-status-badge bg-warning-subtle text-warning-emphasis border border-warning-subtle')
                            .text(reportStatusId >= 2 ? 'Modified (Unsaved)' : 'Entered (Unsaved)');
                    }
                    evaluateRow($row, false);
                }

                if (r.value == null && r.message) {
                    // show test names instead of codes in "Waiting for ..."
                    let msg = r.message;
                    (r.missingCodes || []).forEach(code => {
                        const name = $('tr[data-test-code="' + code + '"]').find('.fw-bold.text-dark').first().text().trim();
                        if (name) msg = msg.replace(code, name);
                    });
                    $note.text(msg).show();
                } else {
                    $note.hide().text('');
                }
            }

            function recalcFormulas(markDirty) {
                if (!hasFormulaRows || formulaInFlight) return;
                formulaInFlight = true;
                $.ajax({
                    url: formulaUrl,
                    type: 'POST',
                    contentType: 'application/json',
                    data: JSON.stringify({ labOrderId: labOrderId, values: currentEntryValues() })
                })
                .done(function (res) {
                    if (!res || !res.success || !res.results) return;
                    res.results.forEach(r => applyFormulaResult(r, markDirty));
                    updateFilledCount();
                    updateActionButtonsVisibility();
                })
                .always(function () { formulaInFlight = false; });
            }

            function cascadeCalculations() {
                if (!hasFormulaRows) return;
                clearTimeout(formulaTimer);
                formulaTimer = setTimeout(() => recalcFormulas(true), 350);
            }

            // ── Live counter update ─────────────────────────────────────────
            function updateFilledCount() {
                let totalFilled = 0;
                let totalCount = 0;
                const groupCounts = {};

                $('.test-item-row').each(function () {
                    const grpId = $(this).data('grpid');
                    if (grpId && groupCounts[grpId] === undefined) {
                        groupCounts[grpId] = 0;
                    }

                    const $valInp = $(this).find('.txt-test-val');
                    if ($valInp.prop('disabled')) {
                        return;
                    }

                    totalCount++;
                    const val = $valInp.val()?.trim() || '';
                    if (val.length > 0) {
                        totalFilled++;
                        if (grpId) groupCounts[grpId]++;
                    }
                });

                $('#counterEntered').text(`${totalFilled} / ${totalCount} Values Filled`);

                // Update per-group header badges
                $('.group-filled-val').each(function () {
                    const grpId = $(this).data('grpid');
                    $(this).text(groupCounts[grpId] || 0);
                });
            }

            // ── Dirty State and Unsaved Changes Tracking ─────────────────────
            let isPageDirty = false;

            function hasUnsavedChanges() {
                if (isPageDirty) return true;

                let hasChanges = false;
                $('.test-item-row').each(function () {
                    const $row = $(this);
                    const $valInp = $row.find('.txt-test-val');
                    if ($valInp.prop('disabled')) return; // skip rejected / recollected

                    const curVal = $valInp.val()?.trim() || '';
                    const initVal = ($row.attr('data-initial-val') ?? '').trim();
                    if (curVal !== initVal) {
                        hasChanges = true;
                        return false;
                    }

                    const curRemarks = $row.find('.txt-test-remarks').val()?.trim() || '';
                    const initRemarks = ($row.attr('data-initial-remarks') ?? '').trim();
                    if (curRemarks !== initRemarks) {
                        hasChanges = true;
                        return false;
                    }

                    // narrative text edited (Microbiology Report Entry)
                    if ($row.attr('data-html-dirty') === '1') {
                        hasChanges = true;
                        return false;
                    }

                    // Any unlocked row that was previously saved
                    if (!$valInp.prop('readonly') && initVal.length > 0) {
                        hasChanges = true;
                        return false;
                    }
                });

                if (hasChanges) return true;

                // Check group lab remarks
                $('.txt-group-lab-remarks').each(function () {
                    const curRemarks = $(this).val()?.trim() || '';
                    const initRemarks = ($(this).attr('data-initial-val') ?? '').trim();
                    if (curRemarks !== initRemarks) {
                        hasChanges = true;
                        return false;
                    }
                });

                return hasChanges;
            }

            // Evaluate all rows on initial page load
            $('.test-item-row').each(function () {
                evaluateRow($(this), false);
            });
            updateFilledCount();
            updateActionButtonsVisibility();
            recalcFormulas(false);   // show the calculated parameters for values already saved

            // Handle live input typing on test result values
            $(document).on('input change', '.txt-test-val', function () {
                const $row = $(this).closest('.test-item-row');
                isPageDirty = true;
                evaluateRow($row, true);
                updateFilledCount();
                updateActionButtonsVisibility();
            });

            // Handle live input typing on test clinical remarks
            $(document).on('input change', '.txt-test-remarks', function () {
                const $row = $(this).closest('.test-item-row');
                const curRemarks = $(this).val()?.trim() || '';
                const initRemarks = ($row.attr('data-initial-remarks') ?? '').trim();
                const reportStatusId = parseInt($row.attr('data-report-status-id')) || 0;
                if (curRemarks !== initRemarks) {
                    isPageDirty = true;
                    if (reportStatusId >= 2) {
                        $row.find('.row-status-badge').attr('class', 'badge fs-9 row-status-badge bg-warning-subtle text-warning-emphasis border border-warning-subtle').text('Modified (Unsaved)');
                    }
                }
                updateActionButtonsVisibility();
            });

            // Handle live input on group lab remarks
            $(document).on('input change', '.txt-group-lab-remarks', function () {
                const curRemarks = $(this).val()?.trim() || '';
                const initRemarks = ($(this).attr('data-initial-val') ?? '').trim();
                if (curRemarks !== initRemarks) {
                    isPageDirty = true;
                }
                updateActionButtonsVisibility();
            });

            // Prevent accidental mousewheel increment/decrement on numeric inputs
            $(document).on('wheel', '.txt-test-val', function (e) {
                $(this).blur();
            });

            // ── Expand / Collapse Group Logic ───────────────────────────────
            $(document).on('click', '.group-collapse-toggle, .group-toggle-btn', function (e) {
                e.stopPropagation();
                const grpId = $(this).data('target');
                const rows = $(`.group-child-${grpId}`);
                const icon = $(`#icon_${grpId}`);
                const btnText = $(`button.group-toggle-btn[data-target="${grpId}"] .toggle-text`);

                if (rows.is(':visible')) {
                    rows.hide();
                    icon.addClass('collapsed');
                    btnText.text('Expand');
                } else {
                    rows.show();
                    icon.removeClass('collapsed');
                    btnText.text('Collapse');
                    
                    rows.each(function() {
                        if ($(this).hasClass('group-header-row')) {
                            const childId = $(this).find('.group-toggle-btn').data('target');
                            if (childId) {
                                $(`#icon_${childId}`).removeClass('collapsed');
                                $(`button.group-toggle-btn[data-target="${childId}"] .toggle-text`).text('Collapse');
                                $(`.group-child-${childId}`).show();
                            }
                        }
                    });
                }
            });

            // ── Expand All / Collapse All ───────────────────────────────────
            $('#btnExpandAll').on('click', function () {
                $('.test-item-row, .lab-remarks-row').show();
                $('.group-collapse-icon').removeClass('collapsed');
                $('.group-toggle-btn .toggle-text').text('Collapse');
            });

            $('#btnCollapseAll').on('click', function () {
                $('.test-item-row.can-collapse, .lab-remarks-row.can-collapse').hide();
                $('.group-collapse-icon').addClass('collapsed');
                $('.group-toggle-btn .toggle-text').text('Expand');
            });

            // ── Dynamic Action Button Visibility ────────────────────────────
            function updateActionButtonsVisibility() {
                let totalActiveCount = 0;
                let unenteredCount = 0;
                let unsubmittedCount = 0;
                let submittedCount = 0;
                let validatedCount = 0;
                let approvedCount = 0;

                const hasDirtyOrUnsaved = hasUnsavedChanges();

                $('.test-item-row').each(function () {
                    const $row = $(this);
                    const $valInp = $row.find('.txt-test-val');
                    if ($valInp.prop('disabled')) {
                        return; // Exclude rejected / re-collected tests
                    }

                    totalActiveCount++;
                    const curVal = $valInp.val()?.trim() || '';
                    const initVal = ($row.attr('data-initial-val') ?? '').trim();
                    const curRemarks = $row.find('.txt-test-remarks').val()?.trim() || '';
                    const initRemarks = ($row.attr('data-initial-remarks') ?? '').trim();
                    const reportStatusId = parseInt($row.attr('data-report-status-id')) || 0;
                    const isUnlocked = !$valInp.prop('readonly') && initVal.length > 0;
                    const isRowModified = (curVal !== initVal) || (curRemarks !== initRemarks) || isUnlocked || $row.attr('data-html-dirty') === '1';

                    if (curVal.length === 0) {
                        unenteredCount++;
                    } else if (isRowModified || reportStatusId < 2) {
                        // Unsaved modification or not yet submitted to DB
                        unsubmittedCount++;
                    } else if (reportStatusId === 5) {
                        approvedCount++;
                    } else if (reportStatusId === 3) {
                        validatedCount++;
                    } else if (reportStatusId === 2) {
                        submittedCount++;
                    } else {
                        unsubmittedCount++;
                    }
                });

                const isAllApproved = (totalActiveCount > 0 && approvedCount === totalActiveCount);
                const isPartialApproved = (approvedCount > 0 && approvedCount < totalActiveCount);

                // 1. Submit button:
                // Visible whenever order is not fully approved AND (any unentered test exists OR any unsubmitted/dirty change exists)
                const needsSubmit = !isAllApproved && (unenteredCount > 0 || unsubmittedCount > 0 || hasDirtyOrUnsaved);
                if (needsSubmit) {
                    $('.btn-action-save').html('<i class="bi bi-send-check me-1"></i>Submit').show();
                } else {
                    $('.btn-action-save').hide();
                }

                // 2. Validate button:
                // Visible whenever order is not fully approved AND there is at least one submitted test awaiting validation!
                // Allows partial validation of submitted tests even if other tests are unentered.
                const canValidate = !isAllApproved && (submittedCount > 0);
                if (canValidate) {
                    $('.btn-action-validate').show();
                } else {
                    $('.btn-action-validate').hide();
                }

                // 3. Approve button:
                // Visible whenever order is not fully approved AND there is at least one validated test awaiting approval!
                // Allows partial approval of validated tests even if other tests are unentered or submitted.
                // PATHOLOGIST_APPROVAL_REQUIRED: approval is done on the Pathologist Dashboard, never here.
                const canApprove = !isAllApproved && (validatedCount > 0) && !PATHOLOGIST_APPROVAL_REQUIRED;
                if (canApprove) {
                    $('.btn-action-approve').show();
                } else {
                    $('.btn-action-approve').hide();
                }

                // 4. Approved Badges
                if (isAllApproved) {
                    $('#badgeHeaderApproved, #badgeApprovedFooter')
                        .removeClass('d-none')
                        .html('<i class="bi bi-patch-check-fill me-1"></i>Report Approved');
                    $('.btn-action-save, .btn-action-validate, .btn-action-approve').hide();
                } else if (isPartialApproved) {
                    $('#badgeHeaderApproved')
                        .removeClass('d-none')
                        .html(`<i class="bi bi-patch-check-fill me-1"></i>Partially Approved (${approvedCount}/${totalActiveCount})`);
                    $('#badgeApprovedFooter').addClass('d-none');
                } else {
                    $('#badgeHeaderApproved, #badgeApprovedFooter').addClass('d-none');
                }
            }

            // ── Row-Level Edit Handler ───────────────────────────────────────
            $(document).on('click', '.btn-edit-row', function (e) {
                e.preventDefault();
                const $btn = $(this);
                const $row = $btn.closest('.test-item-row');
                const $input = $row.find('.txt-test-val');

                $input.prop('readonly', false)
                      .removeClass('is-locked bg-light text-dark')
                      .addClass('border-primary shadow-sm')
                      .focus()
                      .select();

                $btn.removeClass('btn-outline-secondary').addClass('btn-primary text-white');
                $btn.find('i').removeClass('text-primary bi-pencil-square').addClass('text-white bi-pencil-fill');

                isPageDirty = true;
                $row.find('.row-status-badge').attr('class', 'badge fs-9 row-status-badge bg-warning-subtle text-warning-emphasis border border-warning-subtle').text('Modified (Unsaved)');
                updateActionButtonsVisibility();

                toastr.info('Row unlocked for editing. Modify value and click Submit to save.');
            });

            // ── A profile is reported complete: every test of a profile in entry gets a value (submit / validate) ──
            function missingProfileTests() {
                const missing = [];
                $('.test-item-row').removeClass('profile-missing').find('.txt-test-val').removeClass('is-invalid');
                $('.group-header-profile').each(function () {
                    const gid = (this.id || '').replace('header_', '');
                    if (!gid) return;
                    const $rows = $('.test-item-row.group-child-' + gid).filter(function () {
                        const $i = $(this).find('.txt-test-val').first();
                        return $i.length && !$i.prop('disabled') && !$i.prop('readonly');
                    });
                    if (!$rows.length) return;
                    // a profile is checked only once its entry is started (a value typed or saved in any of its tests);
                    // a profile left untouched is not reported now and is not asked for
                    const $all = $('.test-item-row.group-child-' + gid);
                    const started = $all.toArray().some(r => {
                        const $i = $(r).find('.txt-test-val').first();
                        return (($i.val() || '').toString().trim()) || ((($(r).attr('data-initial-val') || '').trim()) && !$i.prop('disabled'));
                    });
                    if (!started) return;
                    const names = [], $empty = [];
                    $rows.each(function () {
                        const $i = $(this).find('.txt-test-val').first();
                        if (!(($i.val() || '').toString().trim())) {
                            const name = $(this).find('td .fw-bold').first().text().trim();
                            names.push(name || $i.attr('aria-label') || $(this).data('test-code') || 'test');
                            $empty.push(this);
                        }
                    });
                    $empty.forEach(r => { $(r).addClass('profile-missing'); $(r).find('.txt-test-val').first().addClass('is-invalid'); });
                    if (names.length) {
                        const pname = $(this).find('[data-target-name]').first().attr('data-target-name') || $(this).find('.fw-bold').first().text().trim() || 'Profile';
                        missing.push({ profile: pname, tests: names, total: $rows.length });
                    }
                });
                return missing;
            }
            function warnMissingProfileTests(missing, action) {
                const html = missing.map(m => `<div class="text-start mb-2"><b>${$('<div>').text(m.profile).html()}</b> <span class="text-muted">(${m.tests.length} of ${m.total} not entered)</span>`
                    + `<ul class="mb-0 small">${m.tests.map(t => `<li>${$('<div>').text(t).html()}</li>`).join('')}</ul></div>`).join('');
                Swal.fire({ title: 'Profile tests without a value', icon: 'warning', width: 640,
                    html: `<div class="small text-start mb-2">A profile once started is reported complete. Enter the missing values of these profiles before you ${action} (profiles not started are left for later):</div>${html}`,
                    confirmButtonText: 'Enter the values' }).then(() => {
                    const $first = $('.test-item-row.profile-missing').first();
                    if ($first.length) { $first[0].scrollIntoView({ behavior: 'smooth', block: 'center' }); $first.find('.txt-test-val').first().trigger('focus'); }
                });
            }
            $(document).on('input change', '.txt-test-val.is-invalid', function () {
                if ((($(this).val() || '').toString().trim())) { $(this).removeClass('is-invalid'); $(this).closest('.test-item-row').removeClass('profile-missing'); }
            });

            // ── Action Buttons Click Handlers ────────────────────────────────
            $('.btn-action-save').on('click', function () {
                let filledCount = 0;
                $('.test-item-row').each(function () {
                    const val = $(this).find('.txt-test-val').val()?.trim() || '';
                    if (val.length > 0) filledCount++;
                });

                if (filledCount === 0) {
                    toastr.warning('Please enter at least one test result value before submitting.');
                    return;
                }
                const missingP = missingProfileTests();
                if (missingP.length) { warnMissingProfileTests(missingP, 'submit'); return; }

                saveReporting(2, 'Report Entry');
            });

            $('.btn-action-validate').on('click', function () {
                let submittedRecords = 0;
                let totalActive = 0;
                $('.test-item-row').each(function () {
                    const $row = $(this);
                    const $inp = $row.find('.txt-test-val');
                    if ($inp.prop('disabled')) return;
                    totalActive++;
                    const repStatus = parseInt($row.attr('data-report-status-id')) || 0;
                    const val = $inp.val()?.trim() || '';
                    if (repStatus === 2 && val.length > 0) {
                        submittedRecords++;
                    }
                });

                if (submittedRecords === 0) {
                    toastr.warning('No submitted test records found to validate. Please enter and submit test results first.');
                    return;
                }
                const missingV = missingProfileTests();
                if (missingV.length) { warnMissingProfileTests(missingV, 'validate'); return; }

                const isPartial = submittedRecords < totalActive;
                const confirmTitle = isPartial ? 'Partially Validate Report?' : 'Validate Report?';
                const confirmText = isPartial 
                    ? `Are you sure you want to validate ${submittedRecords} submitted test(s)? Remaining tests can be entered and submitted later.`
                    : 'Are you sure you want to validate this report? Once validated, it will advance to final approval.';

                Swal.fire({
                    title: confirmTitle,
                    text: confirmText,
                    icon: 'question',
                    showCancelButton: true,
                    confirmButtonColor: '#198754',
                    cancelButtonColor: '#6c757d',
                    confirmButtonText: '<i class="bi bi-check-circle-fill me-1"></i>Yes, Validate ' + (isPartial ? `(${submittedRecords} Tests)` : 'Report')
                }).then((result) => {
                    if (result.isConfirmed) {
                        saveReporting(3, 'Report Validated');
                    }
                });
            });

            $('.btn-action-approve').on('click', function () {
                let validatedRecords = 0;
                let totalActive = 0;
                $('.test-item-row').each(function () {
                    const $row = $(this);
                    const $inp = $row.find('.txt-test-val');
                    if ($inp.prop('disabled')) return;
                    totalActive++;
                    const repStatus = parseInt($row.attr('data-report-status-id')) || 0;
                    const val = $inp.val()?.trim() || '';
                    if (repStatus === 3 && val.length > 0) {
                        validatedRecords++;
                    }
                });

                if (validatedRecords === 0) {
                    toastr.warning('No validated test records found to approve. Please validate test results first.');
                    return;
                }

                const isPartial = validatedRecords < totalActive;
                const confirmTitle = isPartial ? 'Partially Approve Report?' : 'Approve Report?';
                const confirmText = isPartial 
                    ? `Are you sure you want to approve ${validatedRecords} validated test(s)? This will finalize these ${validatedRecords} test result(s).`
                    : 'Are you sure you want to approve this lab report? This will finalize the report.';

                Swal.fire({
                    title: confirmTitle,
                    text: confirmText,
                    icon: 'question',
                    showCancelButton: true,
                    confirmButtonColor: '#0dcaf0',
                    cancelButtonColor: '#6c757d',
                    confirmButtonText: '<i class="bi bi-patch-check-fill me-1"></i>Yes, Approve ' + (isPartial ? `(${validatedRecords} Tests)` : 'Report')
                }).then((result) => {
                    if (result.isConfirmed) {
                        // NABL: a Critical / Panic result needs its communication recorded before approval (SQLScripts/2202)
                        const approveIds = approvalSampleIds();
                        if (window.CriticalComm && approveIds.length) {
                            CriticalComm.ensure({ labOrderId: labOrderId, sampleIds: approveIds, context: 'ENTRY' })
                                .then(function (ok) { if (ok) saveReporting(5, 'Report Approve'); });
                        } else {
                            saveReporting(5, 'Report Approve');
                        }
                    }
                });
            });

            // the rows an approval would send (same filter as saveReporting(5)): validated, with a value, editable
            function approvalSampleIds() {
                return $('.test-item-row').filter(function () {
                    const $row = $(this);
                    return !$row.find('.txt-test-val').prop('disabled')
                        && (parseInt($row.attr('data-report-status-id')) || 0) === 3
                        && ($row.find('.txt-test-val').val()?.trim() || '').length > 0;
                }).map(function () { return parseInt($(this).data('samplecollection-id')); }).get();
            }

            function saveReporting(statusId, statusLabel) {
                const entries = [];
                const targetRowIds = [];

                $('.test-item-row').each(function () {
                    const $row = $(this);
                    const $valInp = $row.find('.txt-test-val');
                    if ($valInp.prop('disabled')) {
                        return; // Skip disabled / rejected / re-collected tests
                    }

                    const samplecollectionID = $row.data('samplecollection-id');
                    const investigationID = $row.data('investigation-id');
                    const reportingType = $row.data('reporting-type') || 'Numeric';
                    const testValue = $valInp.val()?.trim() || '';
                    const remarks = $row.find('.txt-test-remarks').val()?.trim() || '';
                    const abnormalFlag = $row.attr('data-current-flag') || null;
                    const reportStatusId = parseInt($row.attr('data-report-status-id')) || 0;

                    // FILTER BASED ON ACTION:
                    if (statusId === 3) {
                        // VALIDATE: Only include records in Submitted status (ReportStatusId == 2) with a value
                        if (reportStatusId !== 2 || testValue.length === 0) {
                            return;
                        }
                    } else if (statusId === 5) {
                        // APPROVE: Only include records in Validated status (ReportStatusId == 3) with a value
                        if (reportStatusId !== 3 || testValue.length === 0) {
                            return;
                        }
                    } else if (statusId === 2) {
                        // SUBMIT: include any entered test with a value that is NOT yet approved
                        if (testValue.length === 0 || reportStatusId === 5) {
                            return;
                        }
                    }

                    entries.push({
                        samplecollectionID: samplecollectionID,
                        investigationID: investigationID,
                        reportingType: reportingType,
                        testValue: testValue,
                        // narrative rows (Microbiology Report Entry) also send their formatted text; null elsewhere
                        templateHtml: (window.labEntryHooks && window.labEntryHooks.templateHtml) ? window.labEntryHooks.templateHtml($row) : null,
                        remarks: remarks,
                        abnormalFlag: abnormalFlag
                    });
                    targetRowIds.push(samplecollectionID);
                });

                const groupRemarks = [];
                $('.txt-group-lab-remarks').each(function () {
                    const groupKey = $(this).data('group-key') || '';
                    const headerName = $(this).data('header-name') || '';
                    const profileId = parseInt($(this).data('profile-id')) || 0;
                    const investigationId = parseInt($(this).data('investigation-id')) || 0;
                    const labRemarks = $(this).val() || '';

                    if (groupKey) {
                        groupRemarks.push({
                            groupKey: groupKey,
                            headerName: headerName,
                            profileId: profileId > 0 ? profileId : null,
                            investigationId: investigationId > 0 ? investigationId : null,
                            labRemarks: labRemarks.trim()
                        });
                    }
                });

                // Safety net: a row without a configured Reference Range can never be submitted
                // (its input is disabled so it is skipped above; this also catches a re-enabled input).
                const blockedNames = [];
                for (let i = entries.length - 1; i >= 0; i--) {
                    const $r = $('.test-item-row[data-samplecollection-id="' + entries[i].samplecollectionID + '"]');
                    if (String($r.find('.txt-test-val').attr('data-no-ref-range')) === 'true') {
                        blockedNames.push($.trim($r.find('td:nth-child(2) .fw-bold').first().text()));
                        entries.splice(i, 1);
                        targetRowIds.splice(i, 1);
                    }
                }
                if (blockedNames.length) {
                    toastr.error('Need to configure Reference Range first for: ' + blockedNames.join(', '));
                    if (entries.length === 0) return;
                }

                if (entries.length === 0) {
                    if (statusId === 3) {
                        toastr.warning('No submitted test entries found to validate.');
                    } else if (statusId === 5) {
                        toastr.warning('No validated test entries found to approve.');
                    } else {
                        toastr.warning('Please enter at least one test result value before submitting.');
                    }
                    return;
                }

                // SQLScripts/2514: the Lab Serial No (typed by the user) is required while the branch setting is Yes
                const serialBox = document.getElementById('txtLabSerialNo');
                if (serialBox && !serialBox.value.trim()) {
                    serialBox.classList.add('is-invalid'); serialBox.focus();
                    if (window.Swal) Swal.fire({ icon: 'warning', title: 'Lab Serial No required', text: 'Enter the Lab Serial No before saving.' });
                    return;
                }
                if (serialBox) serialBox.classList.remove('is-invalid');

                const payload = {
                    labOrderId: labOrderId,
                    reportStatusId: statusId,
                    entries: entries,
                    groupRemarks: groupRemarks,
                    labSerialNo: serialBox ? serialBox.value.trim() : null
                };

                const $btns = $('.btn-action-save, .btn-action-validate, .btn-action-approve');
                $btns.prop('disabled', true);

                $.ajax({
                    url: window.labEntryCfg.saveUrl,
                    type: 'POST',
                    contentType: 'application/json',
                    data: JSON.stringify(payload)
                })
                .done(function (res) {
                    $btns.prop('disabled', false);
                    if (res.success) {
                        toastr.success(res.message || `Test entries saved as ${statusLabel}!`);
                        if (window.labSerialLock) window.labSerialLock(statusId === 5);

                        const now = new Date();
                        const timeStr = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
                        const dateStr = now.toLocaleDateString([], { day: '2-digit', month: 'short', year: 'numeric' });
                        const fullDateTimeStr = `${dateStr}, ${timeStr}`;

                        if (statusId === 2) {
                            // Submitted / Entered
                            $('.test-item-row').each(function () {
                                const $row = $(this);
                                const sampleId = $row.data('samplecollection-id');
                                if (!targetRowIds.includes(sampleId)) return;

                                const $inp = $row.find('.txt-test-val');
                                const valStr = $inp.val()?.trim() || '';
                                const $editBtn = $row.find('.btn-edit-row');
                                const curRemarks = $row.find('.txt-test-remarks').val()?.trim() || '';

                                $inp.prop('readonly', true).addClass('is-locked bg-light text-dark').removeClass('border-primary shadow-sm');
                                $editBtn.removeClass('d-none btn-primary text-white').addClass('btn-outline-secondary');
                                $editBtn.find('i').removeClass('text-white bi-pencil-fill').addClass('text-primary bi-pencil-square');
                                $row.find('.row-status-badge').attr('class', 'badge fs-9 row-status-badge status-entered').attr('data-time-submitted', fullDateTimeStr).text('Entered');
                                
                                $row.attr('data-report-status-id', '2');
                                $row.attr('data-initial-val', valStr);
                                $row.attr('data-initial-remarks', curRemarks);
                            });

                            $('.txt-group-lab-remarks').each(function () {
                                $(this).attr('data-initial-val', $(this).val()?.trim() || '');
                            });

                            isPageDirty = false;

                            if ($('#pillSubmitted').length) {
                                $('#pillSubmittedVal').text(fullDateTimeStr);
                            } else {
                                $('#rowBannerStatusTimeline').append(`
                                    <div class="info-pill" id="pillSubmitted">
                                        <span class="pill-label text-primary"><i class="bi bi-send-check text-primary me-0.5"></i>Submitted Date</span>
                                        <span class="pill-val text-primary font-monospace" id="pillSubmittedVal">${fullDateTimeStr}</span>
                                    </div>
                                `);
                            }
                        } else if (statusId === 3) {
                            // Validated: ONLY update the rows that were validated!
                            $('.test-item-row').each(function () {
                                const $row = $(this);
                                const sampleId = $row.data('samplecollection-id');
                                if (!targetRowIds.includes(sampleId)) return;

                                const $inp = $row.find('.txt-test-val');
                                const valStr = $inp.val()?.trim() || '';
                                const $editBtn = $row.find('.btn-edit-row');
                                const curRemarks = $row.find('.txt-test-remarks').val()?.trim() || '';

                                $inp.prop('readonly', true).addClass('is-locked bg-light text-dark').removeClass('border-primary shadow-sm');
                                $editBtn.removeClass('d-none btn-primary text-white').addClass('btn-outline-secondary');
                                $editBtn.find('i').removeClass('text-white bi-pencil-fill').addClass('text-primary bi-pencil-square');
                                $row.find('.row-status-badge').attr('class', 'badge fs-9 row-status-badge bg-success-subtle text-success border border-success-subtle').attr('data-time-validated', fullDateTimeStr).text('Validated');
                                
                                $row.attr('data-report-status-id', '3');
                                $row.attr('data-initial-val', valStr);
                                $row.attr('data-initial-remarks', curRemarks);
                            });

                            $('.txt-group-lab-remarks').each(function () {
                                $(this).attr('data-initial-val', $(this).val()?.trim() || '');
                            });

                            isPageDirty = false;

                            if ($('#pillValidated').length) {
                                $('#pillValidatedVal').text(fullDateTimeStr);
                            } else {
                                $('#rowBannerStatusTimeline').append(`
                                    <div class="info-pill" id="pillValidated">
                                        <span class="pill-label text-success"><i class="bi bi-check2-circle text-success me-0.5"></i>Validated Date</span>
                                        <span class="pill-val text-success font-monospace" id="pillValidatedVal">${fullDateTimeStr}</span>
                                    </div>
                                `);
                            }
                        } else if (statusId === 5) {
                            // Approved: ONLY update the rows that were approved!
                            $('.test-item-row').each(function () {
                                const $row = $(this);
                                const sampleId = $row.data('samplecollection-id');
                                if (!targetRowIds.includes(sampleId)) return;

                                const $inp = $row.find('.txt-test-val');
                                const valStr = $inp.val()?.trim() || '';
                                const $remarks = $row.find('.txt-test-remarks');
                                const $editBtn = $row.find('.btn-edit-row');

                                $inp.prop('readonly', true).addClass('is-locked bg-light text-dark').removeClass('border-primary shadow-sm');
                                $remarks.prop('readonly', true).addClass('bg-light-subtle text-muted');
                                $editBtn.addClass('d-none');
                                $row.find('.row-status-badge').attr('class', 'badge fs-9 row-status-badge bg-info-subtle text-info border border-info-subtle').attr('data-time-approved', fullDateTimeStr).text('Approved');
                                
                                $row.attr('data-report-status-id', '5');
                                $row.attr('data-initial-val', valStr);
                            });

                            isPageDirty = false;

                            if ($('#pillApproved').length) {
                                $('#pillApprovedVal').text(fullDateTimeStr);
                            } else {
                                $('#rowBannerStatusTimeline').append(`
                                    <div class="info-pill" id="pillApproved">
                                        <span class="pill-label text-info"><i class="bi bi-patch-check-fill text-info me-0.5"></i>Approved Date</span>
                                        <span class="pill-val text-info font-monospace" id="pillApprovedVal">${fullDateTimeStr}</span>
                                    </div>
                                `);
                            }
                        }

                        if (window.labEntryHooks && window.labEntryHooks.onSaved) {
                            targetRowIds.forEach(function (id) { window.labEntryHooks.onSaved(id, statusId); });
                        }
                        updateActionButtonsVisibility();
                    } else {
                        toastr.error(res.message || 'Failed to save entries.');
                    }
                })
                .fail(function () {
                    $btns.prop('disabled', false);
                    toastr.error('Server error while saving entries.');
                });
            }

            // ── Sample Status Dropdown & Rejection/Re-Collect Handler ────────
            function escapeHtml(text) {
                if (!text) return '';
                return $('<div>').text(text).html();
            }

            let activeStatusChange = null;

            $(document).on('change', '.sample-status-select', function () {
                const $select = $(this);
                const newStatusId = parseInt($select.val());
                const oldStatusId = parseInt($select.attr('data-current-status')) || 2;
                const grpId = $select.data('grpid');
                const targetName = $select.data('target-name') || 'Selected Test / Profile';
                const profileId = $select.data('profile-id') ? parseInt($select.data('profile-id')) : null;
                const investigationId = $select.data('investigation-id') ? parseInt($select.data('investigation-id')) : null;
                const sampleId = $select.data('sample-id') ? parseInt($select.data('sample-id')) : null;

                if (newStatusId === 3 || newStatusId === 4) {
                    activeStatusChange = {
                        $select: $select,
                        newStatusId: newStatusId,
                        oldStatusId: oldStatusId,
                        grpId: grpId,
                        targetName: targetName,
                        profileId: profileId,
                        investigationId: investigationId,
                        sampleId: sampleId,
                        confirmed: false
                    };

                    const isReCollect = (newStatusId === 3);
                    $('#modalRejectionTitle').html(isReCollect
                        ? '<i class="bi bi-arrow-repeat text-warning me-1.5"></i>Sample Re-Collection Request'
                        : '<i class="bi bi-x-circle text-danger me-1.5"></i>Sample Rejection Confirmation');
                    $('#modalRejectionTargetName').text(targetName);
                    $('#modalRejectionReasonSelect').val('').removeClass('is-invalid');
                    $('#modalCustomReasonContainer').hide();
                    $('#modalCustomReasonText').val('').removeClass('is-invalid');

                    const modal = new bootstrap.Modal(document.getElementById('modalSampleRejectionReason'));
                    modal.show();
                } else if (newStatusId === 2) {
                    Swal.fire({
                        title: 'Mark Sample as Collected?',
                        text: `Revert sample status for "${targetName}" back to Collected? This will re-enable test entry for this group.`,
                        icon: 'question',
                        showCancelButton: true,
                        confirmButtonColor: '#198754',
                        cancelButtonColor: '#6c757d',
                        confirmButtonText: '<i class="bi bi-check2-circle me-1"></i>Yes, Mark Collected',
                        cancelButtonText: 'Cancel'
                    }).then((result) => {
                        if (result.isConfirmed) {
                            const payload = {
                                labOrderId: labOrderId,
                                profileId: profileId,
                                investigationId: investigationId,
                                sampleCollectionId: sampleId,
                                collectionStatusId: 2,
                                rejectionReasonId: null,
                                rejectionReason: null
                            };

                            $.ajax({
                                url: window.labEntryCfg.sampleStatusUrl,
                                type: 'POST',
                                contentType: 'application/json',
                                data: JSON.stringify(payload)
                            })
                            .done(function (res) {
                                if (res.success) {
                                    applySampleStatusChangeToDom($select, grpId, 2, '');
                                    toastr.success(res.message || 'Sample marked as Collected.');
                                } else {
                                    $select.val(oldStatusId);
                                    toastr.error(res.message || 'Failed to update sample status.');
                                }
                            })
                            .fail(function () {
                                $select.val(oldStatusId);
                                toastr.error('Server error while updating sample status.');
                            });
                        } else {
                            $select.val(oldStatusId);
                        }
                    });
                }
            });

            $('#modalSampleRejectionReason').on('hidden.bs.modal', function () {
                if (activeStatusChange && !activeStatusChange.confirmed) {
                    activeStatusChange.$select.val(activeStatusChange.oldStatusId);
                }
                activeStatusChange = null;
            });

            $('#modalRejectionReasonSelect').on('change', function () {
                $(this).removeClass('is-invalid');
                if ($(this).val() === '0') {
                    $('#modalCustomReasonContainer').slideDown(150);
                    $('#modalCustomReasonText').focus();
                } else {
                    $('#modalCustomReasonContainer').slideUp(150);
                }
            });

            $('#btnConfirmSampleStatusChange').on('click', function () {
                if (!activeStatusChange) return;

                const reasonSelectVal = $('#modalRejectionReasonSelect').val();
                if (!reasonSelectVal) {
                    $('#modalRejectionReasonSelect').addClass('is-invalid');
                    return;
                }

                let reasonId = null;
                let reasonText = '';

                if (reasonSelectVal === '0') {
                    const customText = $('#modalCustomReasonText').val()?.trim() || '';
                    if (!customText) {
                        $('#modalCustomReasonText').addClass('is-invalid').focus();
                        return;
                    }
                    reasonText = customText;
                } else {
                    reasonId = parseInt(reasonSelectVal);
                    const selectedOption = $('#modalRejectionReasonSelect option:selected');
                    reasonText = selectedOption.data('name') || selectedOption.text().trim();
                    const customText = $('#modalCustomReasonText').val()?.trim() || '';
                    if (customText) {
                        reasonText += ` - ${customText}`;
                    }
                }

                const $btn = $(this);
                $btn.prop('disabled', true);
                $('#spnConfirmSampleStatus').removeClass('d-none');
                $('#iconConfirmSampleStatus').addClass('d-none');

                const payload = {
                    labOrderId: labOrderId,
                    profileId: activeStatusChange.profileId,
                    investigationId: activeStatusChange.investigationId,
                    sampleCollectionId: activeStatusChange.sampleId,
                    collectionStatusId: activeStatusChange.newStatusId,
                    rejectionReasonId: reasonId,
                    rejectionReason: reasonText
                };

                $.ajax({
                    url: window.labEntryCfg.sampleStatusUrl,
                    type: 'POST',
                    contentType: 'application/json',
                    data: JSON.stringify(payload)
                })
                .done(function (res) {
                    $btn.prop('disabled', false);
                    $('#spnConfirmSampleStatus').addClass('d-none');
                    $('#iconConfirmSampleStatus').removeClass('d-none');

                    if (res.success) {
                        activeStatusChange.confirmed = true;
                        const modalEl = document.getElementById('modalSampleRejectionReason');
                        const modal = bootstrap.Modal.getInstance(modalEl);
                        if (modal) modal.hide();

                        const newStatus = activeStatusChange.newStatusId;
                        const $sel = activeStatusChange.$select;
                        const grpId = activeStatusChange.grpId;

                        applySampleStatusChangeToDom($sel, grpId, newStatus, reasonText);
                        toastr.success(res.message || 'Sample status updated.');
                    } else {
                        toastr.error(res.message || 'Failed to update sample status.');
                    }
                })
                .fail(function () {
                    $btn.prop('disabled', false);
                    $('#spnConfirmSampleStatus').addClass('d-none');
                    $('#iconConfirmSampleStatus').removeClass('d-none');
                    toastr.error('Server error occurred while updating sample status.');
                });
            });

            function applySampleStatusChangeToDom($select, grpId, newStatus, reasonText) {
                $select.attr('data-current-status', newStatus);
                $select.removeClass('select-sample-status-2 select-sample-status-3 select-sample-status-4')
                       .addClass(`select-sample-status-${newStatus}`);

                const $wrapper = $select.closest('.sample-status-wrapper');
                $wrapper.find('.sample-rejection-reason-badge').remove();

                const isRejOrReCollect = (newStatus === 3 || newStatus === 4);

                if (isRejOrReCollect && reasonText) {
                    $wrapper.append(`
                        <span class="badge bg-danger-subtle text-danger border border-danger-subtle fs-9 sample-rejection-reason-badge" title="Reason: ${escapeHtml(reasonText)}">
                            <i class="bi bi-exclamation-circle me-1"></i>${escapeHtml(reasonText)}
                        </span>
                    `);
                }

                // Apply to all child rows of this group
                $(`.group-child-${grpId}.test-item-row`).each(function () {
                    const $row = $(this);
                    const $valInp = $row.find('.txt-test-val');
                    const $remInp = $row.find('.txt-test-remarks');
                    const $editBtn = $row.find('.btn-edit-row');
                    const $statusBadge = $row.find('.row-status-badge');
                    const $flagBadge = $row.find('.flag-badge');

                    if (isRejOrReCollect) {
                        $row.find('.no-ref-range-msg').remove();
                        $valInp.val('').prop('disabled', true).removeClass('has-value is-flagged-l is-flagged-h border-primary shadow-sm no-ref-range').attr('placeholder', 'Pending');
                        $remInp.val('').prop('disabled', true).attr('placeholder', newStatus === 3 ? 'Re-Collect pending' : 'Sample Rejected');
                        $editBtn.addClass('d-none');
                        $flagBadge.attr('class', 'badge flag-badge flag-none fs-8 px-2 py-1').text('—');
                        $row.removeAttr('data-current-flag');

                        const statusClass = newStatus === 3 ? 'bg-warning-subtle text-warning-emphasis border border-warning-subtle' : 'bg-danger-subtle text-danger border border-danger-subtle';
                        const statusLabel = newStatus === 3 ? 'Pending (Re-Collect)' : 'Pending (Rejected)';
                        $statusBadge.removeAttr('data-time-drafted data-time-submitted data-time-validated data-time-approved')
                                    .attr('class', `badge fs-9 row-status-badge ${statusClass}`).text(statusLabel);

                        $row.find('.row-rejection-info').remove();
                        $row.find('td:nth-child(2)').append(`
                            <div class="fs-9 mt-0.5 d-flex align-items-center gap-1 row-rejection-info">
                                <span class="badge ${newStatus === 3 ? 'bg-warning-subtle text-warning-emphasis border border-warning-subtle' : 'bg-danger-subtle text-danger border border-danger-subtle'} fs-9">
                                    <i class="bi ${newStatus === 3 ? 'bi-arrow-repeat' : 'bi-x-circle'} me-1"></i>${newStatus === 3 ? 'Re-Collect Pending' : 'Sample Rejected'}
                                </span>
                                ${reasonText ? `<span class="text-danger fs-9 text-truncate" style="max-width: 200px;" title="Reason: ${escapeHtml(reasonText)}">(${escapeHtml(reasonText)})</span>` : ''}
                            </div>
                        `);
                    } else {
                        // Re-enabled back to Collected (2) - unless no Reference Range is configured for this test
                        const noRefRange = String($valInp.attr('data-no-ref-range')) === 'true';
                        $valInp.prop('disabled', noRefRange).toggleClass('no-ref-range', noRefRange).attr('placeholder', noRefRange ? 'N/A' : 'Value');
                        if (noRefRange && !$row.find('.no-ref-range-msg').length) {
                            $valInp.closest('td').append('<div class="no-ref-range-msg fs-9 mt-1" role="alert"><i class="bi bi-exclamation-triangle-fill me-1"></i>Need to configure Reference Range first</div>');
                        }
                        $remInp.prop('disabled', false).attr('placeholder', 'Optional note');
                        $row.find('.row-rejection-info').remove();
                        $statusBadge.attr('class', 'badge fs-9 row-status-badge bg-secondary-subtle text-secondary border border-secondary-subtle').text('Pending entry');
                    }
                });

                // Lab remarks row
                const $remRow = $(`#remarks_${grpId}`);
                if ($remRow.length) {
                    $remRow.find('.txt-group-lab-remarks').prop('disabled', isRejOrReCollect);
                }

                updateFilledCount();
                updateActionButtonsVisibility();
            }

            // Keyboard navigation: Enter moves to next editable value input
            $(document).on('keydown', '.txt-test-val', function (e) {
                if (e.key === 'Enter') {
                    e.preventDefault();
                    const $editableInputs = $('.txt-test-val:visible:not([readonly]):not(:disabled)');
                    const idx = $editableInputs.index(this);
                    if (idx >= 0 && idx < $editableInputs.length - 1) {
                        $editableInputs.eq(idx + 1).focus().select();
                    } else {
                        if ($('#btnStickySave:visible').length) {
                            $('#btnStickySave').focus();
                        } else if ($('#btnStickyValidate:visible').length) {
                            $('#btnStickyValidate').focus();
                        } else if ($('#btnStickyApprove:visible').length) {
                            $('#btnStickyApprove').focus();
                        }
                    }
                }
            });

            // Initial button and badge sync on page load
            updateActionButtonsVisibility();
        });
