// moved from Views/Insurances/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        let currentInsuranceTPAId = 0;
        let currentInsuranceName = '';
        let currentInsuranceCode = '';
        let currentInsuranceType = '';
        let currentPolicyPrefix = '';
        let masterTariffItemsCache = {};
        let loadedTariffs = [];
        let currentEntitlementFilter = 'ALL';

        // 1. Open Insurance Tariffs Modal
        function openInsuranceTariffsModal(insuranceId, name, code, type, prefix) {
            currentInsuranceTPAId = insuranceId;
            currentInsuranceName = name;
            currentInsuranceCode = code;
            currentInsuranceType = type;
            currentPolicyPrefix = prefix;

            document.getElementById('insuranceTariffsModalLabel').innerHTML = 
                `Insurance Tariff: <span class="text-warning">${name}</span>`;
            document.getElementById('modalInsSubtitle').innerText = 
                `Code: ${code || '—'} | Type: ${type} | Policy Prefix: ${prefix || '—'}`;

            toggleTariffForm(false);
            loadInsuranceTariffs();

            const modal = new bootstrap.Modal(document.getElementById('insuranceTariffsModal'));
            modal.show();
        }

        // 2. Load Tariffs via AJAX
        async function loadInsuranceTariffs() {
            const tbody = document.getElementById('tariffsTableBody');
            tbody.innerHTML = `
                <tr>
                    <td colspan="9" class="text-center py-4 text-muted">
                        <div class="spinner-border spinner-border-sm text-primary me-2" role="status"></div>
                        Loading agreed tariffs...
                    </td>
                </tr>`;

            try {
                const response = await fetch(`/Insurances/GetInsuranceTariffs?insuranceTpaId=${currentInsuranceTPAId}`);
                const result = await response.json();

                if (result.success) {
                    loadedTariffs = result.data || [];
                    renderTariffsTable();
                    updateTariffsKPIs();
                    // Update count badge on parent table
                    const badge = document.getElementById(`badge-tariff-count-${currentInsuranceTPAId}`);
                    if (badge) badge.innerText = loadedTariffs.length;
                } else {
                    tbody.innerHTML = `<tr><td colspan="9" class="text-center text-danger py-3">${result.message || 'Failed to load tariffs.'}</td></tr>`;
                }
            } catch (err) {
                tbody.innerHTML = `<tr><td colspan="9" class="text-center text-danger py-3">Error connecting to server.</td></tr>`;
            }
        }

        // 3. Render Tariffs Table with Filters
        function renderTariffsTable() {
            const tbody = document.getElementById('tariffsTableBody');
            const search = (document.getElementById('tariffSearchInput').value || '').toLowerCase();

            const filtered = loadedTariffs.filter(t => {
                const matchHead = (currentEntitlementFilter === 'ALL' || t.entitlementType.toLowerCase() === currentEntitlementFilter.toLowerCase());
                const matchSearch = !search || 
                    (t.itemName && t.itemName.toLowerCase().includes(search)) ||
                    (t.itemCode && t.itemCode.toLowerCase().includes(search)) ||
                    (t.entitlementType && t.entitlementType.toLowerCase().includes(search)) ||
                    (t.deductionRuleType && t.deductionRuleType.toLowerCase().includes(search));
                return matchHead && matchSearch;
            });

            if (filtered.length === 0) {
                tbody.innerHTML = `
                    <tr>
                        <td colspan="9" class="text-center py-5 text-muted">
                            <i class="bi bi-shield-slash fs-2 d-block mb-1 opacity-50"></i>
                            No tariff rules configured for this filter. Click <strong>"Add Tariff Rule"</strong> to create one.
                        </td>
                    </tr>`;
                return;
            }

            let html = '';
            filtered.forEach((t, idx) => {
                const headBadgeClass = getEntitlementBadgeClass(t.entitlementType);
                const fromDate = new Date(t.effective_From).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
                const toDate = new Date(t.effective_To).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
                const isExpired = new Date(t.effective_To) < new Date();

                // Format Deduction Rule badge
                let ruleBadgeHtml = '';
                if (t.deductionRuleType.includes('Percentage') || t.deductionRuleType.includes('Co-Pay')) {
                    ruleBadgeHtml = `<span class="badge bg-warning bg-opacity-10 text-dark border border-warning font-monospace">${t.deductionRuleType}: ${t.deductionValue}%</span>`;
                } else if (t.deductionRuleType.includes('Non-Payable')) {
                    ruleBadgeHtml = `<span class="badge bg-danger bg-opacity-10 text-danger border border-danger">100% Non-Payable</span>`;
                } else if (t.deductionValue > 0) {
                    ruleBadgeHtml = `<span class="badge bg-info bg-opacity-10 text-dark border font-monospace">${t.deductionRuleType}: ₹${t.deductionValue.toLocaleString('en-IN')}</span>`;
                } else {
                    ruleBadgeHtml = `<span class="badge bg-light text-dark border">${t.deductionRuleType}</span>`;
                }

                html += `
                    <tr>
                        <td class="text-muted small">${idx + 1}</td>
                        <td>
                            <span class="badge ${headBadgeClass}">${t.entitlementType}</span>
                        </td>
                        <td>
                            <div class="fw-semibold text-dark">${t.itemName || 'Service Item #' + t.reference_ID}</div>
                            <span class="badge bg-light text-dark border font-monospace extra-small">${t.itemCode || '—'}</span>
                        </td>
                        <td>
                            <span class="text-muted small">₹${(t.standardBaseRate || 0).toLocaleString('en-IN', { minimumFractionDigits: 2 })}</span>
                        </td>
                        <td>
                            <span class="fw-bold text-success fs-7">₹${(t.rate || 0).toLocaleString('en-IN', { minimumFractionDigits: 2 })}</span>
                        </td>
                        <td>
                            ${ruleBadgeHtml}
                        </td>
                        <td>
                            <div class="small">
                                <span class="text-dark">${fromDate}</span>
                                <span class="text-muted"> to </span>
                                <span class="${isExpired ? 'text-danger fw-bold' : 'text-dark'}">${toDate}</span>
                            </div>
                        </td>
                        <td>
                            <div class="form-check form-switch m-0">
                                <input data-permission="MASTER.INSURANCES:TARIFFS" class="form-check-input" type="checkbox" role="switch" ${t.status ? 'checked' : ''} 
                                       onchange="handleToggleTariffStatus(${t.insTariff_ID})" title="${t.status ? 'Deactivate' : 'Activate'}" />
                            </div>
                        </td>
                        <td class="text-end">
                            <button type="button" class="btn btn-sm btn-outline-primary me-1" onclick="editTariffRule(${t.insTariff_ID})" title="Edit Tariff Rule">
                                <i class="bi bi-pencil"></i>
                            </button>
                            <button type="button" class="btn btn-sm btn-outline-danger" data-permission="MASTER.INSURANCES:TARIFFS" onclick="deleteTariffRule(${t.insTariff_ID})" title="Delete Tariff Rule">
                                <i class="bi bi-trash"></i>
                            </button>
                        </td>
                    </tr>`;
            });

            tbody.innerHTML = html;
        }

        function getEntitlementBadgeClass(head) {
            switch (head) {
                case 'Room': return 'bg-secondary text-white';
                case 'Procedure': return 'bg-primary text-white';
                case 'Package': return 'bg-success text-white';
                case 'HospitalService': return 'bg-info text-dark';
                case 'NonPayableItem': return 'bg-danger text-white';
                default: return 'bg-dark text-white';
            }
        }

        // 4. Update Summary KPIs
        function updateTariffsKPIs() {
            document.getElementById('statTotalTariffs').innerText = loadedTariffs.length;
            document.getElementById('statApprovedRates').innerText = loadedTariffs.filter(t => t.rate > 0).length;
            document.getElementById('statDeductionRules').innerText = loadedTariffs.filter(t => t.deductionValue > 0 || t.deductionRuleType.includes('Non-Payable')).length;
            document.getElementById('statActiveTariffs').innerText = loadedTariffs.filter(t => t.status).length;
        }

        // 5. Head Filter Tabs
        function filterTariffsByHead(head, el) {
            currentEntitlementFilter = head;
            document.querySelectorAll('#tariffHeadTabs .nav-link').forEach(l => l.classList.remove('active'));
            el.classList.add('active');
            renderTariffsTable();
        }

        function filterTariffTableRows() {
            renderTariffsTable();
        }

        // 6. Form Visibility & State
        function toggleTariffForm(show, isEdit = false) {
            const card = document.getElementById('tariffFormCard');
            const btn = document.getElementById('btnToggleTariffForm');

            if (show) {
                card.classList.remove('d-none');
                if (btn) btn.classList.add('d-none');
                if (!isEdit) {
                    resetTariffForm();
                }
                card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            } else {
                card.classList.add('d-none');
                if (btn) btn.classList.remove('d-none');
                resetTariffForm();
            }
        }

        function resetTariffForm() {
            document.getElementById('formInsTariffId').value = '0';
            document.getElementById('formInsuranceTPAId').value = currentInsuranceTPAId;
            document.getElementById('tariffFormCardTitle').innerHTML = '<i class="bi bi-plus-square-fill me-2"></i>New Insurance Tariff Rule';
            document.getElementById('formEntitlementType').value = 'Procedure';
            document.getElementById('formDeductionRuleType').value = 'Standard Tariff';
            document.getElementById('formDeductionValue').value = '0.00';
            document.getElementById('formRate').value = '';
            
            // Set today to 1 year
            const today = new Date().toISOString().split('T')[0];
            const nextYear = new Date();
            nextYear.setFullYear(nextYear.getFullYear() + 1);
            document.getElementById('formEffectiveFrom').value = today;
            document.getElementById('formEffectiveTo').value = nextYear.toISOString().split('T')[0];
            document.getElementById('formStatus').checked = true;

            onEntitlementTypeChange();
            onDeductionRuleChange();
        }

        // 7. Dynamic Entitlement Type selection -> load Master Items
        async function onEntitlementTypeChange(preSelectId = null) {
            const head = document.getElementById('formEntitlementType').value;
            const select = document.getElementById('formReferenceId');
            select.innerHTML = '<option value="">Loading services...</option>';

            if (!masterTariffItemsCache[head]) {
                try {
                    const res = await fetch(`/Insurances/GetTariffMasterItems?entitlementType=${encodeURIComponent(head)}`);
                    const json = await res.json();
                    if (json.success) {
                        masterTariffItemsCache[head] = json.data || [];
                    } else {
                        masterTariffItemsCache[head] = [];
                    }
                } catch {
                    masterTariffItemsCache[head] = [];
                }
            }

            const items = masterTariffItemsCache[head] || [];
            if (items.length === 0) {
                select.innerHTML = '<option value="">No items found for this head</option>';
                document.getElementById('tariffBaseRateDisplay').innerText = '₹0.00';
                return;
            }

            let optHtml = '<option value="">-- Select Service Item --</option>';
            items.forEach(it => {
                const sel = (preSelectId && it.reference_ID === preSelectId) ? 'selected' : '';
                optHtml += `<option value="${it.reference_ID}" data-rate="${it.baseRate}" ${sel}>${it.itemCode ? '[' + it.itemCode + '] ' : ''}${it.itemName} (₹${it.baseRate.toLocaleString('en-IN')})</option>`;
            });
            select.innerHTML = optHtml;

            onTariffItemSelectChange();
        }

        function onTariffItemSelectChange() {
            const select = document.getElementById('formReferenceId');
            const selectedOpt = select.options[select.selectedIndex];
            const baseRate = selectedOpt ? parseFloat(selectedOpt.getAttribute('data-rate') || '0') : 0;
            document.getElementById('tariffBaseRateDisplay').innerText = `₹${baseRate.toLocaleString('en-IN', { minimumFractionDigits: 2 })}`;

            // If empty rate, pre-fill with base rate
            const rateInput = document.getElementById('formRate');
            if (!rateInput.value && baseRate > 0) {
                rateInput.value = baseRate.toFixed(2);
            }
        }

        // 8. Deduction Rule Change
        function onDeductionRuleChange() {
            const rule = document.getElementById('formDeductionRuleType').value;
            const suffix = document.getElementById('deductionSuffix');
            const helpText = document.getElementById('deductionHelpText');
            const dedVal = document.getElementById('formDeductionValue');
            const rateInput = document.getElementById('formRate');

            if (rule.includes('Percentage') || rule.includes('Co-Pay') || rule.includes('Capping')) {
                suffix.innerText = '%';
                helpText.innerText = 'Co-pay or capping percentage value (e.g. 10%, 15%)';
            } else if (rule.includes('Non-Payable')) {
                suffix.innerText = '%';
                dedVal.value = '100.00';
                rateInput.value = '0.00';
                helpText.innerText = '100% patient deduction / non-payable item';
            } else if (rule.includes('Fixed') || rule.includes('Cap')) {
                suffix.innerText = '₹';
                helpText.innerText = 'Fixed deduction or capping threshold amount in ₹';
            } else {
                suffix.innerText = '—';
                dedVal.value = '0.00';
                helpText.innerText = 'No deduction applied / full standard coverage';
            }
        }

        // 9. Save Tariff Rule
        async function handleSaveInsuranceTariff(e) {
            e.preventDefault();

            const insTariffId = parseInt(document.getElementById('formInsTariffId').value) || 0;
            const refId = parseInt(document.getElementById('formReferenceId').value) || 0;
            const rateVal = parseFloat(document.getElementById('formRate').value) || 0;
            const dedVal = parseFloat(document.getElementById('formDeductionValue').value) || 0;
            const effFrom = document.getElementById('formEffectiveFrom').value;
            const effTo = document.getElementById('formEffectiveTo').value;

            if (!refId) {
                showTariffAlert('Please select a master service item.', 'danger');
                return;
            }

            if (effTo < effFrom) {
                showTariffAlert('Effective To date cannot be earlier than Effective From date.', 'danger');
                return;
            }

            const payload = {
                InsTariff_ID: insTariffId,
                InsuranceTPA_ID: currentInsuranceTPAId,
                EntitlementType: document.getElementById('formEntitlementType').value,
                Reference_ID: refId,
                DeductionRuleType: document.getElementById('formDeductionRuleType').value,
                DeductionValue: dedVal,
                Rate: rateVal,
                Effective_From: effFrom,
                Effective_To: effTo,
                Status: document.getElementById('formStatus').checked
            };

            const btn = document.getElementById('btnSaveTariff');
            const originalHtml = btn.innerHTML;
            btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Saving...';
            btn.disabled = true;

            try {
                const res = await fetch('/Insurances/SaveInsuranceTariff', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                const result = await res.json();

                if (result.success) {
                    showTariffAlert(result.message || 'Insurance tariff rule saved successfully!', 'success');
                    toggleTariffForm(false);
                    await loadInsuranceTariffs();
                } else {
                    showTariffAlert(result.message || 'Failed to save tariff rule.', 'danger');
                }
            } catch (err) {
                showTariffAlert('Error submitting request: ' + err.message, 'danger');
            } finally {
                btn.innerHTML = originalHtml;
                btn.disabled = false;
            }
        }

        // 10. Edit Tariff Rule
        async function editTariffRule(tariffId) {
            try {
                const res = await fetch(`/Insurances/GetInsuranceTariff?id=${tariffId}`);
                const result = await res.json();
                if (!result.success || !result.data) {
                    showTariffAlert('Failed to retrieve tariff rule details.', 'danger');
                    return;
                }

                const t = result.data;
                toggleTariffForm(true, true);

                document.getElementById('formInsTariffId').value = t.insTariff_ID;
                document.getElementById('formInsuranceTPAId').value = t.insuranceTPA_ID;
                document.getElementById('tariffFormCardTitle').innerHTML = `<i class="bi bi-pencil-square me-2"></i>Edit Tariff Rule [#${t.insTariff_ID}]`;
                document.getElementById('formEntitlementType').value = t.entitlementType;
                document.getElementById('formDeductionRuleType').value = t.deductionRuleType;
                document.getElementById('formDeductionValue').value = t.deductionValue;
                document.getElementById('formRate').value = t.rate;
                document.getElementById('formEffectiveFrom').value = t.effective_From.split('T')[0];
                document.getElementById('formEffectiveTo').value = t.effective_To.split('T')[0];
                document.getElementById('formStatus').checked = t.status;

                onDeductionRuleChange();
                await onEntitlementTypeChange(t.reference_ID);

                document.getElementById('tariffFormCard').scrollIntoView({ behavior: 'smooth' });
            } catch (err) {
                showTariffAlert('Error: ' + err.message, 'danger');
            }
        }

        // 11. Toggle Status
        async function handleToggleTariffStatus(tariffId) {
            try {
                const res = await fetch(`/Insurances/ToggleTariffStatus?id=${tariffId}`, { method: 'POST' });
                const result = await res.json();
                if (result.success) {
                    await loadInsuranceTariffs();
                } else {
                    showTariffAlert(result.message || 'Failed to toggle status.', 'danger');
                }
            } catch (err) {
                showTariffAlert('Error updating status: ' + err.message, 'danger');
            }
        }

        // 12. Delete Tariff Rule
        async function deleteTariffRule(tariffId) {
            if (!confirm('Are you sure you want to delete this Insurance Tariff rule?')) return;

            try {
                const res = await fetch(`/Insurances/DeleteInsuranceTariff?id=${tariffId}`, { method: 'POST' });
                const result = await res.json();
                if (result.success) {
                    showTariffAlert(result.message || 'Tariff rule deleted successfully.', 'success');
                    await loadInsuranceTariffs();
                } else {
                    showTariffAlert(result.message || 'Failed to delete tariff rule.', 'danger');
                }
            } catch (err) {
                showTariffAlert('Error deleting tariff rule: ' + err.message, 'danger');
            }
        }

        // Alert helper
        function showTariffAlert(msg, type = 'info') {
            const alertBox = document.getElementById('tariffModalAlert');
            alertBox.className = `alert alert-${type} py-2 px-3 mb-3 small`;
            alertBox.innerHTML = `<i class="bi ${type === 'success' ? 'bi-check-circle-fill' : 'bi-exclamation-triangle-fill'} me-2"></i>${msg}`;
            alertBox.classList.remove('d-none');
            setTimeout(() => { alertBox.classList.add('d-none'); }, 5000);
        }
    
