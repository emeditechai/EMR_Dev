// moved from Views/ClinicalUnits/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener("DOMContentLoaded", function () {
            const specialitySelect = document.getElementById("specialitySelect");
            const doctorSelect = document.getElementById("doctorSelect");

            if (specialitySelect && doctorSelect) {
                specialitySelect.addEventListener("change", function () {
                    const specId = this.value;
                    const currentSelectedDoc = doctorSelect.value;
                    
                    fetch(`/ClinicalUnits/GetDoctorsBySpeciality?specialityId=${encodeURIComponent(specId)}`)
                        .then(response => response.json())
                        .then(data => {
                            doctorSelect.innerHTML = '<option value="">-- Select Consultant (Optional) --</option>';
                            data.forEach(doc => {
                                const option = document.createElement("option");
                                option.value = doc.doctorId;
                                option.textContent = `${doc.fullName} (${doc.specialityName})`;
                                if (currentSelectedDoc && doc.doctorId == currentSelectedDoc) {
                                    option.selected = true;
                                }
                                doctorSelect.appendChild(option);
                            });
                        })
                        .catch(err => console.error("Error loading doctors:", err));
                });
            }
        });
    
