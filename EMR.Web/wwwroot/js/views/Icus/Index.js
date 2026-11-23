// moved from Views/Icus/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // Initial setup for Add Modal default rate heads
        document.addEventListener('DOMContentLoaded', function () {
            // Seed initial rows for Add Modal
            addPresetRow('addRateTable', 'ICU Bed & Accommodation', 'BED', 4500, 'Per Day');
            addPresetRow('addRateTable', 'Critical Care 1:1 Nursing', 'NUR', 3000, 'Per Day');
            addPresetRow('addRateTable', 'Continuous Multi-para Monitoring', 'MON', 1500, 'Per Day');
            addPresetRow('addRateTable', 'Central High-flow Oxygen', 'O2', 2000, 'Per Day');
        });

        function addRateRow(tableId, name = '', code = '', amount = 0, freq = 'Per Day') {
            var tbody = document.querySelector('#' + tableId + ' tbody');
            var rowIdx = tbody.children.length;

            var tr = document.createElement('tr');
            tr.innerHTML = `
                <td>
                    <input name="Details[${rowIdx}].RateHeadName" class="form-control form-control-sm" value="${name}" placeholder="e.g. Ventilator Support" required />
                </td>
                <td>
                    <input name="Details[${rowIdx}].RateHeadCode" class="form-control form-control-sm font-monospace text-uppercase" value="${code}" placeholder="e.g. VENT" />
                </td>
                <td>
                    <div class="input-group input-group-sm">
                        <span class="input-group-text"><i class="bi bi-currency-rupee"></i></span>
                        <input name="Details[${rowIdx}].RateAmount" class="form-control form-control-sm rate-amt-input" type="number" step="0.01" min="0" value="${amount}" oninput="recalcTotal('${tableId}')" required />
                    </div>
                </td>
                <td>
                    <select name="Details[${rowIdx}].BillingFrequency" class="form-select form-select-sm">
                        <option value="Per Day" ${freq === 'Per Day' ? 'selected' : ''}>Per Day</option>
                        <option value="Per Hour" ${freq === 'Per Hour' ? 'selected' : ''}>Per Hour</option>
                        <option value="Per Usage" ${freq === 'Per Usage' ? 'selected' : ''}>Per Usage</option>
                        <option value="Fixed" ${freq === 'Fixed' ? 'selected' : ''}>Fixed Package</option>
                    </select>
                </td>
                <td class="text-center">
                    <button type="button" class="btn btn-sm btn-outline-danger" onclick="removeRateRow(this, '${tableId}')" title="Remove">
                        <i class="bi bi-x-lg"></i>
                    </button>
                </td>
            `;
            tbody.appendChild(tr);
            recalcTotal(tableId);
        }

        function addPresetRow(tableId, name, code, amount, freq) {
            addRateRow(tableId, name, code, amount, freq);
        }

        function removeRateRow(btn, tableId) {
            var tr = btn.closest('tr');
            tr.remove();
            reindexRows(tableId);
            recalcTotal(tableId);
        }

        function reindexRows(tableId) {
            var tbody = document.querySelector('#' + tableId + ' tbody');
            Array.from(tbody.children).forEach((tr, idx) => {
                tr.querySelectorAll('input, select').forEach(input => {
                    var name = input.getAttribute('name');
                    if (name) {
                        input.setAttribute('name', name.replace(/Details\[\d+\]/, `Details[${idx}]`));
                    }
                });
            });
        }

        function recalcTotal(tableId) {
            var total = 0;
            document.querySelectorAll('#' + tableId + ' .rate-amt-input').forEach(input => {
                total += parseFloat(input.value) || 0;
            });
            var displayId = tableId === 'addRateTable' ? 'addTotalDisplay' : 'editTotalDisplay';
            document.getElementById(displayId).innerText = '₹' + total.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        }

        function openAddTariffForIcu(icuId) {
            document.getElementById('addTariffIcuId').value = icuId;
            var modal = new bootstrap.Modal(document.getElementById('addTariffModal'));
            modal.show();
        }

        function openEditIcuModal(id) {
            fetch('/Icus/GetIcuJson/' + id)
                .then(r => r.json())
                .then(data => {
                    document.getElementById('editIcuId').value = data.icuId;
                    document.getElementById('editIcuWardId').value = data.wardId;
                    document.getElementById('editIcuType').value = data.icuType;
                    document.getElementById('editIcuCode').value = data.icuCode;
                    document.getElementById('editIcuName').value = data.icuName;
                    document.getElementById('editIcuBedCapacity').value = data.bedCapacity;
                    document.getElementById('editIcuVentCapacity').value = data.ventilatorCapacity;
                    document.getElementById('editIcuIsoCapacity').value = data.isolationCapacity;
                    document.getElementById('editIcuDesc').value = data.description || '';
                    document.getElementById('editIcuIsActive').checked = data.isActive;

                    var modal = new bootstrap.Modal(document.getElementById('editIcuModal'));
                    modal.show();
                })
                .catch(err => alert('Failed to load ICU details.'));
        }

        function openEditTariffModal(id) {
            fetch('/Icus/GetTariffJson/' + id)
                .then(r => r.json())
                .then(data => {
                    document.getElementById('editTariffId').value = data.icuTariffId;
                    document.getElementById('editTariffIcuId').value = data.icuId;
                    document.getElementById('editTariffCatId').value = data.tariffCategoryId;

                    if (data.effectiveFrom) {
                        document.getElementById('editTariffEffectiveFrom').value = data.effectiveFrom.substring(0, 10);
                    }
                    if (data.effectiveTo) {
                        document.getElementById('editTariffEffectiveTo').value = data.effectiveTo.substring(0, 10);
                    } else {
                        document.getElementById('editTariffEffectiveTo').value = '';
                    }

                    document.getElementById('editTariffDesc').value = data.description || '';
                    document.getElementById('editTariffIsActive').checked = data.isActive;

                    // Clear and populate dynamic rate heads
                    var tbody = document.querySelector('#editRateTable tbody');
                    tbody.innerHTML = '';

                    if (data.details && data.details.length > 0) {
                        data.details.forEach(d => {
                            addRateRow('editRateTable', d.rateHeadName, d.rateHeadCode || '', d.rateAmount, d.billingFrequency || 'Per Day');
                        });
                    } else {
                        addRateRow('editRateTable', 'ICU Bed & Accommodation', 'BED', 0, 'Per Day');
                    }

                    recalcTotal('editRateTable');

                    var modal = new bootstrap.Modal(document.getElementById('editTariffModal'));
                    modal.show();
                })
                .catch(err => alert('Failed to load Tariff details.'));
        }

        function openViewTariffModal(id) {
            fetch('/Icus/GetTariffViewJson/' + id)
                .then(r => r.json())
                .then(data => {
                    document.getElementById('viewTariffHeaderSubtitle').innerText = `${data.icuName} (${data.icuCode}) - ${data.tariffCategoryName}`;
                    document.getElementById('viewTariffIcuName').innerText = data.icuName;
                    document.getElementById('viewTariffIcuCode').innerText = data.icuCode;
                    document.getElementById('viewTariffIcuType').innerText = data.icuType;

                    document.getElementById('viewTariffCategoryName').innerText = data.tariffCategoryName;
                    document.getElementById('viewTariffPatientCategory').innerText = data.patientCategory ? `Category: ${data.patientCategory}` : 'All Patients';

                    document.getElementById('viewTariffPeriod').innerText = `${data.effectiveFrom} to ${data.effectiveTo}`;
                    document.getElementById('viewTariffStatusBadge').innerHTML = data.isActive
                        ? '<span class="badge bg-success-subtle text-success border border-success-subtle">Active Package</span>'
                        : '<span class="badge bg-danger-subtle text-danger border border-danger-subtle">Inactive Package</span>';

                    var totalFormatted = '₹' + data.totalRate.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
                    document.getElementById('viewTariffTotalRate').innerText = totalFormatted;
                    document.getElementById('viewTariffTableTotal').innerText = totalFormatted;

                    document.getElementById('viewTariffHeadsCount').innerText = data.details ? data.details.length : 0;

                    var tbody = document.querySelector('#viewTariffDetailsTable tbody');
                    tbody.innerHTML = '';

                    if (data.details && data.details.length > 0) {
                        data.details.forEach((d, idx) => {
                            var tr = document.createElement('tr');
                            tr.innerHTML = `
                                <td class="ps-3 text-muted">${idx + 1}</td>
                                <td>
                                    <div class="fw-semibold text-dark">${d.rateHeadName}</div>
                                    ${d.remarks ? `<small class="text-muted">${d.remarks}</small>` : ''}
                                </td>
                                <td>
                                    ${d.rateHeadCode ? `<span class="badge bg-light text-dark font-monospace border">${d.rateHeadCode}</span>` : '<span class="text-muted">—</span>'}
                                </td>
                                <td>
                                    <span class="badge bg-info-subtle text-info-emphasis border">${d.billingFrequency || 'Per Day'}</span>
                                </td>
                                <td>
                                    ${d.isMandatory ? '<span class="badge bg-primary-subtle text-primary border">Mandatory</span>' : '<span class="badge bg-secondary-subtle text-secondary border">Optional</span>'}
                                </td>
                                <td class="text-end pe-3 font-monospace fw-bold text-dark">
                                    ₹${d.rateAmount.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                                </td>
                            `;
                            tbody.appendChild(tr);
                        });
                    } else {
                        tbody.innerHTML = '<tr><td colspan="6" class="text-center py-4 text-muted">No rate heads configured.</td></tr>';
                    }

                    document.getElementById('viewTariffDesc').innerText = data.description || 'No additional remarks provided.';
                    document.getElementById('viewTariffEditBtn').setAttribute('onclick', `bootstrap.Modal.getInstance(document.getElementById('viewTariffModal')).hide(); openEditTariffModal(${data.icuTariffId});`);

                    var modal = new bootstrap.Modal(document.getElementById('viewTariffModal'));
                    modal.show();
                })
                .catch(err => alert('Failed to load Tariff details.'));
        }

        function openViewIcuModal(id) {
            fetch('/Icus/GetIcuViewJson/' + id)
                .then(r => r.json())
                .then(data => {
                    document.getElementById('viewIcuHeaderSubtitle').innerText = `${data.icuName} (${data.icuCode})`;
                    document.getElementById('viewIcuName').innerText = data.icuName;
                    document.getElementById('viewIcuCode').innerText = data.icuCode;
                    document.getElementById('viewIcuType').innerText = data.icuType;

                    document.getElementById('viewIcuWardName').innerText = data.wardName || '—';
                    document.getElementById('viewIcuWardType').innerText = data.wardType ? `Type: ${data.wardType}` : '';

                    document.getElementById('viewIcuBedCapacity').innerText = data.bedCapacity;
                    document.getElementById('viewIcuVentCapacity').innerText = data.ventilatorCapacity;
                    document.getElementById('viewIcuIsoCapacity').innerText = data.isolationCapacity;

                    document.getElementById('viewIcuDesc').innerText = data.description || 'No clinical scope provided.';

                    document.getElementById('viewIcuTariffsCount').innerText = data.tariffs ? data.tariffs.length : 0;

                    var tbody = document.querySelector('#viewIcuTariffsTable tbody');
                    tbody.innerHTML = '';

                    if (data.tariffs && data.tariffs.length > 0) {
                        data.tariffs.forEach(t => {
                            var tr = document.createElement('tr');
                            tr.innerHTML = `
                                <td class="ps-3">
                                    <div class="fw-semibold text-primary">${t.tariffCategoryName}</div>
                                    ${t.patientCategory ? `<small class="badge bg-secondary-subtle text-secondary">${t.patientCategory}</small>` : ''}
                                </td>
                                <td>
                                    <span class="badge bg-light text-dark border">${t.rateHeadsCount} Components</span>
                                </td>
                                <td class="font-monospace fw-bold text-success">
                                    ₹${t.totalRate.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                                </td>
                                <td class="small">
                                    ${t.effectiveFrom} to ${t.effectiveTo}
                                </td>
                                <td>
                                    ${t.isActive ? '<span class="badge bg-success-subtle text-success border border-success-subtle">Active</span>' : '<span class="badge bg-danger-subtle text-danger border border-danger-subtle">Inactive</span>'}
                                </td>
                                <td class="text-end pe-3">
                                    <button type="button" class="btn btn-xs btn-outline-info" onclick="bootstrap.Modal.getInstance(document.getElementById('viewIcuModal')).hide(); openViewTariffModal(${t.icuTariffId});" title="View Tariff Breakdown">
                                        <i class="bi bi-eye"></i> Details
                                    </button>
                                </td>
                            `;
                            tbody.appendChild(tr);
                        });
                    } else {
                        tbody.innerHTML = '<tr><td colspan="6" class="text-center py-4 text-muted">No tariff packages configured for this ICU yet.</td></tr>';
                    }

                    document.getElementById('viewIcuAddTariffBtn').setAttribute('onclick', `bootstrap.Modal.getInstance(document.getElementById('viewIcuModal')).hide(); openAddTariffForIcu(${data.icuId});`);
                    document.getElementById('viewIcuEditBtn').setAttribute('onclick', `bootstrap.Modal.getInstance(document.getElementById('viewIcuModal')).hide(); openEditIcuModal(${data.icuId});`);

                    var modal = new bootstrap.Modal(document.getElementById('viewIcuModal'));
                    modal.show();
                })
                .catch(err => alert('Failed to load ICU details.'));
        }
    
