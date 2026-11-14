// moved from Views/ConsentMasters/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        var quill;

        document.addEventListener('DOMContentLoaded', function () {
            quill = new Quill('#quillEditor', {
                theme: 'snow',
                placeholder: 'Type or compose your informed consent template here. Use dynamic tags for patient details...',
                modules: {
                    toolbar: [
                        [{ 'header': [1, 2, 3, 4, false] }],
                        ['bold', 'italic', 'underline', 'strike'],
                        [{ 'color': [] }, { 'background': [] }],
                        [{ 'list': 'ordered'}, { 'list': 'bullet' }],
                        [{ 'align': [] }],
                        ['blockquote', 'code-block'],
                        ['clean']
                    ]
                }
            });

            onTypeChange();

            // Sync on form submit
            document.getElementById('consentForm').addEventListener('submit', function (e) {
                var html = quill.root.innerHTML;
                if (quill.getText().trim().length === 0 && html === '<p><br></p>') {
                    document.getElementById('hiddenContent').value = '';
                } else {
                    document.getElementById('hiddenContent').value = html;
                }
            });
        });

        function insertVariable(tag) {
            if (!quill) return;
            var range = quill.getSelection(true);
            var index = range ? range.index : quill.getLength();
            quill.insertText(index, tag, 'bold', true);
            quill.setSelection(index + tag.length, 0);
        }

        function onTypeChange() {
            var typeVal = document.getElementById('typeSelect').value;
            var procWrap = document.getElementById('procedureWrapper');
            var procSelect = document.getElementById('procedureSelect');

            if (typeVal === 'IPD') {
                procWrap.style.display = 'block';
                procSelect.disabled = false;
            } else {
                procWrap.style.display = 'none';
                procSelect.disabled = true;
                procSelect.value = '';
            }
        }
    
