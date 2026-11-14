// moved from Views/LabInvestigationProfiles/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        var detailRows = [];

        function toggleProfileType() {
            var type = parseInt($('#profileTypeSelect').val()) || 1;
            if (type === 1) {
                $('#profileTestContainer').show();
                $('#packageNameContainer').hide();
                $('#discountContainer').hide();
                $('#startDateContainer').hide();
                $('#endDateContainer').hide();
                var selectedText = $('#profileTestSelect option:selected').text();
                if (selectedText && $('#profileTestSelect').val()) {
                    var testName = selectedText.split(' (')[0].trim();
                    $('#hiddenProfileName').val(testName);
                }
            } else { // Package (2)
                $('#profileTestContainer').hide();
                $('#packageNameContainer').show();
                $('#discountContainer').show();
                $('#startDateContainer').show();
                $('#endDateContainer').show();
                $('#hiddenProfileName').val($('#packageNameInput').val());
            }
        }

        $(document).ready(function () {
            toggleProfileType();
            $('#profileTypeSelect').on('change', toggleProfileType);

            $('#profileTestSelect').on('change', function () {
                var $opt = $(this).find('option:selected');
                if ($(this).val()) {
                    var text = $opt.text();
                    var testName = text.split(' (')[0].trim();
                    $('#hiddenProfileName').val(testName);
                    $('#packageNameInput').val(testName);
                }
            });

            $('#packageNameInput').on('input', function () {
                $('#hiddenProfileName').val($(this).val());
            });

            var existingJson = $('#DetailsJson').val();
            if (existingJson && existingJson !== '[]') {
                try { detailRows = JSON.parse(existingJson); } catch (e) { detailRows = []; }
            }
            renderGrid();

            // Component test: auto-suggest - type part of the name or code to filter the list
            $('#selectTestId').select2({
                theme: 'bootstrap-5',
                width: '100%',
                placeholder: '-- Type test name or code --',
                allowClear: true
            });

            $('#btnAddDetailRow').on('click', function () {
                var $sel = $('#selectTestId');
                var testId = $sel.val();
                var testText = $sel.find('option:selected').text().trim();
                var seq = parseInt($('#inputSeq').val()) || (detailRows.length + 1);

                if (!testId) { alert('Please select an investigation test.'); return; }
                var alreadyAdded = false;
                $.each(detailRows, function(i, r) { if (r.Test_ID == testId) alreadyAdded = true; });
                if (alreadyAdded) { alert('This test is already added to the profile.'); return; }

                var mrpMatch = testText.match(/[₹]([0-9,]+\.?[0-9]*)/);
                var mrpVal = mrpMatch ? parseFloat(mrpMatch[1].replace(/,/g, '')) : 0;

                detailRows.push({ Detail_ID: 0, Test_ID: parseInt(testId), Test_Name: testText, Sequence: seq, TestMRP: mrpVal });
                detailRows.sort(function(a, b) { return a.Sequence - b.Sequence; });
                renderGrid();
                $sel.val(null).trigger('change');
                $('#inputSeq').val(detailRows.length + 1);
            });

            $(document).on('click', '.btn-delete-row', function () {
                var idx = parseInt($(this).data('index'));
                detailRows.splice(idx, 1);
                renderGrid();
            });

            $('#profileForm').on('submit', function (e) {
                var type = parseInt($('#profileTypeSelect').val()) || 1;
                if (type === 1) {
                    var testId = $('#profileTestSelect').val();
                    if (!testId) {
                        alert('Please select a Profile Test.');
                        e.preventDefault();
                        return false;
                    }
                    var selectedText = $('#profileTestSelect option:selected').text();
                    var testName = selectedText.split(' (')[0].trim();
                    $('#hiddenProfileName').val(testName);
                    $('#packageNameInput').val(testName);
                } else {
                    var pkgName = $('#packageNameInput').val().trim();
                    if (!pkgName) {
                        alert('Please enter a Package Name.');
                        e.preventDefault();
                        return false;
                    }
                    $('#hiddenProfileName').val(pkgName);
                }

                if (detailRows.length === 0) {
                    alert('Please add at least one component test detail row before saving.');
                    e.preventDefault();
                    return false;
                }
                $('#DetailsJson').val(JSON.stringify(detailRows));
                return true;
            });
        });

        function renderGrid() {
            var tbody = document.querySelector('#detailsDataTable tbody');
            tbody.innerHTML = '';
            if (detailRows.length === 0) {
                tbody.innerHTML = '<tr><td colspan="4" class="text-center text-muted py-3"><i class="bi bi-info-circle me-1"></i>No tests added yet. Use the controls above to add tests.</td></tr>';
            } else {
                detailRows.forEach(function(r, i) {
                    var mrp = parseFloat(r.TestMRP || 0).toFixed(2);
                    var safeName = r.Test_Name.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
                    var tr = '<tr>' +
                        '<td class="text-center font-monospace fw-semibold">' + r.Sequence + '</td>' +
                        '<td class="fw-semibold text-dark">' + safeName + '</td>' +
                        '<td class="text-end fw-bold">₹' + mrp + '</td>' +
                        '<td class="text-center"><button type="button" class="btn btn-sm btn-outline-danger btn-delete-row" data-index="' + i + '" title="Remove"><i class="bi bi-trash"></i></button></td>' +
                        '</tr>';
                    tbody.innerHTML += tr;
                });
            }
            $('#DetailsJson').val(JSON.stringify(detailRows));
        }
    
