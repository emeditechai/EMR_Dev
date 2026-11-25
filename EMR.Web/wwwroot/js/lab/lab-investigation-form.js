// Investigation Master Create / Edit: Test Category and Test Method follow the selected Department, Test Sub-Category
// follows the selected Category (LabInvestigations/GetDependentLookups, SQLScripts/2552).
(function () {
    const $dept = $('#cboDepartment'), $cat = $('#cboCategory'), $sub = $('#cboSubCategory'), $method = $('#cboMethod');
    const url = $dept.data('lookup-url');
    if (!$dept.length || !url) return;

    function fill($sel, items, placeholder) {
        const keep = $sel.val();
        $sel.empty().append($('<option>', { value: '', text: placeholder }));
        (items || []).forEach(i => $sel.append($('<option>', { value: i.value, text: i.text })));
        // keep the current choice when it is still in the list
        if (keep && $sel.find(`option[value="${keep}"]`).length) $sel.val(keep); else $sel.val('');
    }

    function load(what) {
        return $.get(url, { departmentId: $dept.val() || 0, categoryId: $cat.val() || 0 }).done(function (res) {
            if (!res || !res.success) return;
            if (what === 'department') {
                fill($cat, res.categories, '-- Select Test Category --');
                fill($method, res.methods, '-- Select Test Method --');
                if (!$cat.val()) fill($sub, [], '-- None / Select Sub-Category --');
                else fill($sub, res.subCategories, '-- None / Select Sub-Category --');
            } else {
                fill($sub, res.subCategories, '-- None / Select Sub-Category --');
            }
        });
    }

    $dept.on('change', () => load('department'));
    $cat.on('change', () => load('category'));
})();
