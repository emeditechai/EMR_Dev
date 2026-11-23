// moved from Views/Corporates/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        let currentCorporateId = 0;
        let currentCorporateName = '';
        let currentCorporateCode = '';
        let masterItemsCache = {};
        let loadedRates = [];
        let currentHeadFilter = 'ALL';

        // 1. Open Corporate Rates Modal
        function openCorporateRatesModal(corporateId, corporateName, corporateCode) {
            currentCorporateId = corporateId;
            currentCorporateName = corporateName;
            currentCorporateCode = corporateCode;

            document.getElementById('corporateRatesModalLabel').innerHTML = 
                `Corporate Rates: <span class="text-warning">${corporateName}</span>`;
            document.getElementById('modalCorpSubtitle').innerText = 
                `Corporate Code: ${corporateCode || '—'} | Scoped Rates & Discounts`;

            toggleRateForm(false);
            loadCorporateRates();

            const modal = new bootstrap.Modal(document.getElementById('corporateRatesModal'));
            modal.show();
        }

        // 2. Load Rates for Current Corporate via AJAX
        async function loadCorporateRates() {
            const tbody = document.getElementById('ratesTableBody');
            tbody.innerHTML = `
                <tr>
                    <td colspan="9" class="text-center py-4 text-muted">
                        <div class="spinner-border spinner-border-sm text-primary me-2" role="status"></div>
                        Loading agreed rates...
                    </td>
                </tr>`;

            try {
                const response = await fetch(`/Corporates/GetCorporateRates?corporateId=${currentCorporateId}`);
                const result = await response.json();

                if (result.success) {
                    loadedRates = result.data || [];
                    renderRatesTable();
                    updateRatesKPIs();
                    // Update count badge on parent table
                    const badge = document.getElementById(`badge-rate-count-${currentCorporateId}`);
                    if (badge) badge.innerText = loadedRates.length;
                } else {
                    tbody.innerHTML = `<tr><td colspan="9" class="text-center text-danger py-3">${result.message || 'Failed to load rates.'}</td></tr>`;
                }
            } catch (err) {
                tbody.innerHTML = `<tr><td colspan="9" class="text-center text-danger py-3">Error connecting to server.</td></tr>`;
            }
        }

        // 3. Render Rates Table with Filters
        function renderRatesTable() {
            const tbody = document.getElementById('ratesTableBody');
            const search = (document.getElementById('rateSearchInput').value || '').toLowerCase();

            const filtered = loadedRates.filter(r => {
                const matchHead = (currentHeadFilter === 'ALL' || r.rateServiceType.toLowerCase() === currentHeadFilter.toLowerCase());
                const matchSearch = !search || 
                    (r.itemName && r.itemName.toLowerCase().includes(search)) ||
                    (r.itemCode && r.itemCode.toLowerCase().includes(search)) ||
                    (r.rateServiceType && r.rateServiceType.toLowerCase().includes(search)) ||
                    (r.rateType && r.rateType.toLowerCase().includes(search));
                return matchHead && matchSearch;
            });

            if (filtered.length === 0) {
                tbody.innerHTML = `
                    <tr>
                        <td colspan="9" class="text-center py-5 text-muted">
                            <i class="bi bi-tag fs-2 d-block mb-1 opacity-50"></i>
                            No rate rules configured for this filter. Click <strong>"Add Rate Rule"</strong> to create one.
                        </td>
                    </tr>`;
                return;
            }

            let html = '';
            filtered.forEach((r, idx) => {
                const headBadgeClass = getHeadBadgeClass(r.rateServiceType);
                const rateTypeBadgeClass = r.rateType === 'Percentage' ? 'bg-info text-dark' : (r.rateType === 'Rate' ? 'bg-success text-white' : 'bg-primary text-white');
                const fromDate = new Date(r.effective_From).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
                const toDate = new Date(r.effective_To).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
                const isExpired = new Date(r.effective_To) < new Date();

                // Format Agreed Value
                let agreedValueHtml = '';
                if (r.rateType === 'Percentage') {
                    agreedValueHtml = `<span class="badge bg-info bg-opacity-10 text-info border border-info fw-bold fs-7">${r.discountPercent || 0}% OFF</span>`;
                } else if (r.rateType === 'Rate') {
                    agreedValueHtml = `<span class="fw-bold text-success fs-7">₹${(r.rate || 0).toLocaleString('en-IN', { minimumFractionDigits: 2 })}</span>`;
                } else {
                    agreedValueHtml = `
                        <div class="fw-bold text-success fs-7">₹${(r.rate || 0).toLocaleString('en-IN', { minimumFractionDigits: 2 })}</div>
                        <small class="text-info fw-semibold">(${r.discountPercent || 0}% Disc)</small>`;
                }

                html += `
                    <tr>
                        <td class="text-muted small">${idx + 1}</td>
                        <td>
                            <span class="badge ${headBadgeClass}">${r.rateServiceType}</span>
                        </td>
                        <td>
                            <div class="fw-semibold text-dark">${r.itemName || 'Service Item #' + r.referenceMaster_ID}</div>
                            <span class="badge bg-light text-dark border font-monospace extra-small">${r.itemCode || '—'}</span>
                        </td>
                        <td>
                            <span class="text-muted small">₹${(r.standardBaseRate || 0).toLocaleString('en-IN', { minimumFractionDigits: 2 })}</span>
                        </td>
                        <td>
                            <span class="badge ${rateTypeBadgeClass}">${r.rateType}</span>
                        </td>
                        <td>
                            ${agreedValueHtml}
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
                                <input data-permission="MASTER.CORPORATES:RATES" class="form-check-input" type="checkbox" role="switch" ${r.status ? 'checked' : ''} 
                                       onchange="handleToggleRateStatus(${r.corpRate_ID})" title="${r.status ? 'Deactivate' : 'Activate'}" />
                            </div>
                        </td>
                        <td class="text-end">
                            <button type="button" class="btn btn-sm btn-outline-primary me-1" onclick="editRateRule(${r.corpRate_ID})" title="Edit Rate Rule">
                                <i class="bi bi-pencil"></i>
                            </button>
                            <button type="button" class="btn btn-sm btn-outline-danger" data-permission="MASTER.CORPORATES:RATES" onclick="deleteRateRule(${r.corpRate_ID})" title="Delete Rate Rule">
                                <i class="bi bi-trash"></i>
                            </button>
                        </td>
                    </tr>`;
            });

            tbody.innerHTML = html;
        }

        function getHeadBadgeClass(head) {
            switch (head) {
                case 'Room': return 'bg-secondary text-white';
                case 'Procedure': return 'bg-primary text-white';
                case 'OT': return 'bg-warning text-dark';
                case 'ICU': return 'bg-danger text-white';
                case 'HospitalService': return 'bg-info text-dark';
                case 'Package': return 'bg-success text-white';
                default: return 'bg-dark text-white';
            }
        }

        // 4. Update Summary KPIs
        function updateRatesKPIs() {
            document.getElementById('statTotalRates').innerText = loadedRates.length;
            document.getElementById('statDiscountRates').innerText = loadedRates.filter(r => r.rateType === 'Percentage' || r.rateType === 'Both').length;
            document.getElementById('statFixedRates').innerText = loadedRates.filter(r => r.rateType === 'Rate' || r.rateType === 'Both').length;
            document.getElementById('statActiveRates').innerText = loadedRates.filter(r => r.status).length;
        }

        // 5. Head Filter Tabs
        function filterRatesByHead(head, el) {
            currentHeadFilter = head;
            document.querySelectorAll('#rateHeadTabs .nav-link').forEach(l => l.classList.remove('active'));
            el.classList.add('active');
            renderRatesTable();
        }

        function filterRateTableRows() {
            renderRatesTable();
        }

        // 6. Form Visibility & State
        function toggleRateForm(show, isEdit = false) {
            const card = document.getElementById('rateFormCard');
            const btn = document.getElementById('btnToggleRateForm');

            if (show) {
                card.classList.remove('d-none');
                btn.classList.add('d-none');
                if (!isEdit) {
                    resetRateForm();
                }
            } else {
                card.classList.add('d-none');
                btn.classList.remove('d-none');
                resetRateForm();
            }
        }

        function resetRateForm() {
            document.getElementById('formCorpRateId').value = '0';
            document.getElementById('formCorporateId').value = currentCorporateId;
            document.getElementById('formCardTitle').innerHTML = '<i class="bi bi-plus-square-fill me-2"></i>New Corporate Hospital Rate Rule';
            document.getElementById('formRateServiceType').value = 'Procedure';
            document.getElementById('formRateType').value = 'Percentage';
            document.getElementById('formRate').value = '';
            document.getElementById('formDiscountPercent').value = '';
            
            // Set today to 1 year
            const today = new Date().toISOString().split('T')[0];
            const nextYear = new Date();
            nextYear.setFullYear(nextYear.getFullYear() + 1);
            document.getElementById('formEffectiveFrom').value = today;
            document.getElementById('formEffectiveTo').value = nextYear.toISOString().split('T')[0];
            document.getElementById('formStatus').checked = true;

            onRateServiceTypeChange();
            onRateTypeChange();
        }

        // 7. Dynamic Service Head selection -> load Master Items
        async function onRateServiceTypeChange(preSelectId = null) {
            const head = document.getElementById('formRateServiceType').value;
            const select = document.getElementById('formReferenceMasterId');
            select.innerHTML = '<option value="">Loading services...</option>';

            if (!masterItemsCache[head]) {
                try {
                    const res = await fetch(`/Corporates/GetMasterServiceItems?serviceType=${encodeURIComponent(head)}`);
                    const json = await res.json();
                    if (json.success) {
                        masterItemsCache[head] = json.data || [];
                    } else {
                        masterItemsCache[head] = [];
                    }
                } catch {
                    masterItemsCache[head] = [];
                }
            }

            const items = masterItemsCache[head] || [];
            if (items.length === 0) {
                select.innerHTML = '<option value="">No items found for this head</option>';
                document.getElementById('baseRateDisplay').innerText = '₹0.00';
                return;
            }

            let optHtml = '<option value="">-- Select Service Item --</option>';
            items.forEach(it => {
                const sel = (preSelectId && it.referenceMaster_ID === preSelectId) ? 'selected' : '';
                optHtml += `<option value="${it.referenceMaster_ID}" data-rate="${it.baseRate}" ${sel}>${it.itemCode ? '[' + it.itemCode + '] ' : ''}${it.itemName} (₹${it.baseRate.toLocaleString('en-IN')})</option>`;
            });
            select.innerHTML = optHtml;

            onMasterItemSelectChange();
        }

        function onMasterItemSelectChange() {
            const select = document.getElementById('formReferenceMasterId');
            const selectedOpt = select.options[select.selectedIndex];
            const baseRate = selectedOpt ? parseFloat(selectedOpt.getAttribute('data-rate') || '0') : 0;
            document.getElementById('baseRateDisplay').innerText = `₹${baseRate.toLocaleString('en-IN', { minimumFractionDigits: 2 })}`;
        }

        // 8. Rate Type Change (Percentage vs Rate vs Both)
        function onRateTypeChange() {
            const type = document.getElementById('formRateType').value;
            const colRate = document.getElementById('colRateInput');
            const colDisc = document.getElementById('colDiscountPercentInput');
            const rateInput = document.getElementById('formRate');
            const discInput = document.getElementById('formDiscountPercent');

            if (type === 'Rate') {
                colRate.classList.remove('d-none');
                colDisc.classList.add('d-none');
                rateInput.required = true;
                discInput.required = false;
                discInput.value = '';
            } else if (type === 'Percentage') {
                colRate.classList.add('d-none');
                colDisc.classList.remove('d-none');
                rateInput.required = false;
                discInput.required = true;
                rateInput.value = '';
            } else { // Both
                colRate.classList.remove('d-none');
                colDisc.classList.remove('d-none');
                rateInput.required = true;
                discInput.required = true;
            }
        }

        // 9. Save Rate Rule (Create / Update)
        async function handleSaveCorporateRate(e) {
            e.preventDefault();

            const corpRateId = parseInt(document.getElementById('formCorpRateId').value) || 0;
            const refMasterId = parseInt(document.getElementById('formReferenceMasterId').value) || 0;
            const rateType = document.getElementById('formRateType').value;
            const rateVal = document.getElementById('formRate').value ? parseFloat(document.getElementById('formRate').value) : null;
            const discVal = document.getElementById('formDiscountPercent').value ? parseFloat(document.getElementById('formDiscountPercent').value) : null;
            const effFrom = document.getElementById('formEffectiveFrom').value;
            const effTo = document.getElementById('formEffectiveTo').value;

            if (!refMasterId) {
                showAlert('Please select a master service item.', 'danger');
                return;
            }

            if (effTo < effFrom) {
                showAlert('Effective To date cannot be earlier than Effective From date.', 'danger');
                return;
            }

            const payload = {
                CorpRate_ID: corpRateId,
                Corporate_ID: currentCorporateId,
                RateServiceType: document.getElementById('formRateServiceType').value,
                ReferenceMaster_ID: refMasterId,
                RateType: rateType,
                Rate: rateVal,
                DiscountPercent: discVal,
                Effective_From: effFrom,
                Effective_To: effTo,
                Status: document.getElementById('formStatus').checked
            };

            const btn = document.getElementById('btnSaveRate');
            const originalHtml = btn.innerHTML;
            btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Saving...';
            btn.disabled = true;

            try {
                const res = await fetch('/Corporates/SaveCorporateRate', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                const result = await res.json();

                if (result.success) {
                    showAlert(result.message || 'Corporate rate rule saved successfully!', 'success');
                    toggleRateForm(false);
                    await loadCorporateRates();
                } else {
                    showAlert(result.message || 'Failed to save rate rule.', 'danger');
                }
            } catch (err) {
                showAlert('Error submitting request: ' + err.message, 'danger');
            } finally {
                btn.innerHTML = originalHtml;
                btn.disabled = false;
            }
        }

        // 10. Edit Rate Rule
        async function editRateRule(rateId) {
            try {
                const res = await fetch(`/Corporates/GetCorporateRate?id=${rateId}`);
                const result = await res.json();
                if (!result.success || !result.data) {
                    showAlert('Failed to retrieve rate rule details.', 'danger');
                    return;
                }

                const r = result.data;
                toggleRateForm(true, true);

                document.getElementById('formCorpRateId').value = r.corpRate_ID;
                document.getElementById('formCorporateId').value = r.corporate_ID;
                document.getElementById('formCardTitle').innerHTML = `<i class="bi bi-pencil-square me-2"></i>Edit Rate Rule [#${r.corpRate_ID}]`;
                document.getElementById('formRateServiceType').value = r.rateServiceType;
                document.getElementById('formRateType').value = r.rateType;
                document.getElementById('formRate').value = r.rate != null ? r.rate : '';
                document.getElementById('formDiscountPercent').value = r.discountPercent != null ? r.discountPercent : '';
                document.getElementById('formEffectiveFrom').value = r.effective_From.split('T')[0];
                document.getElementById('formEffectiveTo').value = r.effective_To.split('T')[0];
                document.getElementById('formStatus').checked = r.status;

                onRateTypeChange();
                await onRateServiceTypeChange(r.referenceMaster_ID);

                // Scroll smoothly to form
                document.getElementById('rateFormCard').scrollIntoView({ behavior: 'smooth' });
            } catch (err) {
                showAlert('Error: ' + err.message, 'danger');
            }
        }

        // 11. Toggle Status
        async function handleToggleRateStatus(rateId) {
            try {
                const res = await fetch(`/Corporates/ToggleRateStatus?id=${rateId}`, { method: 'POST' });
                const result = await res.json();
                if (result.success) {
                    await loadCorporateRates();
                } else {
                    showAlert(result.message || 'Failed to toggle status.', 'danger');
                }
            } catch (err) {
                showAlert('Error updating status: ' + err.message, 'danger');
            }
        }

        // 12. Delete Rate Rule
        async function deleteRateRule(rateId) {
            if (!confirm('Are you sure you want to delete this Corporate Rate rule?')) return;

            try {
                const res = await fetch(`/Corporates/DeleteCorporateRate?id=${rateId}`, { method: 'POST' });
                const result = await res.json();
                if (result.success) {
                    showAlert(result.message || 'Rate rule deleted successfully.', 'success');
                    await loadCorporateRates();
                } else {
                    showAlert(result.message || 'Failed to delete rate rule.', 'danger');
                }
            } catch (err) {
                showAlert('Error deleting rate rule: ' + err.message, 'danger');
            }
        }

        // Alert helper
        function showAlert(msg, type = 'info') {
            const alertBox = document.getElementById('rateModalAlert');
            alertBox.className = `alert alert-${type} py-2 px-3 mb-3 small`;
            alertBox.innerHTML = `<i class="bi ${type === 'success' ? 'bi-check-circle-fill' : 'bi-exclamation-triangle-fill'} me-2"></i>${msg}`;
            alertBox.classList.remove('d-none');
            setTimeout(() => { alertBox.classList.add('d-none'); }, 5000);
        }
    
