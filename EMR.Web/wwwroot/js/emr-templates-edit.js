// Moved out of Views/EmrTemplates/Edit.cshtml (kept the views under the compiler's string-literal limit); no Razor code inside.
        // Track the active section element
        let activeSectionEl = null;

        function selectSection(el) {
            $('.section-card').removeClass('active-section');
            activeSectionEl = $(el);
            activeSectionEl.addClass('active-section');
        }

        $(document).ready(function() {
            // Initialize select2
            $('.select2-multiple').select2({
                theme: 'bootstrap-5',
                width: '100%',
                allowClear: true
            });

            const sectionsContainer = $('#sectionsContainer');
            const sectionHtmlTemplate = $('#sectionTemplate').html();
            const fieldHtmlTemplate = $('#fieldTemplate').html();

            // Set active section on load if any exist
            const loadedSections = sectionsContainer.children('.section-card');
            if (loadedSections.length > 0) {
                selectSection(loadedSections.first());
            }

            // Run initial index updates since we loaded server-side HTML
            updateIndices();
            // Initialize autocomplete for loaded items
            $('.field-row[data-field-type="Investigation"], .field-row[data-field-type="Medication"]').each(function() {
                const row = $(this);
                const fieldType = row.attr('data-field-type');
                setupAutoSuggest(row, fieldType);
                
                // Bind close buttons of loaded Investigation tags
                row.find('.selected-item-tag .btn-close').on('click', function () {
                    $(this).closest('.selected-item-tag').remove();
                    updateIndices();
                });

                // Bind remove buttons of loaded Medication rows (dose/freq style)
                row.find('.selected-item-tag .item-remove-btn').on('click', function () {
                    $(this).closest('.selected-item-tag').remove();
                    updateIndices();
                });

                // Init tag editors for server-rendered Medication config panels
                if (fieldType === 'Medication') {
                    row.find('.tag-editor-wrap').each(function() { initTagEditor($(this), row); });
                }
            });

            // Initialize media fields loaded from server
            $('.field-row[data-field-type="RichText"] .rich-text-editor').each(function() {
                initQuillEditor(this, $(this).attr('data-content') || null);
            });
            $('.field-row[data-field-type="Paint"]').each(function() { initPaintCanvas($(this)); });
            $('.field-row[data-field-type="ImageUpload"]').each(function() { initImageUpload($(this)); });
            $('.field-row[data-field-type="FileUpload"]').each(function() { initFileUpload($(this)); });

            // Prevent accidental drag when interacting with media content
            sectionsContainer.on('dragstart', '.field-media-content', function(e) { e.stopPropagation(); });

            // Toolbox Add Section
            $('#btnAddSection').click(function() {
                addSection('');
            });

            function addSection(defaultName) {
                const sectionIndex = sectionsContainer.children().length;
                let html = sectionHtmlTemplate.replace(/{sectionIndex}/g, sectionIndex);
                const el = $(html);
                
                if (defaultName) {
                    el.find('.section-name-input').val(defaultName);
                }
                
                sectionsContainer.append(el);
                selectSection(el);
                
                setupDropZone(el.find('.drop-zone'));
                updateIndices();
            }

            // Remove section
            sectionsContainer.on('click', '.btn-remove-section', function(e) {
                e.stopPropagation();
                const card = $(this).closest('.section-card');
                const sectionName = card.find('.section-name-input').val().trim() || 'this section';

                Swal.fire({
                    title: 'Delete Section?',
                    html: `This will permanently remove <strong>${sectionName}</strong> and all its fields.`,
                    icon: 'warning',
                    showCancelButton: true,
                    confirmButtonColor: '#dc3545',
                    cancelButtonColor: '#6c757d',
                    confirmButtonText: '<i class="bi bi-trash me-1"></i>Yes, delete it',
                    cancelButtonText: 'Cancel'
                }).then((result) => {
                    if (result.isConfirmed) {
                        if (activeSectionEl && activeSectionEl.is(card)) {
                            activeSectionEl = null;
                        }
                        card.remove();

                        const remaining = sectionsContainer.children('.section-card');
                        if (remaining.length > 0) {
                            selectSection(remaining.first());
                        }
                        updateIndices();
                    }
                });
            });

            // Toolbox Item Click (Append field directly to active section)
            $('.tool-item').click(function() {
                const type = $(this).data('type');
                
                if (!activeSectionEl || activeSectionEl.closest('body').length === 0) {
                    const lastSec = sectionsContainer.children('.section-card').last();
                    if (lastSec.length > 0) {
                        selectSection(lastSec);
                    } else {
                        addSection('New Section');
                    }
                }
                
                addField(activeSectionEl, '', type, false);
            });

            function addField(secCard, defaultFieldName, defaultFieldType, isRequired) {
                if (defaultFieldType === 'Investigation' || defaultFieldType === 'Medication') {
                    addInvestigationOrMedicationField(secCard, defaultFieldName, defaultFieldType);
                    return;
                }
                if (['ImageUpload', 'Paint', 'FileUpload', 'RichText'].includes(defaultFieldType)) {
                    addMediaField(secCard, defaultFieldName, defaultFieldType);
                    return;
                }

                const fieldsContainer = secCard.find('.fields-container');
                const emptyMsg = secCard.find('.empty-fields-msg');
                const fieldIndex = fieldsContainer.children().length;
                
                let html = fieldHtmlTemplate.replace(/{fieldIndex}/g, fieldIndex);
                const el = $(html);
                
                if (defaultFieldName) {
                    el.find('.field-name-input').val(defaultFieldName);
                }
                
                el.find('.field-type-badge').text(getFieldTypeShortName(defaultFieldType));
                
                const optionsInput = el.find('.field-options-input');
                if (defaultFieldType === 'Select' || defaultFieldType === 'MultiSelect') {
                    optionsInput.removeClass('d-none').prop('required', true);
                }
                
                if (isRequired) {
                    el.find('.field-required-checkbox').prop('checked', true);
                }
                
                el.attr('data-field-type', defaultFieldType);
                
                fieldsContainer.append(el);
                emptyMsg.addClass('d-none');
                
                setupFieldDragDrop(el);
                updateIndices();
            }

            // Remove field
            sectionsContainer.on('click', '.btn-remove-field', function(e) {
                e.stopPropagation();
                const secCard = $(this).closest('.section-card');
                $(this).closest('.field-row').remove();
                
                const container = secCard.find('.fields-container');
                if (container.children().length === 0) {
                    secCard.find('.empty-fields-msg').removeClass('d-none');
                }
                
                updateIndices();
            });

            function getFieldTypeShortName(type) {
                switch(type) {
                    case 'Text': return 'Text';
                    case 'TextArea': return 'Multi-line';
                    case 'Select': return 'Dropdown';
                    case 'MultiSelect': return 'Multi-select';
                    case 'Number': return 'Number';
                    case 'Checkbox': return 'Switch';
                    case 'Date': return 'Date';
                    case 'Investigation': return 'Investigation';
                    case 'Medication': return 'Medication';
                    case 'ImageUpload': return 'Image';
                    case 'Paint': return 'Paint';
                    case 'FileUpload': return 'File';
                    case 'RichText': return 'Rich Text';
                    default: return type;
                }
            }

            // ── AUTO-SUGGEST SETUP ──────────────────────────────────
            function setupAutoSuggest(fieldRow, fieldType) {
                const endpoint = fieldType === 'Investigation'
                    ? '/EmrInvestigations/Search'
                    : '/EmrMedications/Search';

                const suggestBox = fieldRow.find('.autosuggest-input');
                const dropdown = fieldRow.find('.autosuggest-dropdown');

                suggestBox.on('input', async function () {
                    const q = $(this).val().trim();
                    if (q.length < 1) { dropdown.hide(); return; }

                    try {
                        const res = await fetch(`${endpoint}?q=${encodeURIComponent(q)}`);
                        const items = await res.json();
                        dropdown.empty();

                        if (items.length === 0) {
                            dropdown.html('<div class="dropdown-item-text text-muted small py-2">No results found</div>').show();
                            return;
                        }

                        items.forEach(item => {
                            const subtitle = fieldType === 'Investigation'
                                ? (item.category ? `<span class="badge bg-info-subtle text-info border ms-1" style="font-size:0.65rem;">${item.category}</span>` : '')
                                : (item.genericName ? `<small class="text-muted ms-1">(${item.genericName})</small>` : '');

                            const li = $(`<button type="button" class="dropdown-item py-2 d-flex align-items-center gap-1">
                                <span class="fw-semibold">${item.text}</span>
                                ${subtitle}
                            </button>`);

                            li.on('click', function () {
                                const hint = fieldType === 'Medication' ? (item.strength || '') + (item.unit ? ' ' + item.unit : '') : '';
                                addSelectedItem(fieldRow, item.id, item.text, fieldType, hint.trim(), fieldRow);
                                suggestBox.val('');
                                dropdown.hide();
                                updateIndices();
                            });
                            dropdown.append(li);
                        });

                        dropdown.show();
                    } catch (e) {
                        console.error('AutoSuggest error:', e);
                    }
                });

                $(document).on('click.autosuggest', function (e) {
                    if (!fieldRow[0].contains(e.target)) dropdown.hide();
                });
            }

            // ── TAG EDITOR: Frequency / Procedure options ─────────────────────
            function initTagEditor(wrap, fieldRow) {
                const targetKey = wrap.attr('data-target'); // e.g. 'med-freq-options-store'
                const store = fieldRow.find('.' + targetKey);
                const display = wrap.find('.tag-display');
                const input = wrap.find('.tag-input');
                const addBtn = wrap.find('.tag-add-btn');

                const isFn = (targetKey === 'med-freq-options-store');
                const chipColor = isFn ? 'bg-warning-subtle text-warning-emphasis border-warning-subtle' : 'bg-primary-subtle text-primary-emphasis border-primary-subtle';

                function syncStore() {
                    const tags = [];
                    display.find('.tag-chip').each(function() {
                        const label = $(this).contents().filter(function() { return this.nodeType === 3; }).text().trim();
                        if (label) tags.push(label);
                    });
                    store.val(tags.join(', '));
                    updateIndices();
                }

                function addTag(val) {
                    val = val.trim();
                    if (!val) return;
                    // Avoid duplicates
                    let exists = false;
                    display.find('.tag-chip').each(function() {
                        const label = $(this).contents().filter(function() { return this.nodeType === 3; }).text().trim();
                        if (label.toLowerCase() === val.toLowerCase()) { exists = true; }
                    });
                    if (exists) { input.val(''); return; }
                    const chip = $(`<span class="badge ${chipColor} border d-inline-flex align-items-center gap-1 tag-chip">${val} <button type="button" class="btn-close" style="font-size:0.45rem;" data-tag="${val}"></button></span>`);
                    chip.find('.btn-close').on('click', function() { chip.remove(); syncStore(); });
                    display.append(chip);
                    input.val('');
                    syncStore();
                }

                // Bind close on existing chips
                display.find('.tag-chip .btn-close').off('click.te').on('click.te', function() {
                    $(this).closest('.tag-chip').remove();
                    syncStore();
                });

                addBtn.on('click', function() { addTag(input.val()); });
                input.on('keydown', function(e) {
                    if (e.key === 'Enter') { e.preventDefault(); addTag($(this).val()); }
                });
            }

            function addSelectedItem(fieldRow, id, text, fieldType, strengthHint, sourceFieldRow) {
                const container = fieldRow.find('.selected-items-container');
                if (container.find(`[data-item-id="${id}"]`).length > 0) return;

                if (fieldType === 'Medication') {
                    // Get freq/proc options from the fieldRow's stored options
                    const fr = sourceFieldRow || fieldRow;
                    const freqOptsCsv = fr.find('.med-freq-options-store').val() || 'Daily,Weekly,Monthly,Yearly,Alternate Day';
                    const procOptsCsv = fr.find('.med-proc-options-store').val() || 'Before Food,After Food,After Breakfast,Before Breakfast,After Lunch,After Dinner,Before Dinner';
                    const freqOpts = freqOptsCsv.split(',').map(o => o.trim()).filter(o => o);
                    const procOpts = procOptsCsv.split(',').map(o => o.trim()).filter(o => o);

                    const dosePlaceholder = strengthHint ? `Dose (e.g. ${strengthHint})` : 'Dose';
                    const freqOptions = freqOpts.map(o => `<option value="${o}">${o}</option>`).join('');
                    const procOptions = procOpts.map(o => `<option value="${o}">${o}</option>`).join('');

                    const row = $(`
                        <div class="selected-item-tag d-flex align-items-center gap-2 flex-wrap p-1 bg-white border rounded mb-1" data-item-id="${id}" data-item-text="${text}">
                            <span class="badge bg-warning-subtle text-warning-emphasis border border-warning-subtle">
                                <i class="bi bi-capsule me-1"></i>${text}
                            </span>
                            <input type="text" class="form-control form-control-sm item-dose-input" placeholder="${dosePlaceholder}" style="max-width:100px;" />
                            <select class="form-select form-select-sm item-freq-select" style="max-width:130px;">
                                <option value="">-- Frequency --</option>
                                ${freqOptions}
                            </select>
                            <select class="form-select form-select-sm item-proc-select" style="max-width:155px;">
                                <option value="">-- Procedure --</option>
                                ${procOptions}
                            </select>
                            <button type="button" class="btn btn-sm btn-link text-danger p-0 ms-auto item-remove-btn" style="line-height:1;"><i class="bi bi-x-circle-fill"></i></button>
                        </div>
                    `);
                    row.find('.item-remove-btn').on('click', function () { row.remove(); updateIndices(); });
                    container.append(row);
                } else {
                    const tag = $(`
                        <span class="badge bg-light text-dark border me-1 mb-1 d-inline-flex align-items-center gap-1 selected-item-tag" data-item-id="${id}" data-item-text="${text}">
                            ${text}
                            <button type="button" class="btn-close btn-close-dark" style="font-size:0.5rem;"></button>
                        </span>
                    `);
                    tag.find('.btn-close').on('click', function () { tag.remove(); updateIndices(); });
                    container.append(tag);
                }
            }

            // ── DRAG AND DROP INTEGRATION ──

            // 1. Toolbox Draggable
            document.querySelectorAll('.tool-item').forEach(item => {
                item.addEventListener('dragstart', function(e) {
                    e.dataTransfer.setData('text/plain', this.dataset.type);
                    e.dataTransfer.effectAllowed = 'copy';
                });
            });

            // 2. Drop Zone Setup
            function setupDropZone(zone) {
                const el = zone[0];
                
                el.addEventListener('dragover', function(e) {
                    e.preventDefault();
                    e.dataTransfer.dropEffect = 'copy';
                    $(this).addClass('drag-over');
                });
                
                el.addEventListener('dragenter', function(e) {
                    e.preventDefault();
                    $(this).addClass('drag-over');
                });
                
                el.addEventListener('dragleave', function() {
                    $(this).removeClass('drag-over');
                });
                
                el.addEventListener('drop', function(e) {
                    e.preventDefault();
                    $(this).removeClass('drag-over');
                    
                    const type = e.dataTransfer.getData('text/plain');
                    if (type) {
                        const secCard = $(this).closest('.section-card');
                        selectSection(secCard);
                        
                        const draggingFieldId = e.dataTransfer.getData('field-id');
                        if (draggingFieldId) {
                            const fieldRow = $('#' + draggingFieldId);
                            if (fieldRow.length > 0) {
                                $(this).append(fieldRow);
                                secCard.find('.empty-fields-msg').addClass('d-none');
                                updateIndices();
                            }
                        } else {
                            addField(secCard, '', type, false);
                        }
                    }
                });
            }

            // 3. Field Sorting Setup
            let draggedField = null;

            function setupFieldDragDrop(fieldRow) {
                const row = fieldRow[0];
                const id = 'field_row_' + Math.random().toString(36).substr(2, 9);
                fieldRow.attr('id', id);
                
                row.addEventListener('dragstart', function(e) {
                    draggedField = this;
                    e.dataTransfer.setData('text/plain', this.dataset.fieldType);
                    e.dataTransfer.setData('field-id', this.id);
                    e.dataTransfer.effectAllowed = 'move';
                    setTimeout(() => this.classList.add('dragging'), 0);
                });
                
                row.addEventListener('dragend', function() {
                    this.classList.remove('dragging');
                    draggedField = null;
                    updateIndices();
                });

                row.addEventListener('dragover', function(e) {
                    e.preventDefault();
                    if (!draggedField || draggedField === this) return;
                    
                    const container = this.parentNode;
                    const bounding = this.getBoundingClientRect();
                    const offset = e.clientY - bounding.top - bounding.height / 2;
                    
                    if (offset < 0) {
                        container.insertBefore(draggedField, this);
                    } else {
                        container.insertBefore(draggedField, this.nextSibling);
                    }
                });
            }

            // Apply drag drop setup on initial rows
            $('.drop-zone').each(function() {
                setupDropZone($(this));
            });
            $('.field-row').each(function() {
                setupFieldDragDrop($(this));
            });

            // Regenerate input names
            function updateIndices() {
                sectionsContainer.children('.section-card').each(function(sIdx, secEl) {
                    const sec = $(secEl);
                    sec.attr('data-section-index', sIdx);
                    
                    sec.find('.section-name-input').attr('name', `Sections[${sIdx}].SectionName`);
                    sec.find('.section-id-input').attr('name', `Sections[${sIdx}].SectionId`);
                    
                    const fieldsContainer = sec.find('.fields-container');
                    const emptyMsg = sec.find('.empty-fields-msg');
                    const fields = fieldsContainer.children('.field-row');
                    
                    if (fields.length > 0) {
                        emptyMsg.addClass('d-none');
                    } else {
                        emptyMsg.removeClass('d-none');
                    }
                    
                    fields.each(function(fIdx, fieldEl) {
                        const f = $(fieldEl);
                        f.attr('data-field-index', fIdx);
                        
                        const fieldType = f.attr('data-field-type');
                        
                        f.find('.field-name-input').attr('name', `Sections[${sIdx}].Fields[${fIdx}].FieldName`);
                        f.find('.field-id-input').attr('name', `Sections[${sIdx}].Fields[${fIdx}].FieldId`);
                        
                        let typeInput = f.find('.field-type-hidden-val');
                        if (typeInput.length === 0) {
                            typeInput = $('<input type="hidden" class="field-type-hidden-val" />');
                            f.append(typeInput);
                        }
                        typeInput.attr('name', `Sections[${sIdx}].Fields[${fIdx}].FieldType`).val(fieldType);
                        
                        let optionsInput = f.find('.field-options-input');
                        if (fieldType === 'Investigation' || fieldType === 'Medication') {
                            if (optionsInput.length === 0) {
                                optionsInput = $('<input type="hidden" class="field-options-input" />');
                                f.append(optionsInput);
                            }
                            const selectedItems = [];
                            f.find('.selected-item-tag').each(function() {
                                const itemId = $(this).attr('data-item-id');
                                const itemText = $(this).attr('data-item-text') || $(this).find('.badge').text().replace(/^\s*/, '').trim();
                                if (fieldType === 'Medication') {
                                    const dose = $(this).find('.item-dose-input').val().trim();
                                    const freq = $(this).find('.item-freq-select').val().trim();
                                    const proc = $(this).find('.item-proc-select').val().trim();
                                    selectedItems.push(itemId + '|' + itemText + '|' + dose + '|' + freq + '|' + proc);
                                } else {
                                    selectedItems.push(itemId + '|' + itemText);
                                }
                            });
                            if (fieldType === 'Medication') {
                                // Collect freq/proc options from the tag editors
                                const freqOptsCsv = f.find('.med-freq-options-store').val() || '';
                                const procOptsCsv = f.find('.med-proc-options-store').val() || '';
                                const freqOpts = freqOptsCsv.split(',').map(o => o.trim()).filter(o => o);
                                const procOpts = procOptsCsv.split(',').map(o => o.trim()).filter(o => o);
                                const medJson = JSON.stringify({ freqOptions: freqOpts, procOptions: procOpts, items: selectedItems.join(',') });
                                optionsInput.val(medJson);
                            } else {
                                optionsInput.val(selectedItems.join(','));
                            }
                        } else if (fieldType === 'RichText') {
                            if (optionsInput.length === 0) {
                                optionsInput = $('<input type="hidden" class="field-options-input" />');
                                f.append(optionsInput);
                            }
                            const editorEl = f.find('.rich-text-editor')[0];
                            if (editorEl) {
                                const qi = $(editorEl).data('quill-instance');
                                if (qi) optionsInput.val(JSON.stringify(qi.getContents()));
                            }
                        }
                        optionsInput.attr('name', `Sections[${sIdx}].Fields[${fIdx}].OptionsString`);
                        
                        f.find('.field-required-checkbox').attr('name', `Sections[${sIdx}].Fields[${fIdx}].IsRequired`);
                        f.find('.field-required-hidden').attr('name', `Sections[${sIdx}].Fields[${fIdx}].IsRequired`);
                    });
                });
            }

            // Bind preview events
            $('#btnPreviewTemplate, #btnPreviewTemplateBottom').click(showTemplatePreview);

            function showTemplatePreview() {
                const templateName = $('#TemplateName').val().trim() || 'Untitled EMR Template';
                const description = $('#Description').val().trim();
                
                let html = `
                    <div class="mb-4 bg-white p-3 rounded shadow-sm">
                        <h4 class="fw-bold text-primary mb-1"><i class="bi bi-file-earmark-medical me-2"></i>${templateName}</h4>
                        ${description ? `<p class="text-muted small mb-0">${description}</p>` : ''}
                    </div>
                    
                    <!-- Common EMR Header -->
                    <div class="card border-0 shadow-sm mb-4 bg-white" style="border-radius: 10px;">
                        <div class="card-header bg-light py-2 px-3 border-bottom-0">
                            <span class="fw-bold text-secondary small text-uppercase"><i class="bi bi-person-lines-fill me-1"></i>Common Patient Header (Auto-Generated)</span>
                        </div>
                        <div class="card-body py-3">
                            <div class="row g-3 small">
                                <div class="col-md-3"><strong>Visit No:</strong> <span class="text-muted">V26270001</span></div>
                                <div class="col-md-3"><strong>UHID:</strong> <span class="text-muted">PH26270001</span></div>
                                <div class="col-md-3"><strong>Patient Name:</strong> <span class="text-muted">Jane Doe</span></div>
                                <div class="col-md-3"><strong>Age/Gender:</strong> <span class="text-muted">34 Y / Female</span></div>
                                <div class="col-md-3"><strong>Consulting Doctor:</strong> <span class="text-muted">Dr. Samir Pandit</span></div>
                                <div class="col-md-3"><strong>Speciality:</strong> <span class="text-muted">General Medicine</span></div>
                                <div class="col-md-3"><strong>Visit Date:</strong> <span class="text-muted">${new Date().toLocaleString()}</span></div>
                                <div class="col-md-3"><strong>Visit Type:</strong> <span class="text-muted">OPD Consultation</span></div>
                            </div>
                        </div>
                    </div>
                `;

                const sections = $('#sectionsContainer').children('.section-card');
                
                if (sections.length === 0) {
                    html += `
                        <div class="text-center py-5 text-muted bg-white rounded-3 border">
                            <i class="bi bi-exclamation-triangle fs-1 d-block mb-2 text-warning"></i>
                            No sections configured. Add some sections to preview.
                        </div>
                    `;
                } else {
                    sections.each(function() {
                        const secName = $(this).find('.section-name-input').val().trim() || 'Unnamed Section';
                        const fields = $(this).find('.fields-container').children('.field-row');
                        
                        html += `
                            <div class="card border-0 shadow-sm mb-4 bg-white" style="border-radius: 10px; overflow: hidden;">
                                <div class="card-header bg-light py-2 px-3 border-bottom">
                                    <h5 class="fw-bold mb-0 text-dark small text-uppercase" style="letter-spacing: 0.5px;">${secName}</h5>
                                </div>
                                <div class="card-body">
                        `;
                        
                        if (fields.length === 0) {
                            html += `<div class="text-center text-muted py-3 small">No fields added to this section.</div>`;
                        } else {
                            html += `<div class="row g-3">`;
                            fields.each(function() {
                                const fieldName = $(this).find('.field-name-input').val().trim() || 'Label';
                                const fieldType = $(this).attr('data-field-type') || 'Text';
                                const isRequired = $(this).find('.field-required-checkbox').is(':checked');
                                const reqAsterisk = isRequired ? '<span class="text-danger">*</span>' : '';
                                
                                html += `<div class="col-md-6 mb-2">`;
                                html += `<label class="form-label fw-semibold small text-dark mb-1">${fieldName} ${reqAsterisk}</label>`;
                                
                                switch(fieldType) {
                                    case 'Text':
                                        html += `<input type="text" class="form-control form-control-sm" placeholder="Enter ${fieldName}..." disabled />`;
                                        break;
                                    case 'TextArea':
                                        html += `<textarea class="form-control form-control-sm" rows="3" placeholder="Enter ${fieldName} details..." disabled></textarea>`;
                                        break;
                                    case 'Select':
                                        html += `<select class="form-select form-select-sm" disabled>`;
                                        const optStr = $(this).find('.field-options-input').val().trim();
                                        if (optStr) {
                                            const opts = optStr.split(',');
                                            opts.forEach(o => {
                                                html += `<option value="${o.trim()}">${o.trim()}</option>`;
                                            });
                                        } else {
                                            html += `<option value="">-- Select option --</option>`;
                                        }
                                        html += `</select>`;
                                        break;
                                    case 'MultiSelect':
                                        html += `<div class="p-2 border rounded bg-light-subtle d-flex flex-wrap gap-2">`;
                                        const multiOptStr = $(this).find('.field-options-input').val().trim();
                                        if (multiOptStr) {
                                            const opts = multiOptStr.split(',');
                                            opts.forEach((o, i) => {
                                                const oId = 'preview_chk_' + Math.random().toString(36).substr(2, 5);
                                                html += `
                                                    <div class="form-check form-check-inline mb-0">
                                                        <input class="form-check-input" type="checkbox" id="${oId}" disabled />
                                                        <label class="form-check-label small" for="${oId}">${o.trim()}</label>
                                                    </div>
                                                `;
                                            });
                                        } else {
                                            html += `<span class="text-muted small">No options defined</span>`;
                                        }
                                        html += `</div>`;
                                        break;
                                    case 'Number':
                                        html += `<input type="number" class="form-control form-control-sm" placeholder="0" disabled />`;
                                        break;
                                    case 'Checkbox':
                                        html += `
                                            <div class="form-check form-switch mt-1">
                                                <input class="form-check-input" type="checkbox" role="switch" disabled />
                                                <label class="form-check-label text-muted small">Enabled</label>
                                            </div>
                                        `;
                                        break;
                                    case 'Date':
                                        html += `
                                            <div class="input-group input-group-sm">
                                                <span class="input-group-text bg-light text-muted"><i class="bi bi-calendar"></i></span>
                                                <input type="date" class="form-control" disabled />
                                            </div>
                                        `;
                                        break;
                                    case 'ImageUpload':
                                        html += `<div class="border border-2 border-dashed rounded-2 d-flex flex-column align-items-center justify-content-center p-3 text-muted bg-light" style="min-height: 80px;">
                                            <i class="bi bi-image fs-2 text-info mb-1 d-block"></i>
                                            <div class="small fw-semibold">Image upload area</div>
                                        </div>`;
                                        break;
                                    case 'Paint':
                                        html += `<div class="border rounded-2 bg-white d-flex align-items-center justify-content-center" style="height: 120px;">
                                            <div class="text-center text-muted small"><i class="bi bi-brush fs-2 d-block mb-1 text-danger"></i>Paint / Annotate Canvas</div>
                                        </div>`;
                                        break;
                                    case 'FileUpload':
                                        html += `<div class="border border-dashed rounded-2 d-flex align-items-center gap-2 p-2 bg-light">
                                            <i class="bi bi-paperclip text-secondary fs-5"></i>
                                            <span class="small text-muted">File attachment</span>
                                            <button class="btn btn-sm btn-outline-secondary ms-auto" disabled><i class="bi bi-folder-open me-1"></i>Browse</button>
                                        </div>`;
                                        break;
                                    case 'RichText':
                                        html += `<div class="border rounded-2 overflow-hidden">
                                            <div class="d-flex gap-1 p-2 border-bottom bg-light flex-wrap">
                                                <span class="badge bg-secondary-subtle border fw-bold">B</span>
                                                <span class="badge bg-secondary-subtle border fst-italic">I</span>
                                                <span class="badge bg-secondary-subtle border text-decoration-underline">U</span>
                                                <span class="badge bg-secondary-subtle border"><i class="bi bi-palette2"></i></span>
                                                <span class="badge bg-secondary-subtle border">H1</span>
                                                <span class="badge bg-secondary-subtle border">&#8226; List</span>
                                            </div>
                                            <div class="p-2 small text-muted bg-white" style="min-height: 60px;">Rich text content area...</div>
                                        </div>`;
                                        break;
                                    default:
                                        html += `<input type="text" class="form-control form-control-sm" disabled />`;
                                }
                                
                                html += `</div>`;
                            });
                            html += `</div>`;
                        }
                        
                        html += `
                                </div>
                            </div>
                        `;
                    });
                }
                
                $('#previewModalBody').html(html);
                const myModal = new bootstrap.Modal(document.getElementById('previewModal'));
                myModal.show();
            }

            // Investigation / Medication special field rows
            function addInvestigationOrMedicationField(secCard, defaultFieldName, defaultFieldType) {
                const fieldsContainer = secCard.find('.fields-container');
                const emptyMsg = secCard.find('.empty-fields-msg');

                const fieldTypeColor = defaultFieldType === 'Investigation' ? 'success' : 'warning';
                const fieldTypeIcon = defaultFieldType === 'Investigation' ? 'bi-eyedropper' : 'bi-capsule';
                const fieldTypeName = defaultFieldType;
                const placeholder = defaultFieldType === 'Investigation' ? 'Search investigations...' : 'Search medications...';
                const isMed = defaultFieldType === 'Medication';

                const defaultFreqOpts = ['Daily', 'Weekly', 'Monthly', 'Yearly', 'Alternate Day'];
                const defaultProcOpts = ['Before Food', 'After Food', 'After Breakfast', 'Before Breakfast', 'After Lunch', 'After Dinner', 'Before Dinner'];

                const itemsContainerClass = isMed
                    ? 'selected-items-container d-flex flex-column gap-1 mb-2 p-1 border rounded bg-light'
                    : 'selected-items-container d-flex flex-wrap gap-1 mb-2 p-1 border rounded bg-light';

                const freqTagsHtml = defaultFreqOpts.map(o =>
                    `<span class="badge bg-warning-subtle text-warning-emphasis border border-warning-subtle d-inline-flex align-items-center gap-1 tag-chip">${o} <button type="button" class="btn-close" style="font-size:0.45rem;" data-tag="${o}"></button></span>`
                ).join('');
                const procTagsHtml = defaultProcOpts.map(o =>
                    `<span class="badge bg-primary-subtle text-primary-emphasis border border-primary-subtle d-inline-flex align-items-center gap-1 tag-chip">${o} <button type="button" class="btn-close" style="font-size:0.45rem;" data-tag="${o}"></button></span>`
                ).join('');

                const configPanel = isMed ? `
                    <input type="hidden" class="med-freq-options-store" value="${defaultFreqOpts.join(', ')}" />
                    <input type="hidden" class="med-proc-options-store" value="${defaultProcOpts.join(', ')}" />
                    <div class="med-options-config bg-light border rounded p-2 mb-2" style="font-size:0.82rem;">
                        <div class="fw-semibold text-secondary mb-1"><i class="bi bi-sliders me-1"></i>Dropdown Options (editable)</div>
                        <div class="row g-2">
                            <div class="col-md-6">
                                <label class="form-label mb-1 small fw-semibold text-warning-emphasis"><i class="bi bi-clock me-1"></i>Frequency Options</label>
                                <div class="tag-editor-wrap" data-target="med-freq-options-store">
                                    <div class="tag-display d-flex flex-wrap gap-1 mb-1">${freqTagsHtml}</div>
                                    <div class="input-group input-group-sm">
                                        <input type="text" class="form-control form-control-sm tag-input" placeholder="Add option... press Enter" />
                                        <button class="btn btn-outline-warning btn-sm tag-add-btn" type="button">Add</button>
                                    </div>
                                </div>
                            </div>
                            <div class="col-md-6">
                                <label class="form-label mb-1 small fw-semibold text-primary-emphasis"><i class="bi bi-clock-history me-1"></i>Procedure Options</label>
                                <div class="tag-editor-wrap" data-target="med-proc-options-store">
                                    <div class="tag-display d-flex flex-wrap gap-1 mb-1">${procTagsHtml}</div>
                                    <div class="input-group input-group-sm">
                                        <input type="text" class="form-control form-control-sm tag-input" placeholder="Add option... press Enter" />
                                        <button class="btn btn-outline-primary btn-sm tag-add-btn" type="button">Add</button>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class="d-flex align-items-center gap-2 mb-1 px-1">
                        <small class="text-muted fw-semibold" style="min-width:150px;">Medicine</small>
                        <small class="text-muted fw-semibold" style="min-width:100px;">Dose</small>
                        <small class="text-muted fw-semibold" style="min-width:130px;">Frequency</small>
                        <small class="text-muted fw-semibold" style="min-width:155px;">Procedure</small>
                    </div>` : '';

                const el = $(`
                    <div class="field-row p-2 mb-2 border rounded-2 bg-white" data-field-type="${defaultFieldType}" draggable="true">
                        <div class="d-flex align-items-center justify-content-between mb-2">
                            <div class="d-flex align-items-center gap-2">
                                <i class="bi bi-grip-vertical text-muted" style="cursor:grab;"></i>
                                <span class="badge bg-${fieldTypeColor}-subtle text-${fieldTypeColor}-emphasis border border-${fieldTypeColor}-subtle field-type-badge">
                                    <i class="${fieldTypeIcon} me-1"></i>${fieldTypeName}
                                </span>
                                <input type="text" class="form-control form-control-sm field-name-input" placeholder="Section label (e.g. Ordered Medications)" value="${defaultFieldName}" style="max-width: 220px;" />
                            </div>
                            <button type="button" class="btn btn-sm btn-link text-danger p-1 btn-remove-field">
                                <i class="bi bi-x-circle-fill fs-5"></i>
                            </button>
                        </div>
                        ${configPanel}
                        <div class="${itemsContainerClass}" style="min-height: 32px;"></div>
                        <div class="position-relative">
                            <input type="text" class="form-control form-control-sm autosuggest-input" placeholder="${placeholder}" autocomplete="off" />
                            <div class="autosuggest-dropdown dropdown-menu w-100 p-0 border shadow-sm" style="display:none; max-height:200px; overflow-y:auto; position:absolute; z-index:1050;"></div>
                        </div>
                    </div>
                `);

                fieldsContainer.append(el);
                emptyMsg.addClass('d-none');

                // Init tag editors on the new element
                el.find('.tag-editor-wrap').each(function() { initTagEditor($(this), el); });

                setupAutoSuggest(el, defaultFieldType);
                setupFieldDragDrop(el);
                updateIndices();
            }

            // ── MEDIA FIELD BUILDER ──────────────────────────────────
            function addMediaField(secCard, defaultFieldName, fieldType) {
                const fieldsContainer = secCard.find('.fields-container');
                const emptyMsg = secCard.find('.empty-fields-msg');

                const configs = {
                    ImageUpload: { color: 'info',      icon: 'bi-image',    label: 'Image Area' },
                    Paint:       { color: 'danger',    icon: 'bi-brush',    label: 'Paint / Annotate' },
                    FileUpload:  { color: 'secondary', icon: 'bi-paperclip',label: 'File Attachment' },
                    RichText:    { color: 'primary',   icon: 'bi-type-h1',  label: 'Rich Text' }
                };
                const cfg = configs[fieldType];

                let contentHtml = '';
                if (fieldType === 'ImageUpload') {
                    contentHtml = `
                        <div class="image-upload-area border border-2 border-dashed rounded-2 d-flex flex-column align-items-center justify-content-center p-3 text-muted bg-light-subtle" style="min-height: 100px;">
                            <i class="bi bi-cloud-upload fs-3 mb-1 text-info"></i>
                            <div class="small fw-semibold">Click to upload or drag image here</div>
                            <div style="font-size: 0.7rem;">PNG, JPG, GIF accepted</div>
                            <img class="image-preview mt-2 d-none rounded" style="max-height: 150px; max-width: 100%;" />
                            <input type="file" class="image-file-input d-none" accept="image/*" />
                        </div>`;
                } else if (fieldType === 'Paint') {
                    contentHtml = `
                        <div class="paint-control-wrapper">
                            <div class="paint-toolbar p-2 bg-light rounded-top border border-bottom-0">
                                <div class="d-flex gap-1 align-items-center flex-wrap">
                                    <div class="btn-group btn-group-sm" role="group">
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn active" data-tool="pen" title="Pen (freehand)"><i class="bi bi-pencil-fill"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="highlighter" title="Highlighter"><i class="bi bi-highlighter"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="line" title="Straight line"><i class="bi bi-slash-lg"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="arrow" title="Arrow"><i class="bi bi-arrow-right"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="rect" title="Rectangle (outline)"><i class="bi bi-square"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="filled-rect" title="Filled rectangle"><i class="bi bi-square-fill"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="circle" title="Ellipse (outline)"><i class="bi bi-circle"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="filled-circle" title="Filled ellipse"><i class="bi bi-circle-fill"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="text" title="Text"><i class="bi bi-type"></i></button>
                                        <button type="button" class="btn btn-sm btn-outline-secondary paint-tool-btn" data-tool="eraser" title="Eraser"><i class="bi bi-eraser-fill"></i></button>
                                    </div>
                                    <input type="color" class="paint-color form-control form-control-color p-0" value="#000000" title="Colour" style="width:28px; height:28px; border:none;" />
                                    <select class="paint-size form-select form-select-sm" style="width:auto;" title="Stroke width">
                                        <option value="1">1 px</option>
                                        <option value="2">2 px</option>
                                        <option value="4" selected>4 px</option>
                                        <option value="8">8 px</option>
                                        <option value="14">14 px</option>
                                        <option value="24">24 px</option>
                                    </select>
                                    <button type="button" class="btn btn-sm btn-outline-secondary paint-undo-btn" title="Undo"><i class="bi bi-arrow-counterclockwise"></i></button>
                                    <button type="button" class="btn btn-sm btn-outline-secondary paint-redo-btn" title="Redo"><i class="bi bi-arrow-clockwise"></i></button>
                                    <input type="file" class="paint-bg-input d-none" accept="image/*" />
                                    <button type="button" class="btn btn-sm btn-outline-info paint-bg-btn" title="Upload background image"><i class="bi bi-image me-1"></i>BG</button>
                                    <button type="button" class="btn btn-sm btn-outline-danger paint-clear-btn ms-auto" title="Clear canvas"><i class="bi bi-trash"></i></button>
                                </div>
                            </div>
                            <div class="position-relative">
                                <canvas class="paint-canvas border rounded-bottom w-100" height="260" style="cursor: crosshair; background: #fff;"></canvas>
                                <input type="text" class="paint-text-input form-control form-control-sm d-none" placeholder="Type text, press Enter to place..." style="position: absolute; top: 8px; left: 8px; max-width: 280px; z-index: 10;" />
                            </div>
                        </div>`;
                } else if (fieldType === 'FileUpload') {
                    contentHtml = `
                        <div class="file-upload-area border border-2 border-dashed rounded-2 d-flex align-items-center justify-content-between p-3 bg-light-subtle" style="cursor: pointer;">
                            <div class="d-flex align-items-center gap-3">
                                <i class="bi bi-folder2-open fs-4 text-secondary"></i>
                                <div>
                                    <div class="small fw-semibold">Click to browse files</div>
                                    <div class="text-muted" style="font-size: 0.7rem;">PDF, DOC, DOCX, XLS, JPG, PNG</div>
                                </div>
                            </div>
                            <input type="file" class="file-browser-input d-none" multiple />
                            <button type="button" class="btn btn-sm btn-outline-secondary file-browse-btn"><i class="bi bi-folder-open me-1"></i>Browse</button>
                        </div>
                        <div class="selected-files-list mt-1 small text-muted"></div>`;
                } else if (fieldType === 'RichText') {
                    contentHtml = `
                        <div class="rich-text-wrapper border rounded-2 overflow-hidden">
                            <div class="rich-text-editor" style="min-height: 120px; background: #fff;"></div>
                        </div>`;
                }

                const el = $(`
                    <div class="field-row p-2 mb-2 border rounded-2 bg-white" data-field-type="${fieldType}" draggable="true">
                        <input type="hidden" class="field-id-input" />
                        <input type="hidden" class="field-type-hidden-val" value="${fieldType}" />
                        <input type="hidden" class="field-options-input" />
                        <div class="d-flex align-items-center justify-content-between mb-2">
                            <div class="d-flex align-items-center gap-2">
                                <i class="bi bi-grip-vertical text-muted fs-5" style="cursor:grab;"></i>
                                <span class="badge bg-${cfg.color}-subtle text-${cfg.color}-emphasis border border-${cfg.color}-subtle field-type-badge">
                                    <i class="${cfg.icon} me-1"></i>${cfg.label}
                                </span>
                                <input type="text" class="form-control form-control-sm field-name-input" placeholder="Field label" value="${defaultFieldName}" style="max-width: 220px;" required />
                            </div>
                            <div class="d-flex align-items-center gap-2">
                                <div class="form-check form-switch mb-0">
                                    <input class="form-check-input field-required-checkbox" type="checkbox" role="switch" value="true" />
                                    <input type="hidden" class="field-required-hidden" value="false" />
                                    <label class="form-check-label text-secondary small">Required</label>
                                </div>
                                <button type="button" class="btn btn-sm btn-link text-danger p-1 btn-remove-field" title="Remove Field">
                                    <i class="bi bi-x-circle-fill fs-5"></i>
                                </button>
                            </div>
                        </div>
                        <div class="field-media-content">${contentHtml}</div>
                    </div>
                `);

                fieldsContainer.append(el);
                emptyMsg.addClass('d-none');
                initMediaField(el, fieldType);
                setupFieldDragDrop(el);
                updateIndices();
            }

            function initMediaField(el, fieldType) {
                if      (fieldType === 'RichText')    initQuillEditor(el.find('.rich-text-editor')[0], null);
                else if (fieldType === 'Paint')       initPaintCanvas(el);
                else if (fieldType === 'ImageUpload') initImageUpload(el);
                else if (fieldType === 'FileUpload')  initFileUpload(el);
            }

            function initQuillEditor(container, savedContent) {
                if (!container || $(container).data('quill-init')) return;
                const quill = new Quill(container, {
                    theme: 'snow',
                    placeholder: 'Enter rich text content here...',
                    modules: {
                        toolbar: [
                            [{ 'header': [1, 2, 3, false] }],
                            ['bold', 'italic', 'underline', 'strike'],
                            [{ 'color': [] }, { 'background': [] }],
                            [{ 'align': [] }],
                            [{ 'list': 'ordered' }, { 'list': 'bullet' }],
                            ['link'],
                            ['clean']
                        ]
                    }
                });
                $(container).data('quill-init', true).data('quill-instance', quill);
                if (savedContent) {
                    try { quill.setContents(JSON.parse(savedContent)); } catch(e) { quill.setText(savedContent); }
                }
                quill.on('text-change', function() {
                    $(container).closest('.field-row').find('.field-options-input').val(JSON.stringify(quill.getContents()));
                });
            }

            function initPaintCanvas(fieldRowEl) {
                const canvas = fieldRowEl.find('.paint-canvas')[0];
                if (!canvas || $(canvas).data('paint-init')) return;
                $(canvas).data('paint-init', true);

                const ctx = canvas.getContext('2d');
                ctx.fillStyle = '#fff';
                ctx.fillRect(0, 0, canvas.width, canvas.height);

                // Restore saved state
                const savedData = $(canvas).data('saved');
                if (savedData && typeof savedData === 'string' && savedData.startsWith('data:image')) {
                    const img = new Image();
                    img.onload = () => ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                    img.src = savedData;
                }

                // ── State ─────────────────────────────────────────────────
                let isDrawing = false, currentTool = 'pen';
                let startX = 0, startY = 0, lastX = 0, lastY = 0;
                let snapshot  = null;
                let history   = [], redoStack = [];
                const MAX_HIST    = 30;
                const SHAPE_TOOLS = new Set(['line','arrow','rect','filled-rect','circle','filled-circle']);
                const FREE_TOOLS  = new Set(['pen','highlighter','eraser']);

                const saveState   = () => { history.push(canvas.toDataURL()); if (history.length > MAX_HIST) history.shift(); redoStack = []; };
                const commitInput = () => fieldRowEl.find('.field-options-input').val(canvas.toDataURL());
                const getPos = e => {
                    const r = canvas.getBoundingClientRect();
                    return [(e.clientX - r.left) * (canvas.width / r.width),
                            (e.clientY - r.top)  * (canvas.height / r.height)];
                };
                const setStyle = () => {
                    ctx.strokeStyle = currentTool === 'eraser' ? '#ffffff' : fieldRowEl.find('.paint-color').val();
                    ctx.fillStyle   = fieldRowEl.find('.paint-color').val();
                    ctx.lineWidth   = currentTool === 'highlighter'
                        ? parseInt(fieldRowEl.find('.paint-size').val()) * 6
                        : parseInt(fieldRowEl.find('.paint-size').val());
                    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
                    ctx.globalAlpha = currentTool === 'highlighter' ? 0.35 : 1.0;
                };
                const drawArrowHead = (x1, y1, x2, y2) => {
                    const len = Math.max(14, Math.min(50, ctx.lineWidth * 4));
                    const angle = Math.atan2(y2 - y1, x2 - x1);
                    ctx.beginPath();
                    ctx.moveTo(x1, y1); ctx.lineTo(x2, y2);
                    ctx.lineTo(x2 - len * Math.cos(angle - Math.PI / 6), y2 - len * Math.sin(angle - Math.PI / 6));
                    ctx.moveTo(x2, y2);
                    ctx.lineTo(x2 - len * Math.cos(angle + Math.PI / 6), y2 - len * Math.sin(angle + Math.PI / 6));
                    ctx.stroke();
                };
                const drawShape = (x2, y2) => {
                    setStyle();
                    switch (currentTool) {
                        case 'line':
                            ctx.beginPath(); ctx.moveTo(startX, startY); ctx.lineTo(x2, y2); ctx.stroke(); break;
                        case 'arrow': drawArrowHead(startX, startY, x2, y2); break;
                        case 'rect': ctx.strokeRect(startX, startY, x2 - startX, y2 - startY); break;
                        case 'filled-rect': ctx.fillRect(startX, startY, x2 - startX, y2 - startY); break;
                        case 'circle': { const rx=(x2-startX)/2, ry=(y2-startY)/2; ctx.beginPath(); ctx.ellipse(startX+rx, startY+ry, Math.abs(rx), Math.abs(ry), 0, 0, Math.PI*2); ctx.stroke(); break; }
                        case 'filled-circle': { const rx=(x2-startX)/2, ry=(y2-startY)/2; ctx.beginPath(); ctx.ellipse(startX+rx, startY+ry, Math.abs(rx), Math.abs(ry), 0, 0, Math.PI*2); ctx.fill(); break; }
                    }
                    ctx.globalAlpha = 1.0;
                };

                // ── Mouse Events ───────────────────────────────────────────
                canvas.addEventListener('mousedown', function(e) {
                    e.preventDefault();
                    if (currentTool === 'text') {
                        const [x, y] = getPos(e);
                        const ti = fieldRowEl.find('.paint-text-input');
                        ti.css({ left: Math.min(x, canvas.width - 290) + 'px', top: Math.min(y, canvas.height - 40) + 'px' })
                          .removeClass('d-none').focus().data({ tx: x, ty: y });
                        ti.off('keydown.paint').on('keydown.paint', function(ke) {
                            if (ke.key === 'Enter') {
                                const txt = $(this).val().trim();
                                if (txt) {
                                    saveState();
                                    ctx.globalAlpha = 1.0;
                                    ctx.font      = `${parseInt(fieldRowEl.find('.paint-size').val()) * 4}px Arial`;
                                    ctx.fillStyle = fieldRowEl.find('.paint-color').val();
                                    ctx.fillText(txt, $(this).data('tx'), $(this).data('ty'));
                                    commitInput();
                                }
                                $(this).val('').addClass('d-none');
                            }
                        });
                        return;
                    }
                    isDrawing = true;
                    [startX, startY] = getPos(e); [lastX, lastY] = [startX, startY];
                    saveState();
                    if (SHAPE_TOOLS.has(currentTool)) {
                        snapshot = ctx.getImageData(0, 0, canvas.width, canvas.height);
                    } else {
                        setStyle(); ctx.beginPath(); ctx.moveTo(startX, startY);
                    }
                });

                canvas.addEventListener('mousemove', function(e) {
                    if (!isDrawing) return;
                    const [x, y] = getPos(e);
                    if (FREE_TOOLS.has(currentTool)) {
                        setStyle();
                        ctx.beginPath(); ctx.moveTo(lastX, lastY); ctx.lineTo(x, y); ctx.stroke();
                        ctx.globalAlpha = 1.0; [lastX, lastY] = [x, y];
                    } else if (snapshot) {
                        ctx.putImageData(snapshot, 0, 0); drawShape(x, y);
                    }
                });

                canvas.addEventListener('mouseup', function(e) {
                    if (!isDrawing) return;
                    isDrawing = false;
                    if (SHAPE_TOOLS.has(currentTool)) {
                        const [x, y] = getPos(e);
                        if (snapshot) ctx.putImageData(snapshot, 0, 0);
                        drawShape(x, y); snapshot = null;
                    }
                    ctx.globalAlpha = 1.0; commitInput();
                });

                canvas.addEventListener('mouseleave', function() {
                    if (!isDrawing) return;
                    isDrawing = false;
                    if (snapshot) { ctx.putImageData(snapshot, 0, 0); if (history.length) history.pop(); snapshot = null; }
                    ctx.globalAlpha = 1.0; commitInput();
                });

                // ── Toolbar ────────────────────────────────────────────────
                const cursors = { pen:'crosshair', highlighter:'crosshair', line:'crosshair', arrow:'crosshair', rect:'crosshair', 'filled-rect':'crosshair', circle:'crosshair', 'filled-circle':'crosshair', text:'text', eraser:'cell' };
                fieldRowEl.find('.paint-tool-btn').on('click', function() {
                    fieldRowEl.find('.paint-tool-btn').removeClass('active');
                    $(this).addClass('active');
                    currentTool = $(this).data('tool');
                    canvas.style.cursor = cursors[currentTool] || 'crosshair';
                });

                // ── Undo / Redo ────────────────────────────────────────────
                fieldRowEl.find('.paint-undo-btn').on('click', function() {
                    if (!history.length) return;
                    redoStack.push(canvas.toDataURL());
                    const s = history.pop();
                    const img = new Image();
                    img.onload = () => { ctx.fillStyle='#fff'; ctx.fillRect(0,0,canvas.width,canvas.height); ctx.drawImage(img,0,0); commitInput(); };
                    img.src = s;
                });
                fieldRowEl.find('.paint-redo-btn').on('click', function() {
                    if (!redoStack.length) return;
                    history.push(canvas.toDataURL());
                    const s = redoStack.pop();
                    const img = new Image();
                    img.onload = () => { ctx.fillStyle='#fff'; ctx.fillRect(0,0,canvas.width,canvas.height); ctx.drawImage(img,0,0); commitInput(); };
                    img.src = s;
                });

                // ── Background Image ───────────────────────────────────────
                fieldRowEl.find('.paint-bg-btn').on('click', e => { e.stopPropagation(); fieldRowEl.find('.paint-bg-input').trigger('click'); });
                fieldRowEl.find('.paint-bg-input').on('change', function() {
                    const file = this.files[0];
                    if (file && file.type.startsWith('image/')) {
                        saveState();
                        const reader = new FileReader();
                        reader.onload = ev => {
                            const img = new Image();
                            img.onload = () => {
                                const sc = Math.min(canvas.width / img.width, canvas.height / img.height);
                                ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
                                ctx.drawImage(img, (canvas.width-img.width*sc)/2, (canvas.height-img.height*sc)/2, img.width*sc, img.height*sc);
                                commitInput();
                            };
                            img.src = ev.target.result;
                        };
                        reader.readAsDataURL(file);
                    }
                });

                // ── Clear ──────────────────────────────────────────────────
                fieldRowEl.find('.paint-clear-btn').on('click', function() {
                    saveState();
                    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
                    fieldRowEl.find('.field-options-input').val('');
                });
            }

            function initImageUpload(fieldRowEl) {
                const area      = fieldRowEl.find('.image-upload-area');
                const fileInput = fieldRowEl.find('.image-file-input');
                const preview   = fieldRowEl.find('.image-preview');
                if (area.data('img-init')) return;
                area.data('img-init', true);

                area.on('click', function(e) {
                    if (!$(e.target).is(fileInput)) fileInput.trigger('click');
                });

                fileInput.on('change', function() {
                    const file = this.files[0];
                    if (file && file.type.startsWith('image/')) {
                        const reader = new FileReader();
                        reader.onload = ev => {
                            preview.attr('src', ev.target.result).removeClass('d-none');
                            fieldRowEl.find('.field-options-input').val(ev.target.result);
                        };
                        reader.readAsDataURL(file);
                    }
                });

                area[0].addEventListener('dragover',  e => { e.preventDefault(); e.stopPropagation(); area.addClass('border-info'); });
                area[0].addEventListener('dragleave', () => area.removeClass('border-info'));
                area[0].addEventListener('drop', function(e) {
                    e.preventDefault(); e.stopPropagation();
                    area.removeClass('border-info');
                    const f = e.dataTransfer.files[0];
                    if (f && f.type.startsWith('image/')) {
                        const reader = new FileReader();
                        reader.onload = ev => {
                            preview.attr('src', ev.target.result).removeClass('d-none');
                            fieldRowEl.find('.field-options-input').val(ev.target.result);
                        };
                        reader.readAsDataURL(f);
                    }
                });
            }

            function initFileUpload(fieldRowEl) {
                const fileInput = fieldRowEl.find('.file-browser-input');
                const browseBtn = fieldRowEl.find('.file-browse-btn');
                const filesList = fieldRowEl.find('.selected-files-list');
                if (browseBtn.data('file-init')) return;
                browseBtn.data('file-init', true);

                browseBtn.on('click', e => { e.stopPropagation(); fileInput.trigger('click'); });

                fileInput.on('change', function() {
                    const files = Array.from(this.files);
                    if (files.length > 0) {
                        filesList.html(files.map(f => `<span class="badge bg-secondary-subtle border me-1"><i class="bi bi-file-earmark me-1"></i>${f.name}</span>`).join(''));
                        fieldRowEl.find('.field-options-input').val(files.map(f => f.name).join(','));
                    }
                });
            }


            // Form Submit validations
            $('#templateForm').submit(function(e) {
                let isValid = true;
                
                if (sectionsContainer.children('.section-card').length === 0) {
                    Swal.fire({
                        icon: 'warning',
                        title: 'Empty Template',
                        text: 'Please add at least one section.'
                    });
                    isValid = false;
                }
                
                sectionsContainer.children('.section-card').each(function() {
                    const secName = $(this).find('.section-name-input').val().trim();
                    if (!secName) {
                        Swal.fire({
                            icon: 'warning',
                            title: 'Validation Error',
                            text: 'All sections must have a name.'
                        });
                        isValid = false;
                        return false;
                    }
                    
                    const fields = $(this).find('.fields-container').children('.field-row');
                    if (fields.length === 0) {
                        Swal.fire({
                            icon: 'warning',
                            title: 'Empty Section',
                            text: `Please add at least one field to section "${secName}".`
                        });
                        isValid = false;
                        return false;
                    }
                });
                
                if (!isValid) {
                    e.preventDefault();
                }
            });
        });
    
