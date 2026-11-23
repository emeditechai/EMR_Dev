// moved from Views/LabFormulaParameters/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
$(function () {
    var rows = $('#formulaTable tbody tr.data-row');
    var pageSize = 10, currentPage = 1;

    function totalPages() { return Math.max(1, Math.ceil(rows.length / pageSize)); }

    function paginate() {
        var tp = totalPages();
        if (currentPage > tp) currentPage = tp;
        rows.hide();
        rows.slice((currentPage - 1) * pageSize, currentPage * pageSize).show();
        renderNav();
    }

    function renderNav() {
        var tp = totalPages();
        var start = (currentPage - 1) * pageSize + 1;
        var end = Math.min(currentPage * pageSize, rows.length);

        $('.page-info').text(rows.length ? 'Page ' + currentPage + ' of ' + tp + ' (' + start + '–' + end + ' of ' + rows.length + ')' : 'No records');
        $('.page-first, .page-prev').prop('disabled', currentPage <= 1);
        $('.page-next, .page-last').prop('disabled', currentPage >= tp);
        $('.page-goto-input').attr('max', tp);

        var html = '';
        var maxBtns = 5, half = Math.floor(maxBtns / 2);
        var s = Math.max(1, currentPage - half), e = Math.min(tp, s + maxBtns - 1);
        if (e - s < maxBtns - 1) s = Math.max(1, e - maxBtns + 1);
        for (var i = s; i <= e; i++) {
            html += '<button class="btn btn-sm ' + (i === currentPage ? 'btn-primary' : 'btn-outline-secondary') + ' page-num" data-page="' + i + '">' + i + '</button>';
        }
        $('.page-numbers').html(html);
    }

    $(document).on('click', '.page-num', function () { currentPage = +$(this).data('page'); paginate(); });
    $(document).on('click', '.page-first', function () { currentPage = 1; paginate(); });
    $(document).on('click', '.page-last', function () { currentPage = totalPages(); paginate(); });
    $(document).on('click', '.page-prev', function () { if (currentPage > 1) { currentPage--; paginate(); } });
    $(document).on('click', '.page-next', function () { if (currentPage < totalPages()) { currentPage++; paginate(); } });
    $(document).on('change', '.page-size-select', function () {
        pageSize = +$(this).val();
        $('.page-size-select').val(pageSize);
        currentPage = 1;
        paginate();
    });
    $(document).on('click', '.page-goto-btn', function () {
        var v = +$(this).siblings('.page-goto-input').val();
        if (v >= 1 && v <= totalPages()) { currentPage = v; paginate(); }
    });
    $(document).on('keypress', '.page-goto-input', function (e) {
        if (e.which === 13) { e.preventDefault(); $(this).siblings('.page-goto-btn').click(); }
    });

    paginate();
});
