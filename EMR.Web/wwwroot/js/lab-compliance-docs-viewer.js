// Read-only "View Uploaded Documents" popup for the B2C Order List and B2B Registration list.
// Any page that includes this file gets a working popup for free: just add a button with
// class="btn-view-compliance-docs" and data-laborderid="<id>" to the row's action menu.
// Requires jQuery, Bootstrap 5 (bundle) and SweetAlert2 to already be loaded on the page.
(function (window, $) {
    'use strict';

    var MODAL_ID = 'labComplianceViewerModal';
    var DATA_URL = '/LabOrderBooking/GetOrderComplianceDocuments';

    var LABELS = {
        prescription: 'Prescription',
        ovd: 'OVD Document',
        consent: 'Consent'
    };

    function isImage(path) {
        return /\.(jpe?g|png)$/i.test(path || '');
    }

    function slotHtml(key, filePath, remarks) {
        var label = LABELS[key];
        var body;
        if (filePath) {
            var thumb = isImage(filePath)
                ? '<img src="' + filePath + '" class="border rounded" style="max-height:60px;max-width:60px;object-fit:cover;">'
                : '<i class="bi bi-file-earmark-pdf text-danger fs-3"></i>';
            body =
                '<div class="d-flex align-items-center gap-2">' +
                    thumb +
                    '<a href="' + filePath + '" target="_blank" class="btn btn-sm btn-outline-primary"><i class="bi bi-eye me-1"></i>Preview</a>' +
                '</div>';
        } else if (remarks) {
            body = '<div class="small text-muted fst-italic"><i class="bi bi-chat-left-text me-1"></i>Bypassed: ' + $('<div>').text(remarks).html() + '</div>';
        } else {
            body = '<span class="text-muted small">Not applicable</span>';
        }

        return (
            '<div class="d-flex justify-content-between align-items-start border rounded-3 p-2 mb-2">' +
                '<span class="fw-semibold text-dark"><i class="bi bi-file-earmark-medical text-primary me-1"></i>' + label + '</span>' +
                '<div>' + body + '</div>' +
            '</div>'
        );
    }

    function buildModal() {
        if (document.getElementById(MODAL_ID)) return $('#' + MODAL_ID);
        var html =
            '<div class="modal fade" id="' + MODAL_ID + '" tabindex="-1" aria-hidden="true">' +
                '<div class="modal-dialog modal-dialog-centered">' +
                    '<div class="modal-content">' +
                        '<div class="modal-header">' +
                            '<h6 class="modal-title fw-bold"><i class="bi bi-file-earmark-arrow-up text-primary me-2"></i>Uploaded Compliance Documents</h6>' +
                            '<button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>' +
                        '</div>' +
                        '<div class="modal-body lcdv-body">' +
                            '<div class="text-center py-3"><span class="spinner-border spinner-border-sm"></span> Loading...</div>' +
                        '</div>' +
                        '<div class="modal-footer">' +
                            '<button type="button" class="btn btn-secondary btn-sm" data-bs-dismiss="modal">Close</button>' +
                        '</div>' +
                    '</div>' +
                '</div>' +
            '</div>';
        $(document.body).append(html);
        return $('#' + MODAL_ID);
    }

    function open(labOrderId) {
        var $modal = buildModal();
        $modal.find('.lcdv-body').html('<div class="text-center py-3"><span class="spinner-border spinner-border-sm"></span> Loading...</div>');
        var bsModal = bootstrap.Modal.getOrCreateInstance($modal[0]);
        bsModal.show();

        $.get(DATA_URL, { labOrderId: labOrderId })
            .done(function (res) {
                if (!res || !res.success) {
                    $modal.find('.lcdv-body').html('<div class="text-danger small">' + (res && res.message ? res.message : 'Unable to load documents for this bill.') + '</div>');
                    return;
                }
                var anyRequired = res.prescriptionFilePath || res.prescriptionRemarks
                    || res.ovdDocumentFilePath || res.ovdDocumentRemarks
                    || res.consentFilePath || res.consentRemarks;

                var html = '<div class="small text-muted mb-2">Bill No: <strong>' + (res.billNo || '-') + '</strong> &middot; Patient: <strong>' + (res.patientName || '-') + '</strong></div>';
                if (!anyRequired) {
                    html += '<div class="text-center text-muted py-3"><i class="bi bi-info-circle me-1"></i>No compliance documents were required for this bill.</div>';
                } else {
                    html += slotHtml('prescription', res.prescriptionFilePath, res.prescriptionRemarks);
                    html += slotHtml('ovd', res.ovdDocumentFilePath, res.ovdDocumentRemarks);
                    html += slotHtml('consent', res.consentFilePath, res.consentRemarks);
                }
                $modal.find('.lcdv-body').html(html);
            })
            .fail(function () {
                $modal.find('.lcdv-body').html('<div class="text-danger small">Unable to load documents for this bill.</div>');
            });
    }

    $(document).on('click', '.btn-view-compliance-docs', function () {
        var id = $(this).data('laborderid');
        if (id) open(id);
    });

    window.LabComplianceDocsViewer = { open: open };
})(window, jQuery);
