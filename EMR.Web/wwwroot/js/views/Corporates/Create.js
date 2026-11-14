// moved from Views/Corporates/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener("DOMContentLoaded", function () {
            const fromDate = document.getElementById("effectiveFrom");
            const toDate = document.getElementById("effectiveTo");
            const contactInput = document.getElementById("contactNoInput");

            // Ensure toDate >= fromDate
            if (fromDate && toDate) {
                fromDate.addEventListener("change", function () {
                    if (fromDate.value && toDate.value && toDate.value < fromDate.value) {
                        toDate.value = fromDate.value;
                    }
                    toDate.min = fromDate.value;
                });
            }

            // Only allow numbers in 10-digit mobile contact input
            if (contactInput) {
                contactInput.addEventListener("input", function () {
                    this.value = this.value.replace(/[^0-9]/g, '').slice(0, 10);
                });
            }
        });
    
