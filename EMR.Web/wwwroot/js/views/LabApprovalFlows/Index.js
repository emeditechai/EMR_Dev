// moved from Views/LabApprovalFlows/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        $(function () {
            // searchable filters (Select2, already used elsewhere in the app)
            $('.flow-filter-select').each(function () {
                const $el = $(this);
                $el.select2({
                    width: '100%', minimumResultsForSearch: 0, allowClear: true,
                    placeholder: $el.find('option[value=""]').first().text() || 'All',
                    language: { noResults: () => 'No match found' }
                })
                .on('select2:unselecting', function () { $(this).data('cleared', true); })
                .on('select2:opening', function (e) { if ($(this).data('cleared')) { $(this).removeData('cleared'); e.preventDefault(); } });
            });
            $(document).on('select2:open', () => setTimeout(() => { const f = document.querySelector('.select2-container--open .select2-search__field'); if (f) f.focus(); }, 0));
        });
    
