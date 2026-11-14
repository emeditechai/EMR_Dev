// moved from Views/LabBreakpoints/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        $(function () {
            $('.select2-single').each(function () {
                $(this).select2({ theme: 'bootstrap-5', width: '100%', placeholder: $(this).data('placeholder'), allowClear: true });
            });
            $('.select2-multi').each(function () {
                $(this).select2({ theme: 'bootstrap-5', width: '100%', placeholder: $(this).data('placeholder'), closeOnSelect: false });
            });
            // Keep the order in which items were picked, so it becomes the saved display order.
            $('.select2-multi').on('select2:select', function (e) {
                var el = $(e.params.data.element);
                el.detach();
                $(this).append(el).trigger('change');
            });
            // Tier per selected item. Rows follow the select's option order, which is also the posted order.
            $('.tier-grid').each(function () {
                var grid = $(this), sel = $('#' + grid.data('for')), tiers = {};
                (grid.data('tiers') || []).forEach(function (t) { tiers[t.id] = t.tier; });
                var labels = { 1: 'Tier 1 - First line', 2: 'Tier 2 - Second line', 3: 'Tier 3 - Restricted', 4: 'Tier 4 - Last resort' };
                function render() {
                    var body = grid.find('tbody').empty(), n = 0;
                    sel.find('option:selected').each(function () {
                        var id = parseInt(this.value, 10), t = tiers[id] || 1, opts = '';
                        for (var k = 1; k <= 4; k++) opts += '<option value="' + k + '"' + (k === t ? ' selected' : '') + '>' + labels[k] + '</option>';
                        body.append($('<tr>').append($('<td class="text-muted">').text(++n), $('<td>').text(this.text),
                            $('<td>').append($('<select class="form-select form-select-sm">').attr('name', grid.data('tiername')).attr('data-id', id).html(opts))));
                    });
                    grid.toggle(n > 0);
                }
                grid.on('change', 'select', function () { tiers[$(this).data('id')] = parseInt(this.value, 10); });
                sel.on('change', render);
                render();
            });
        });
    
