// moved from Views/Insurances/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener("DOMContentLoaded", function () {
            const typeSelect = document.getElementById("typeSelect");
            const codeInput = document.getElementById("codeInput");
            const prefixInput = document.getElementById("policyPrefixInput");
            const btnRegenerate = document.getElementById("btnRegeneratePrefix");
            const contactInput = document.getElementById("contactNoInput");

            // Helper function to fetch auto-generated prefix
            async function fetchPrefix() {
                const type = typeSelect ? typeSelect.value : "Insurance Company";
                const code = codeInput ? codeInput.value : "";
                try {
                    const response = await fetch(`/Insurances/GeneratePrefix?type=${encodeURIComponent(type)}&code=${encodeURIComponent(code)}`);
                    if (response.ok) {
                        const data = await response.json();
                        if (data && data.prefix) {
                            prefixInput.value = data.prefix;
                        }
                    }
                } catch (e) {
                    console.error("Failed to generate prefix", e);
                }
            }

            if (btnRegenerate) {
                btnRegenerate.addEventListener("click", fetchPrefix);
            }

            if (typeSelect) {
                typeSelect.addEventListener("change", function () {
                    if (!prefixInput.value || prefixInput.value.startsWith("POL-")) {
                        fetchPrefix();
                    }
                });
            }

            if (codeInput) {
                codeInput.addEventListener("blur", function () {
                    if (!prefixInput.value || prefixInput.value.startsWith("POL-")) {
                        fetchPrefix();
                    }
                });
            }

            // Only allow numbers in 10-digit mobile contact input
            if (contactInput) {
                contactInput.addEventListener("input", function () {
                    this.value = this.value.replace(/[^0-9]/g, '').slice(0, 10);
                });
            }
        });
    
