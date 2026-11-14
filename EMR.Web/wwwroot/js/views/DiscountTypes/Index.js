// moved from Views/DiscountTypes/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        $(document).ready(function () {
            $('#discountTypeTable').DataTable({
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
        });

        function confirmDelete(id, name) {
            Swal.fire({
                title: 'Delete Discount Type?',
                text: `Are you sure you want to delete "${name}"? This action cannot be undone.`,
                icon: 'warning',
                showCancelButton: true,
                confirmButtonColor: '#dc3545',
                cancelButtonColor: '#6c757d',
                confirmButtonText: 'Yes, delete it!'
            }).then((result) => {
                if (result.isConfirmed) {
                    $('#deleteForm-' + id).submit();
                }
            });
        }
    
