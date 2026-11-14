// moved from Views/EmailLogs/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    function viewError(encodedMsg) {
        var msg = decodeURIComponent(encodedMsg);
        Swal.fire({
            icon: 'error',
            title: 'Delivery Failed',
            html: '<div class="text-start p-2 rounded bg-light border" style="font-family: monospace; font-size: 0.85rem; max-height: 300px; overflow-y: auto;">' + 
                  msg.replace(/\n/g, '<br>') + '</div>',
            width: '600px',
            confirmButtonColor: 'var(--emr-primary)'
        });
    }
