// moved from Views/MembershipPlans/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        $(document).ready(function () {
            if ($('#membershipPlanTable tbody tr td').length > 1) {
                $('#membershipPlanTable').DataTable({
                    "pageLength": 10,
                    "ordering": true,
                    "info": true,
                    "searching": false, // Handled by custom search box
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

        function confirmDelete(btn) {
            var id = btn.dataset.id, name = btn.dataset.name, cards = parseInt(btn.dataset.cards || '0', 10);
            Swal.fire({
                title: cards > 0 ? 'Deactivate Membership Plan?' : 'Delete Membership Plan?',
                text: cards > 0
                    ? '"' + name + '" has ' + cards + ' issued card(s). It will be deactivated so no new cards can be issued on it; existing cards stay valid.'
                    : 'Are you sure you want to delete "' + name + '"?',
                icon: 'warning',
                showCancelButton: true,
                confirmButtonColor: '#dc3545',
                cancelButtonColor: '#6c757d',
                confirmButtonText: cards > 0 ? 'Yes, deactivate' : 'Yes, delete it!'
            }).then(function (result) {
                if (result.isConfirmed) $('#deleteForm-' + id).submit();
            });
        }
    
