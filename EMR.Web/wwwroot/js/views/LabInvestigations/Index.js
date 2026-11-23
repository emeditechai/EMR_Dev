// moved from Views/LabInvestigations/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        $(document).ready(function () {
            var rows = $('table.table tbody tr').not(':has(td[colspan])');
            var pageSize = 10;
            var currentPage = 1;

            function renderNav(navEl, totalPages) {
                navEl.empty();
                navEl.append('<li class="page-item ' + (currentPage === 1 ? 'disabled' : '') + '"><a class="page-link" href="#" data-page="first" title="First Page">&laquo;&laquo;</a></li>');
                navEl.append('<li class="page-item ' + (currentPage === 1 ? 'disabled' : '') + '"><a class="page-link" href="#" data-page="prev" title="Previous Page">&laquo;</a></li>');
                var startPage = Math.max(1, currentPage - 2);
                var endPage = Math.min(totalPages, startPage + 4);
                if (endPage - startPage < 4) startPage = Math.max(1, endPage - 4);
                for (var i = startPage; i <= endPage; i++) {
                    navEl.append('<li class="page-item ' + (i === currentPage ? 'active' : '') + '"><a class="page-link" href="#" data-page="' + i + '">' + i + '</a></li>');
                }
                navEl.append('<li class="page-item ' + (currentPage === totalPages ? 'disabled' : '') + '"><a class="page-link" href="#" data-page="next" title="Next Page">&raquo;</a></li>');
                navEl.append('<li class="page-item ' + (currentPage === totalPages ? 'disabled' : '') + '"><a class="page-link" href="#" data-page="last" title="Last Page">&raquo;&raquo;</a></li>');
            }

            function paginate() {
                var total = rows.length;
                var totalPages = Math.max(1, Math.ceil(total / pageSize));
                if (currentPage > totalPages) currentPage = totalPages;
                rows.hide();
                rows.slice((currentPage - 1) * pageSize, currentPage * pageSize).show();
                var start = total === 0 ? 0 : (currentPage - 1) * pageSize + 1;
                var end = Math.min(currentPage * pageSize, total);
                var infoText = 'Showing ' + start + ' to ' + end + ' of ' + total + ' entries (Page ' + currentPage + ' of ' + totalPages + ')';
                $('#pageInfo, #pageInfoTop').text(infoText);
                $('#pageSize, #pageSizeTop').val(pageSize);
                $('#goToPage, #goToPageTop').attr('max', totalPages).attr('placeholder', currentPage);
                renderNav($('#pageNav'), totalPages);
                renderNav($('#pageNavTop'), totalPages);
            }

            $('#pageSize, #pageSizeTop').on('change', function () {
                pageSize = parseInt($(this).val());
                $('#pageSize, #pageSizeTop').val(pageSize);
                currentPage = 1;
                paginate();
            });

            $('#pageNav, #pageNavTop').on('click', 'a.page-link', function (e) {
                e.preventDefault();
                var p = $(this).data('page');
                var totalPages = Math.max(1, Math.ceil(rows.length / pageSize));
                if (p === 'first') { currentPage = 1; }
                else if (p === 'prev') { if (currentPage > 1) currentPage--; }
                else if (p === 'next') { if (currentPage < totalPages) currentPage++; }
                else if (p === 'last') { currentPage = totalPages; }
                else { currentPage = parseInt(p); }
                paginate();
            });

            $('.goToPageBtn').on('click', function () {
                var input = $('#' + $(this).data('target'));
                var page = parseInt(input.val());
                var totalPages = Math.max(1, Math.ceil(rows.length / pageSize));
                if (!isNaN(page) && page >= 1 && page <= totalPages) {
                    currentPage = page;
                    paginate();
                } else {
                    alert('Please enter a valid page number (1 - ' + totalPages + ')');
                }
                input.val('');
            });

            $('#goToPage, #goToPageTop').on('keypress', function (e) {
                if (e.which === 13) {
                    e.preventDefault();
                    $(this).siblings('.goToPageBtn').click();
                }
            });

            paginate();
        });
    
