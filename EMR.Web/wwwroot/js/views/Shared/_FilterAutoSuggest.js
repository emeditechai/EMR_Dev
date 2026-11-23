// moved from Views/Shared/_FilterAutoSuggest.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    $(function () {
        if (!$.fn.select2) return;   // the plain dropdowns keep working
        const ids = ['#ddlDepartment', '#ddlCategory', '#ddlSubCategory'];

        ids.forEach(function (id) {
            const $s = $(id);
            if (!$s.length) return;
            $s.parent().addClass('fas-wrap');
            const placeholder = $s.data('placeholder') || $s.find('option[value=""]').first().text() || 'All';
            $s.select2({
                theme: 'bootstrap-5',
                width: '100%',
                placeholder: placeholder,
                allowClear: true,
                selectionCssClass: 'select2--small',
                dropdownCssClass: 'select2--small fas-dropdown',
                language: { noResults: () => 'No match found' }
            });

            // the page refills the options (cascade) and resets values in code: keep the shown text in step
            // ("change.select2" updates the display only - the page's own change handlers do not run again)
            let pending = false;
            const sync = () => { if (pending) return; pending = true; setTimeout(() => { pending = false; $s.trigger('change.select2'); }, 0); };
            new MutationObserver(sync).observe($s[0], { childList: true, subtree: true, attributes: true, attributeFilter: ['selected'] });
            $s.data('fasSync', sync);
        });

        // Lab Reporting's "Reset" clears the values without a change event
        $(document).on('click', '#btnResetFilters', function () {
            ids.forEach(id => $(id).data('fasSync')?.());
        });

        // typing starts the search at once when the dropdown opens
        $(document).on('select2:open', function (e) {
            if (!ids.includes('#' + e.target.id)) return;
            setTimeout(() => document.querySelector('.select2-container--open .select2-search__field')?.focus(), 0);
        });
    });
