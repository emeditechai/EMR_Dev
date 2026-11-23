// moved from Views/Beds/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            const buildingSelect = document.getElementById('buildingSelect');
            const wardSelect = document.getElementById('wardSelect');
            const roomSelect = document.getElementById('roomSelect');

            const floorSelect = document.getElementById('floorSelect');
            const resetFloors = () => { floorSelect.innerHTML = '<option value="">-- Select Floor --</option>'; };
            const resetWards = () => { wardSelect.innerHTML = '<option value="">-- Select Ward --</option>'; };
            const resetRooms = () => { roomSelect.innerHTML = '<option value="">-- Select Room --</option>'; };

            buildingSelect.addEventListener('change', async function () {
                resetFloors(); resetWards(); resetRooms();
                if (!this.value) return;
                try {
                    const res = await fetch(`/Beds/GetFloorsByBuilding?buildingId=${this.value}`);
                    if (res.ok) (await res.json()).forEach(f => floorSelect.appendChild(new Option(`${f.floorName} (${f.floorCode})`, f.floorId)));
                } catch (err) { console.error('Error fetching floors:', err); }
            });

            floorSelect.addEventListener('change', async function () {
                resetWards(); resetRooms();
                if (!this.value) return;
                try {
                    const res = await fetch(`/Beds/GetWardsByFloor?floorId=${this.value}`);
                    if (res.ok) (await res.json()).forEach(w => wardSelect.appendChild(new Option(`${w.wardName} (${w.wardCode}) - ${w.wardType}`, w.wardId)));
                } catch (err) { console.error('Error fetching wards:', err); }
            });

            wardSelect.addEventListener('change', async function () {
                const wardId = this.value;
                roomSelect.innerHTML = '<option value="">-- Select Room --</option>';

                if (!wardId) return;

                try {
                    const res = await fetch(`/Beds/GetRoomsByWard?wardId=${wardId}`);
                    if (res.ok) {
                        const rooms = await res.json();
                        rooms.forEach(r => {
                            const opt = document.createElement('option');
                            opt.value = r.roomId;
                            opt.textContent = `Room ${r.roomNumber} (${r.roomType} - ${r.roomCategory})`;
                            roomSelect.appendChild(opt);
                        });
                    }
                } catch (err) {
                    console.error('Error fetching rooms:', err);
                }
            });
        });
    
