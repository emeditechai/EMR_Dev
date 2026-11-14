// moved from Views/MembershipCards/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        $(document).ready(function () {
            if ($('#membershipCardTable tbody tr td').length > 1) {
                $('#membershipCardTable').DataTable({
                    "pageLength": 25,
                    "order": [],
                    "info": true,
                    "searching": false, // Handled by the filter row
                    "lengthChange": true,
                    "language": {
                        "paginate": {
                            "previous": "<i class='bi bi-chevron-left'></i>",
                            "next": "<i class='bi bi-chevron-right'></i>"
                        }
                    }
                });
            }
        });
    
