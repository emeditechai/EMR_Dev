// moved from Views/BedRoomTariffs/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            const wardSelect = document.getElementById('wardSelect');
            const roomSelect = document.getElementById('roomSelect');

            // Cascading Ward -> Room
            wardSelect.addEventListener('change', async function () {
                const wardId = this.value;
                roomSelect.innerHTML = '<option value="">-- Select Room --</option>';
                if (!wardId) return;

                try {
                    const res = await fetch(`/BedRoomTariffs/GetRoomsByWard?wardId=${wardId}`);
                    if (res.ok) {
                        const rooms = await res.json();
                        rooms.forEach(r => {
                            const opt = document.createElement('option');
                            opt.value = r.value;
                            opt.textContent = r.text;
                            roomSelect.appendChild(opt);
                        });
                    }
                } catch (err) {
                    console.error('Error fetching rooms:', err);
                }
            });

            // Live Rate Calculation
            const rateInputs = document.querySelectorAll('.rate-input');
            const roomInput = document.getElementById('RoomCharge');
            const bedInput = document.getElementById('BedCharge');
            const nursingInput = document.getElementById('NursingCharge');
            const attendantInput = document.getElementById('AttendantCharge');
            const isolationInput = document.getElementById('IsolationCharge');
            const gstInput = document.getElementById('GstPercentage');

            const dispBase = document.getElementById('dispBase');
            const dispGstPercent = document.getElementById('dispGstPercent');
            const dispGstAmount = document.getElementById('dispGstAmount');
            const dispGross = document.getElementById('dispGross');

            function recalculate() {
                const r = parseFloat(roomInput.value) || 0;
                const b = parseFloat(bedInput.value) || 0;
                const n = parseFloat(nursingInput.value) || 0;
                const a = parseFloat(attendantInput.value) || 0;
                const iso = parseFloat(isolationInput.value) || 0;
                const gst = parseFloat(gstInput.value) || 0;

                const base = r + b + n + a + iso;
                const gstAmt = (base * (gst / 100.0));
                const gross = base + gstAmt;

                dispBase.textContent = '₹' + base.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
                dispGstPercent.textContent = gst.toString();
                dispGstAmount.textContent = '+₹' + gstAmt.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
                dispGross.textContent = '₹' + gross.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
            }

            rateInputs.forEach(input => {
                input.addEventListener('input', recalculate);
            });

            recalculate();
        });
    
