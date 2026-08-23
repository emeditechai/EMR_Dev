# Lab Masters Design & Form Standardizations Rulebook

This document serves as the project-wide architectural reference for all **Lab Master** modules within the EMR System (`EMR.Api` and `EMR.Web`).

---

## 1. Core Form Layout & Field Rules

### A. Auto-Generated Code Field Position
- **Rule**: Every entry and edit form for Lab Masters MUST position the **Code field as the very first field** at the top-left of the form layout.
- **Behavior**:
  - On **Create Form**: Displayed as a disabled/read-only input stating `Auto-generated on save (e.g. LCAT0001, LSUBCAT0001, SMP0001, MTH0001, UNT0001)`.
  - On **Edit Form**: Displayed as a read-only monospace text field with the existing code value.

### B. Display Order Field Rule
- **Rule**: The **Display Order** numeric input field is **RESTRICTED EXCLUSIVELY to Test Category Master**.
- **Enforcement**:
  - **Test Category Master**: Display Order remains a mandatory numeric input field on Create and Edit forms to control ordering on pathology request forms and patient reports.
  - **All Other Lab Masters** (Test Sub Category, Sample Type, Test Method, Unit Master): Display Order MUST NOT be shown on Create or Edit forms. The system defaults `Display_Order = 1` internally.

---

## 2. Common Lab Master Summary Dashboard

- **Rule**: All 5 Lab Master list pages (`Index.cshtml`) MUST embed the unified `_LabMasterDashboard.cshtml` summary banner at the top of the page.
- **Metrics Included**:
  1. **Test Categories Count**: Total & Active Test Categories.
  2. **Test Sub Categories Count**: Total & Active Sub Categories.
  3. **Sample Types Count**: Total & Active Sample Types.
  4. **Test Methods Count**: Total & Active Test Methods.
  5. **Units Count**: Total & Active Lab Measurement Units.

---

## 3. Summary Matrix of Lab Masters

| Master Module | Menu Location | Code Field (1st Pos) | Display Order Field | Duplicate Validation Rule |
| :--- | :--- | :--- | :--- | :--- |
| **Test Category Master** | Master > Lab Master > Test Category Master | Yes (`LCAT0001`) | **YES (Mandatory)** | Unique `Category_Name` per Branch |
| **Test Sub Category Master** | Master > Lab Master > Test Sub Category Master | Yes (`LSUBCAT0001`) | **NO (Hidden/Default 1)** | Unique `SubCategory_Name` per Category & Branch |
| **Sample Type Master** | Master > Lab Master > Sample Type Master | Yes (`SMP0001`) | **NO (Hidden/Default 1)** | Unique `Sample_Name` + `Container_Type` + `Volume` per Branch |
| **Test Method Master** | Master > Lab Master > Test Method Master | Yes (`MTH0001`) | **NO (Hidden/Default 1)** | Unique `Method_Name` per Department & Branch |
| **Unit Master** | Master > General Master & Lab Master > Unit Master | Yes (`UNT0001`) | **NO (Hidden/Default 1)** | Unique `Unit_Name` per Branch |

---

## 4. Implementation Guidelines for Developers

1. **Creating/Editing Lab Master Views**:
   - Always place the Code input in `col-md-6` or `col-md-12` at line 1 of the form inside `<div class="row g-3">`.
   - Never add `<input asp-for="Display_Order" />` unless developing for `LabTestCategories`.
   - Always include `@await Html.PartialAsync("_LabMasterDashboard", dashboardModel)` above the search/filter card in `Index.cshtml`.
