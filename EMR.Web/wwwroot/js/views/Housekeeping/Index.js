// moved from Views/Housekeeping/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        let physicalItemsCache = [];

        // ── Location Modal Helpers ───────────────────────────────────────────
        function openLocationModal() {
            document.getElementById('formLocation').reset();
            document.getElementById('loc_Location_ID').value = '0';
            document.getElementById('loc_Status').checked = true;
            document.getElementById('modalLocationLabel').innerHTML = '<i class="bi bi-geo-alt me-2"></i>Add Housekeeping Location';
            onLocationTypeChanged();
            new bootstrap.Modal(document.getElementById('modalLocation')).show();
        }

        async function editLocation(id) {
            try {
                const res = await fetch(`/Housekeeping/GetLocation?id=${id}`);
                if (!res.ok) throw new Error("Failed to load location.");
                const data = await res.json();

                document.getElementById('loc_Location_ID').value = data.location_ID;
                document.getElementById('loc_LocationType').value = data.locationType;
                document.getElementById('loc_LocationCode').value = data.locationCode;
                document.getElementById('loc_LocationName').value = data.locationName;
                document.getElementById('loc_RiskLevel').value = data.riskLevel;
                document.getElementById('loc_Building_ID').value = data.building_ID || '';
                document.getElementById('loc_Floor_ID').value = data.floor_ID || '';
                document.getElementById('loc_Status').checked = data.status;

                document.getElementById('modalLocationLabel').innerHTML = `<i class="bi bi-geo-alt me-2"></i>Edit Location: ${data.locationName}`;

                await onLocationTypeChanged(data.reference_ID);

                new bootstrap.Modal(document.getElementById('modalLocation')).show();
            } catch (err) {
                alert(err.message);
            }
        }

        async function onLocationTypeChanged(selectedRefId = 0) {
            const locType = document.getElementById('loc_LocationType').value;
            const refSelect = document.getElementById('loc_Reference_ID');
            refSelect.innerHTML = '<option value="0">Loading...</option>';

            try {
                const res = await fetch(`/Housekeeping/GetPhysicalMasterItems?locationType=${encodeURIComponent(locType)}`);
                const items = await res.json();
                physicalItemsCache = items;

                refSelect.innerHTML = '<option value="0">-- Select Physical Entity / General --</option>';
                items.forEach(it => {
                    const opt = document.createElement('option');
                    opt.value = it.reference_ID;
                    opt.textContent = it.itemName;
                    if (selectedRefId && it.reference_ID === selectedRefId) {
                        opt.selected = true;
                    }
                    refSelect.appendChild(opt);
                });
            } catch {
                refSelect.innerHTML = '<option value="0">-- Select Physical Entity --</option>';
            }
        }

        function onPhysicalReferenceChanged() {
            const refId = parseInt(document.getElementById('loc_Reference_ID').value);
            if (!refId) return;

            const it = physicalItemsCache.find(x => x.reference_ID === refId);
            if (it) {
                if (it.floor_ID) document.getElementById('loc_Floor_ID').value = it.floor_ID;
                if (it.building_ID) document.getElementById('loc_Building_ID').value = it.building_ID;
                if (!document.getElementById('loc_LocationName').value) {
                    document.getElementById('loc_LocationName').value = it.itemName;
                }
            }
        }

        // ── Cleaning Modal Helpers ───────────────────────────────────────────
        function openCleaningModal() {
            document.getElementById('formCleaning').reset();
            document.getElementById('cln_Cleaning_ID').value = '0';
            document.getElementById('cln_Status').checked = true;
            document.getElementById('cln_SLA_Minutes').value = '30';
            document.getElementById('modalCleaningLabel').innerHTML = '<i class="bi bi-brush me-2"></i>Add Cleaning Protocol';
            new bootstrap.Modal(document.getElementById('modalCleaning')).show();
        }

        async function editCleaning(id) {
            try {
                const res = await fetch(`/Housekeeping/GetCleaning?id=${id}`);
                if (!res.ok) throw new Error("Failed to load cleaning protocol.");
                const data = await res.json();

                document.getElementById('cln_Cleaning_ID').value = data.cleaning_ID;
                document.getElementById('cln_CleaningType').value = data.cleaningType;
                document.getElementById('cln_Frequency').value = data.frequency;
                document.getElementById('cln_ChemicalUsed').value = data.chemicalUsed;
                document.getElementById('cln_EquipmentUsed').value = data.equipmentUsed;
                document.getElementById('cln_SLA_Minutes').value = data.slA_Minutes;
                document.getElementById('cln_ChecklistTemplate_ID').value = data.checklistTemplate_ID || '';
                document.getElementById('cln_Status').checked = data.status;

                document.getElementById('modalCleaningLabel').innerHTML = `<i class="bi bi-brush me-2"></i>Edit Protocol: ${data.cleaningType}`;
                new bootstrap.Modal(document.getElementById('modalCleaning')).show();
            } catch (err) {
                alert(err.message);
            }
        }

        // ── Staff Modal Helpers ──────────────────────────────────────────────
        function openStaffModal() {
            document.getElementById('formStaff').reset();
            document.getElementById('stf_HKStaff_ID').value = '0';
            document.getElementById('stf_Status').checked = true;
            document.getElementById('modalStaffLabel').innerHTML = '<i class="bi bi-people me-2"></i>Deploy Staff Member';
            new bootstrap.Modal(document.getElementById('modalStaff')).show();
        }

        async function editStaff(id) {
            try {
                const res = await fetch(`/Housekeeping/GetStaff?id=${id}`);
                if (!res.ok) throw new Error("Failed to load staff allocation.");
                const data = await res.json();

                document.getElementById('stf_HKStaff_ID').value = data.hKStaff_ID;
                document.getElementById('stf_Staff_ID').value = data.staff_ID;
                document.getElementById('stf_ShiftMaster_ID').value = data.shiftMaster_ID;
                document.getElementById('stf_AreaAllocation_ID').value = data.areaAllocation_ID;
                document.getElementById('stf_Supervisor_ID').value = data.supervisor_ID || '';
                document.getElementById('stf_Status').checked = data.status;

                document.getElementById('modalStaffLabel').innerHTML = `<i class="bi bi-people me-2"></i>Edit Allocation: ${data.staffName}`;
                new bootstrap.Modal(document.getElementById('modalStaff')).show();
            } catch (err) {
                alert(err.message);
            }
        }
    
