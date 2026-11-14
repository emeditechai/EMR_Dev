// moved from Views/Doctors/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
(function () {
    'use strict';

    let currentDoctorId = 0;
    let allServices     = [];
    let selectedService = null;

    function antiForgeryToken() {
        return document.querySelector('input[name="__RequestVerificationToken"]')?.value ?? '';
    }

    // ── View-all fees ──────────────────────────────────────────────
    window.showAllFees = function (btn) {
        const doctorName = btn.dataset.doctor;
        const fees = JSON.parse(btn.dataset.fees);
        document.getElementById('vfDoctorName').textContent = doctorName;
        const list = document.getElementById('vfFeesList');
        list.innerHTML = fees.map(f =>
            `<span class="badge text-bg-info fs-6 px-3 py-2">${f}</span>`
        ).join('');
        bootstrap.Modal.getOrCreateInstance(document.getElementById('viewFeesModal')).show();
    };

    const modalEl       = document.getElementById('consultingFeeModal');
    const bsModal       = new bootstrap.Modal(modalEl);
    const nameEl        = document.getElementById('cfDoctorName');
    const searchInput   = document.getElementById('cfSearchInput');
    const suggestions   = document.getElementById('cfSuggestions');
    const addBtn        = document.getElementById('cfAddBtn');
    const selectedPrev  = document.getElementById('cfSelectedPreview');
    const selectedLabel = document.getElementById('cfSelectedLabel');
    const noServices    = document.getElementById('cfNoServices');
    const loadingMsg    = document.getElementById('cfLoadingMsg');
    const cfTable       = document.getElementById('cfTable');
    const cfTableBody   = document.getElementById('cfTableBody');
    const emptyMsg      = document.getElementById('cfEmptyMsg');

    window.openConsultingModal = async function (doctorId, doctorName) {
        currentDoctorId   = doctorId;
        selectedService   = null;
        nameEl.textContent = doctorName;
        searchInput.value  = '';
        suggestions.style.display = 'none';
        suggestions.innerHTML = '';
        selectedPrev.classList.add('d-none');
        noServices.classList.add('d-none');
        addBtn.disabled = true;
        bsModal.show();
        await loadServices();
        await loadFees();
    };

    async function loadServices() {
        try {
            const res = await fetch('/Doctors/GetConsultingServices');
            allServices = await res.json();
            if (allServices.length === 0) noServices.classList.remove('d-none');
        } catch { noServices.classList.remove('d-none'); }
    }

    async function loadFees() {
        loadingMsg.classList.remove('d-none');
        cfTable.classList.add('d-none');
        emptyMsg.classList.add('d-none');
        const res  = await fetch('/Doctors/GetDoctorFees?doctorId=' + currentDoctorId);
        const fees = await res.json();
        renderFees(fees);
    }

    function renderFees(fees) {
        loadingMsg.classList.add('d-none');
        cfTableBody.innerHTML = '';
        if (!fees || fees.length === 0) {
            cfTable.classList.add('d-none');
            emptyMsg.classList.remove('d-none');
            return;
        }
        emptyMsg.classList.add('d-none');
        cfTable.classList.remove('d-none');
        fees.forEach(f => {
            const tr = document.createElement('tr');
            let graceTimeHtml = '<span class="text-muted small fst-italic">N/A</span>';
            if (f.consultingType === 'Video') {
                const val = f.graceTime !== null ? f.graceTime : '';
                graceTimeHtml = '<input type="number" class="form-control form-control-sm text-center mx-auto" style="width: 80px;" min="0" value="' + val + '" onchange="window.updateGraceTime(' + f.mappingId + ', this.value)" placeholder="--" />';
            }
            tr.innerHTML =
                '<td><span class="badge text-bg-light border font-monospace text-dark">' + f.itemCode + '</span></td>' +
                '<td class="fw-semibold">' + f.itemName + '</td>' +
                '<td class="text-end fw-semibold text-success">₹' + Number(f.itemCharges).toFixed(2) + '</td>' +
                '<td class="text-center">' + graceTimeHtml + '</td>' +
                '<td class="text-center"><button class="btn btn-sm btn-outline-danger" data-permission="MASTER.DOCTORS:CONSULTING_CHARGES" onclick="window.removeFee(' + f.mappingId + ')" title="Remove"><i class="bi bi-trash3"></i></button></td>';
            cfTableBody.appendChild(tr);
        });
    }

    window.updateGraceTime = async function(mappingId, val) {
        const graceTime = val ? parseInt(val) : null;
        try {
            await fetch('/Doctors/UpdateGraceTime', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': antiForgeryToken() },
                body: JSON.stringify({ mappingId: mappingId, doctorId: currentDoctorId, graceTime: graceTime })
            });
        } catch (e) {
            console.error('Failed to update grace time', e);
        }
    };

    searchInput.addEventListener('input', function () {
        const q = this.value.trim().toLowerCase();
        selectedService = null;
        addBtn.disabled = true;
        selectedPrev.classList.add('d-none');
        if (!q) { suggestions.style.display = 'none'; return; }
        const matches = allServices.filter(s =>
            s.itemCode.toLowerCase().includes(q) || s.itemName.toLowerCase().includes(q));
        if (!matches.length) {
            suggestions.innerHTML = '<div class="list-group-item text-muted fst-italic">No matches found</div>';
            suggestions.style.display = 'block';
            return;
        }
        suggestions.innerHTML = matches.map(s =>
            '<button type="button" class="list-group-item list-group-item-action d-flex justify-content-between align-items-center" data-id="' + s.serviceId + '">' +
            '<span><span class="badge text-bg-light border font-monospace text-dark me-2">' + s.itemCode + '</span>' + s.itemName + '</span>' +
            '<span class="text-success fw-semibold">₹' + Number(s.itemCharges).toFixed(2) + '</span>' +
            '</button>'
        ).join('');
        suggestions.style.display = 'block';
    });

    suggestions.addEventListener('click', function (e) {
        const btn = e.target.closest('[data-id]');
        if (!btn) return;
        const svc = allServices.find(s => s.serviceId == btn.dataset.id);
        if (!svc) return;
        selectedService = svc;
        searchInput.value = svc.itemCode + ' — ' + svc.itemName;
        suggestions.style.display = 'none';
        selectedLabel.textContent = svc.itemCode + ' — ' + svc.itemName + ' (₹' + Number(svc.itemCharges).toFixed(2) + ')';
        selectedPrev.classList.remove('d-none');
        
        if (svc.consultingType === 'Video') {
            document.getElementById('cfGraceTimeWrapper').classList.remove('d-none');
            document.getElementById('cfGraceTimeInput').value = '';
        } else {
            document.getElementById('cfGraceTimeWrapper').classList.add('d-none');
            document.getElementById('cfGraceTimeInput').value = '';
        }
        
        addBtn.disabled = false;
    });

    document.addEventListener('click', function (e) {
        if (!suggestions.contains(e.target) && e.target !== searchInput)
            suggestions.style.display = 'none';
    });

    addBtn.addEventListener('click', async function () {
        if (!selectedService) return;
        
        let graceTime = null;
        if (selectedService.consultingType === 'Video') {
            const val = document.getElementById('cfGraceTimeInput').value;
            if (val) graceTime = parseInt(val);
        }

        addBtn.disabled = true;
        addBtn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Adding…';
        try {
            const res  = await fetch('/Doctors/AddConsultingFee', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': antiForgeryToken() },
                body: JSON.stringify({ doctorId: currentDoctorId, serviceId: selectedService.serviceId, graceTime: graceTime })
            });
            const data = await res.json();
            if (data.success) {
                renderFees(data.fees);
                searchInput.value = '';
                selectedService   = null;
                selectedPrev.classList.add('d-none');
                document.getElementById('cfGraceTimeWrapper').classList.add('d-none');
                document.getElementById('cfGraceTimeInput').value = '';
                refreshRowFees(currentDoctorId, data.fees);
            }
        } finally {
            addBtn.innerHTML = '<i class="bi bi-plus-lg me-1"></i>Add';
            addBtn.disabled  = true;
        }
    });

    window.removeFee = async function (mappingId) {
        const result = await Swal.fire({
            title: 'Remove Fee?',
            text: 'Remove this consulting fee from the doctor?',
            icon: 'warning',
            showCancelButton: true,
            confirmButtonColor: '#dc3545',
            cancelButtonColor: '#6c757d',
            confirmButtonText: 'Yes, remove it',
            cancelButtonText: 'Cancel'
        });
        if (!result.isConfirmed) return;
        const res  = await fetch('/Doctors/RemoveConsultingFee', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': antiForgeryToken() },
            body: JSON.stringify({ mappingId: mappingId, doctorId: currentDoctorId })
        });
        const data = await res.json();
        if (data.success) {
            renderFees(data.fees);
            refreshRowFees(currentDoctorId, data.fees);
        }
    };

    function refreshRowFees(doctorId, fees) {
        const btn = document.querySelector('button[onclick*="openConsultingModal(' + doctorId + ',"]');
        if (!btn) return;
        const row = btn.closest('tr');
        if (!row) return;
        const td = row.querySelectorAll('td')[4];
        if (!td) return;
        if (!fees || fees.length === 0) {
            td.innerHTML = '<span class="text-muted small fst-italic">None</span>';
        } else {
            td.innerHTML = fees.map(f =>
                '<span class="badge text-bg-info text-white me-1 mb-1">' + f.itemName + ' (₹' + Number(f.itemCharges).toFixed(0) + ')</span>'
            ).join('');
        }
    }

    // reset state when modal closes
    modalEl.addEventListener('hidden.bs.modal', function () {
        searchInput.value = '';
        suggestions.style.display = 'none';
        selectedPrev.classList.add('d-none');
        document.getElementById('cfGraceTimeWrapper').classList.add('d-none');
        document.getElementById('cfGraceTimeInput').value = '';
        addBtn.disabled = true;
        selectedService = null;
    });
})();
