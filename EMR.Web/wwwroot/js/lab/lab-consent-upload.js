// LAB > B2C Order List / B2B Registration: "Upload Consent" after billing (SQLScripts/2553).
// The page renders a hidden .btn-upload-consent (data-laborderid) per row; this script asks which bills need a consent
// (a test with Consent Required = Yes, also inside a profile / package), shows the action on those rows only, and
// uploads a PDF / JPG / JPEG / PNG to LabOrderBooking/UploadOrderConsent. Nothing else on the page is touched.
// Also shows "Print FORM - F" (.li-print-formf, SQLScripts/2554) on B2C rows with a female consent test.
// Requires jQuery, Bootstrap 5 and SweetAlert2 (already on both pages).
(function (window, $) {
    'use strict';
    var me = document.currentScript;
    var STATUS_URL = me && me.dataset.statusUrl, UPLOAD_URL = me && me.dataset.uploadUrl;
    if (!STATUS_URL || !UPLOAD_URL) return;

    var MODAL_ID = 'labConsentUploadModal', ACCEPT = '.pdf,.jpg,.jpeg,.png', MAX = 10 * 1024 * 1024;
    var status = {};   // labOrderId -> { tests, hasFile, remarks }

    function esc(s) { return $('<div>').text(s == null ? '' : String(s)).html(); }

    function label(id) {
        var st = status[id], done = st && st.hasFile;
        $('.btn-upload-consent[data-laborderid="' + id + '"]').each(function () {
            var $b = $(this);
            $b.find('.lbl').text(done ? 'Replace Consent (uploaded)' : 'Upload Consent');
            $b.attr('title', done ? 'Consent uploaded - replace it' : 'Upload Consent');
            if (!$b.find('.lbl').length) $b.toggleClass('btn-outline-warning', !done).toggleClass('btn-outline-success', done);
            $b.find('i').toggleClass('text-warning', !done && $b.hasClass('dropdown-item')).toggleClass('text-success', done && $b.hasClass('dropdown-item'));
        });
    }

    function show(id) {
        $('.btn-upload-consent[data-laborderid="' + id + '"]').removeClass('d-none');
        $('.li-upload-consent[data-laborderid="' + id + '"]').removeClass('d-none');
        label(id);
    }

    function loadStatus() {
        var ids = $('.btn-upload-consent, .btn-print-formf').map(function () { return $(this).data('laborderid'); }).get();
        ids = ids.filter(function (v, i) { return v && ids.indexOf(v) === i; });
        if (!ids.length) return;
        $.get(STATUS_URL, { ids: ids.join(',') }).done(function (res) {
            if (!res || !res.success) return;
            (res.rows || []).forEach(function (r) {
                status[r.labOrderId] = { tests: r.tests, hasFile: r.hasFile, remarks: r.remarks };
                show(r.labOrderId);
                if (r.formFUrl) {   // 2554: FORM F (PC-PNDT) for a female consent test
                    $('.btn-print-formf[data-laborderid="' + r.labOrderId + '"]').attr('href', r.formFUrl);
                    $('.li-print-formf[data-laborderid="' + r.labOrderId + '"]').removeClass('d-none');
                }
            });
        });
    }

    function modal() {
        if (document.getElementById(MODAL_ID)) return $('#' + MODAL_ID);
        $('body').append(
            '<div class="modal fade" id="' + MODAL_ID + '" tabindex="-1" aria-hidden="true">' +
              '<div class="modal-dialog modal-dialog-centered"><div class="modal-content">' +
                '<div class="modal-header">' +
                  '<h6 class="modal-title fw-bold"><i class="bi bi-file-earmark-check text-primary me-2"></i>Upload Consent <span class="text-muted fw-normal lcu-bill"></span></h6>' +
                  '<button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>' +
                '</div>' +
                '<div class="modal-body">' +
                  '<div class="small mb-2 lcu-tests"></div>' +
                  '<div class="small mb-2 lcu-existing"></div>' +
                  '<div class="border rounded-3 p-3">' +
                    '<label class="form-label fw-semibold mb-1"><i class="bi bi-file-earmark-text text-primary me-1"></i>Consent</label>' +
                    '<input type="file" class="form-control lcu-file" accept="' + ACCEPT + '">' +
                    '<div class="form-text">PDF, JPG, JPEG or PNG, up to 10 MB.</div>' +
                    '<div class="text-danger small mt-1 lcu-error d-none"></div>' +
                  '</div>' +
                '</div>' +
                '<div class="modal-footer">' +
                  '<button type="button" class="btn btn-light" data-bs-dismiss="modal">Cancel</button>' +
                  '<button type="button" class="btn btn-primary lcu-save"><i class="bi bi-upload me-1"></i>Upload</button>' +
                '</div>' +
              '</div></div>' +
            '</div>');
        return $('#' + MODAL_ID);
    }

    function open(id, bill) {
        var st = status[id] || {}, $m = modal();
        $m.data('laborderid', id);
        $m.find('.lcu-bill').text(bill ? '· ' + bill : '');
        $m.find('.lcu-tests').html(st.tests ? '<i class="bi bi-info-circle me-1 text-primary"></i>Consent needed for: <b>' + esc(st.tests) + '</b>' : '');
        $m.find('.lcu-existing').html(st.hasFile
            ? '<span class="text-success"><i class="bi bi-check-circle me-1"></i>A consent is already uploaded; a new file replaces it (see "View Uploaded Documents").</span>'
            : (st.remarks ? '<span class="text-muted fst-italic"><i class="bi bi-chat-left-text me-1"></i>At billing: ' + esc(st.remarks) + '</span>' : ''));
        $m.find('.lcu-file').val('');
        $m.find('.lcu-error').addClass('d-none').text('');
        $m.find('.lcu-save').prop('disabled', false).html('<i class="bi bi-upload me-1"></i>Upload');
        bootstrap.Modal.getOrCreateInstance($m[0]).show();
    }

    function fail($m, msg) { $m.find('.lcu-error').removeClass('d-none').text(msg); }

    $(document).on('click', '.btn-upload-consent', function (e) {
        e.preventDefault();
        open($(this).data('laborderid'), $(this).data('bill'));
    });

    $(document).on('click', '#' + MODAL_ID + ' .lcu-save', function () {
        var $m = $('#' + MODAL_ID), id = $m.data('laborderid'), file = $m.find('.lcu-file')[0].files[0];
        if (!file) return fail($m, 'Please choose the consent file.');
        if (!/\.(pdf|jpe?g|png)$/i.test(file.name)) return fail($m, 'Only PDF, JPG, JPEG or PNG files can be uploaded.');
        if (file.size > MAX) return fail($m, 'The file is larger than 10 MB.');

        var fd = new FormData();
        fd.append('labOrderId', id);
        fd.append('consentFile', file);
        fd.append('__RequestVerificationToken', $('#frmConsentToken input[name="__RequestVerificationToken"]').val() || '');
        var $btn = $(this).prop('disabled', true).html('<span class="spinner-border spinner-border-sm me-1"></span>Uploading...');
        $.ajax({ url: UPLOAD_URL, type: 'POST', data: fd, processData: false, contentType: false })
            .done(function (res) {
                if (!res || !res.success) { $btn.prop('disabled', false).html('<i class="bi bi-upload me-1"></i>Upload'); return fail($m, (res && res.message) || 'The consent could not be uploaded.'); }
                status[id] = $.extend(status[id] || {}, { hasFile: true });
                label(id);
                bootstrap.Modal.getOrCreateInstance($m[0]).hide();
                if (window.Swal) Swal.fire({ icon: 'success', title: 'Consent uploaded', timer: 1600, showConfirmButton: false });
            })
            .fail(function (xhr) {
                $btn.prop('disabled', false).html('<i class="bi bi-upload me-1"></i>Upload');
                fail($m, xhr.status === 403 ? 'You do not have permission to upload a consent.' : 'Server error while uploading. Please try again.');
            });
    });

    $(loadStatus);
})(window, jQuery);
