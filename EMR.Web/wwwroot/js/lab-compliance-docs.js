// Prescription / OVD Document / Consent upload gate for LAB B2C & B2B booking.
// One controller instance per booking page (B2CBooking.cshtml / B2BBooking.cshtml).
// Requires jQuery, Bootstrap 5 (bundle) and SweetAlert2 to already be loaded on the page.
(function (window, $) {
    'use strict';

    var CONDITIONS = ['prescription', 'ovd', 'consent'];

    var LABELS = {
        prescription: 'Prescription',
        ovd: 'OVD Document',
        consent: 'Consent'
    };

    var ALERT_TEXT = {
        prescription: 'Upload a Prescription',
        ovd: 'Upload OVD Document First',
        consent: 'Fill up consent and Upload'
    };

    var FIELD_NAMES = {
        prescription: { file: 'prescriptionFile', remarks: 'prescriptionRemarks' },
        ovd: { file: 'ovdDocumentFile', remarks: 'ovdDocumentRemarks' },
        consent: { file: 'consentFile', remarks: 'consentRemarks' }
    };

    function create(options) {
        var cfg = $.extend({
            flagsUrl: '/LabOrderBooking/GetInvestigationDocFlags',
            formSelector: '#labForm',
            saveButtonSelector: '#btnSaveSubmit',
            iconSelector: '#btnComplianceUpload',
            modalId: 'labComplianceModal',
            getLineItems: function () { return []; }
        }, options || {});

        var state = {
            required: { prescription: false, ovd: false, consent: false },
            files: { prescription: null, ovd: null, consent: null },
            remarks: { prescription: '', ovd: '', consent: '' },
            bypass: { prescription: false, ovd: false, consent: false }
        };
        var requestSeq = 0;
        var $modal = null;

        function splitPlainAndGroup() {
            var plain = [], group = [];
            (cfg.getLineItems() || []).forEach(function (it) {
                var id = it && it.investigationId;
                if (!id) return;
                if (it.isPackage || it.isProfileTest || it.isProfile) group.push(id);
                else plain.push(id);
            });
            return {
                plainIds: Array.from(new Set(plain)).join(','),
                groupIds: Array.from(new Set(group)).join(',')
            };
        }

        function isSatisfied(key) {
            return !!(state.files[key] || (state.remarks[key] && state.remarks[key].trim().length > 0));
        }

        function isCompliant() {
            return CONDITIONS.every(function (key) {
                return !state.required[key] || isSatisfied(key);
            });
        }

        function updateSaveButtonState() {
            $(cfg.saveButtonSelector).prop('disabled', !isCompliant());
        }

        function updateIconState() {
            var anyRequired = CONDITIONS.some(function (key) { return state.required[key]; });
            $(cfg.iconSelector).prop('disabled', !anyRequired)
                .toggleClass('disabled', !anyRequired)
                .attr('title', anyRequired
                    ? 'Upload required compliance documents for this bill'
                    : 'No compliance documents are required for the tests currently added');
        }

        function fileLabel(key) {
            var f = state.files[key];
            if (!f) return '';
            return f.name + ' (' + Math.max(1, Math.round(f.size / 1024)) + ' KB)';
        }

        function sectionHtml(key) {
            var label = LABELS[key];
            var names = FIELD_NAMES[key];
            var required = state.required[key];
            var bypass = state.bypass[key];
            var fileChosen = !!state.files[key];
            var previewBtn = fileChosen
                ? '<button type="button" class="btn btn-sm btn-outline-secondary lcd-preview" data-key="' + key + '"><i class="bi bi-eye me-1"></i>Preview</button>'
                : '';

            return (
                '<div class="lcd-section border rounded-3 p-3 mb-3' + (required ? '' : ' d-none') + '" data-key="' + key + '">' +
                    '<div class="d-flex justify-content-between align-items-center mb-2">' +
                        '<span class="fw-bold text-dark"><i class="bi bi-file-earmark-medical text-primary me-1"></i>' + label + '</span>' +
                        '<div class="form-check form-switch m-0">' +
                            '<input class="form-check-input lcd-bypass" type="checkbox" data-key="' + key + '" id="lcdBypass_' + key + '" ' + (bypass ? 'checked' : '') + '>' +
                            '<label class="form-check-label small text-muted" for="lcdBypass_' + key + '">Not available &mdash; add remark instead</label>' +
                        '</div>' +
                    '</div>' +
                    '<div class="lcd-file-row ' + (bypass ? 'd-none' : '') + '">' +
                        '<input type="file" class="form-control form-control-sm lcd-file" data-key="' + key + '" name="' + names.file + '" accept=".pdf,.jpg,.jpeg,.png" ' + (bypass ? 'disabled' : '') + '>' +
                        '<div class="small mt-1 d-flex align-items-center gap-2">' +
                            '<span class="text-success lcd-file-label">' + (fileChosen ? '<i class="bi bi-check-circle-fill me-1"></i>' + fileLabel(key) : '') + '</span>' +
                            previewBtn +
                        '</div>' +
                    '</div>' +
                    '<div class="lcd-remark-row ' + (bypass ? '' : 'd-none') + '">' +
                        '<textarea class="form-control form-control-sm lcd-remark" data-key="' + key + '" name="' + names.remarks + '" rows="2" placeholder="Reason ' + label + ' is not available..." ' + (bypass ? '' : 'disabled') + '>' + (state.remarks[key] || '') + '</textarea>' +
                    '</div>' +
                '</div>'
            );
        }

        function renderModalBody() {
            if (!$modal) return;
            var anyRequired = CONDITIONS.some(function (key) { return state.required[key]; });
            var body = anyRequired
                ? CONDITIONS.map(sectionHtml).join('')
                : '<div class="text-center text-muted py-3"><i class="bi bi-info-circle me-1"></i>No compliance documents are required for the tests currently on this bill.</div>';
            $modal.find('.lcd-modal-body').html(body);

            // Rebuilding the HTML replaces the <input type="file"> nodes, which would silently
            // drop the already-chosen File at actual form-submit time even though it is still
            // held in state - reattach it to the fresh input via DataTransfer so it stays real.
            CONDITIONS.forEach(function (key) {
                var file = state.files[key];
                if (!file || state.bypass[key]) return;
                var input = $modal.find('.lcd-file[data-key="' + key + '"]')[0];
                if (!input) return;
                var dt = new DataTransfer();
                dt.items.add(file);
                input.files = dt.files;
            });
        }

        function buildModalSkeleton() {
            if (document.getElementById(cfg.modalId)) {
                $modal = $('#' + cfg.modalId);
                return;
            }
            var html =
                '<div class="modal fade" id="' + cfg.modalId + '" tabindex="-1" aria-hidden="true">' +
                    '<div class="modal-dialog modal-dialog-centered">' +
                        '<div class="modal-content">' +
                            '<div class="modal-header">' +
                                '<h6 class="modal-title fw-bold"><i class="bi bi-file-earmark-arrow-up text-primary me-2"></i>Compliance Documents for this Bill</h6>' +
                                '<button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>' +
                            '</div>' +
                            '<div class="modal-body lcd-modal-body"></div>' +
                            '<div class="modal-footer">' +
                                '<button type="button" class="btn btn-primary btn-sm" data-bs-dismiss="modal"><i class="bi bi-check2 me-1"></i>Done</button>' +
                            '</div>' +
                        '</div>' +
                    '</div>' +
                '</div>';
            $(cfg.formSelector).append(html);
            $modal = $('#' + cfg.modalId);
        }

        function wireEvents() {
            $(document).on('click', cfg.iconSelector, function (e) {
                e.preventDefault();
                if ($(this).prop('disabled')) return;
                renderModalBody();
                var bsModal = bootstrap.Modal.getOrCreateInstance(document.getElementById(cfg.modalId));
                bsModal.show();
            });

            $(document).on('change', '#' + cfg.modalId + ' .lcd-file', function () {
                var key = $(this).data('key');
                var file = this.files && this.files[0] ? this.files[0] : null;
                state.files[key] = file;
                renderModalBody();
                updateSaveButtonState();
            });

            $(document).on('input change', '#' + cfg.modalId + ' .lcd-remark', function () {
                var key = $(this).data('key');
                state.remarks[key] = $(this).val();
                updateSaveButtonState();
            });

            $(document).on('change', '#' + cfg.modalId + ' .lcd-bypass', function () {
                var key = $(this).data('key');
                state.bypass[key] = $(this).is(':checked');
                if (state.bypass[key]) {
                    state.files[key] = null; // bypassed - a previously chosen file no longer applies
                }
                renderModalBody();
                updateSaveButtonState();
            });

            $(document).on('click', '#' + cfg.modalId + ' .lcd-preview', function () {
                var key = $(this).data('key');
                var file = state.files[key];
                if (!file) return;
                var url = URL.createObjectURL(file);
                window.open(url, '_blank');
            });
        }

        function fireAlertsForNewlyRequired(prevRequired) {
            var toShow = CONDITIONS.filter(function (key) {
                return state.required[key] && !prevRequired[key];
            });
            if (!toShow.length || typeof Swal === 'undefined') return;

            var chain = Promise.resolve();
            toShow.forEach(function (key) {
                chain = chain.then(function () {
                    return Swal.fire({
                        icon: 'warning',
                        title: 'Document Required',
                        text: ALERT_TEXT[key],
                        confirmButtonText: 'OK',
                        confirmButtonColor: '#0d6efd'
                    });
                });
            });
        }

        function refreshRequiredFromGrid() {
            var ids = splitPlainAndGroup();
            var mySeq = ++requestSeq;

            if (!ids.plainIds && !ids.groupIds) {
                var prevEmpty = $.extend({}, state.required);
                state.required = { prescription: false, ovd: false, consent: false };
                updateIconState();
                updateSaveButtonState();
                renderModalBody();
                return;
            }

            $.get(cfg.flagsUrl, { plainIds: ids.plainIds, groupIds: ids.groupIds })
                .done(function (res) {
                    if (mySeq !== requestSeq) return; // a newer grid change has already superseded this call
                    if (!res || !res.success) return;

                    var prevRequired = $.extend({}, state.required);
                    var req = { prescription: false, ovd: false, consent: false };
                    (res.rows || []).forEach(function (r) {
                        if (r.prescriptionRequired) req.prescription = true;
                        if (r.ovdRequired) req.ovd = true;
                        if (r.consentRequired) req.consent = true;
                    });
                    state.required = req;

                    updateIconState();
                    updateSaveButtonState();
                    renderModalBody();
                    fireAlertsForNewlyRequired(prevRequired);
                });
        }

        function init() {
            buildModalSkeleton();
            wireEvents();
            updateIconState();
            updateSaveButtonState();
        }

        return {
            init: init,
            onLineItemsChanged: refreshRequiredFromGrid,
            isCompliant: isCompliant
        };
    }

    window.LabComplianceDocs = { create: create };
})(window, jQuery);
