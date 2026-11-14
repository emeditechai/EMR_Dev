// moved from Views/Rooms/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            const buildingSelect = document.getElementById('buildingSelect');
            const floorSelect = document.getElementById('floorSelect');
            const wardSelect = document.getElementById('wardSelect');

            buildingSelect.addEventListener('change', async function () {
                const buildingId = this.value;
                floorSelect.innerHTML = '<option value="">-- Select Floor --</option>';
                wardSelect.innerHTML = '<option value="">-- Select Ward --</option>';

                if (!buildingId) return;

                try {
                    const res = await fetch(`/Rooms/GetFloorsByBuilding?buildingId=${buildingId}`);
                    if (res.ok) {
                        const floors = await res.json();
                        floors.forEach(f => {
                            const opt = document.createElement('option');
                            opt.value = f.floorId;
                            opt.textContent = `${f.floorName} (${f.floorCode})`;
                            floorSelect.appendChild(opt);
                        });
                    }
                } catch (err) {
                    console.error('Error fetching floors:', err);
                }
            });

            floorSelect.addEventListener('change', async function () {
                const floorId = this.value;
                wardSelect.innerHTML = '<option value="">-- Select Ward --</option>';

                if (!floorId) return;

                try {
                    const res = await fetch(`/Rooms/GetWardsByFloor?floorId=${floorId}`);
                    if (res.ok) {
                        const wards = await res.json();
                        wards.forEach(w => {
                            const opt = document.createElement('option');
                            opt.value = w.wardId;
                            opt.textContent = `${w.wardName} (${w.wardCode}) - ${w.wardType}`;
                            wardSelect.appendChild(opt);
                        });
                    }
                } catch (err) {
                    console.error('Error fetching wards:', err);
                }
            });
        });
    
