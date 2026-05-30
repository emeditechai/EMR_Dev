# Doctor Schedule Scheduler — End-to-End Implementation Plan

> **Status**: Planned — Not yet implemented
> **Created**: 8 May 2026
> **Scope**: OPD only (IPD future-ready via `ScheduleType` column)

---

## Overview

Build a per-doctor weekly schedule configurator backed by SQL tables + stored procedures, a new EMR.Api controller, a new EMR.Web API client, and two UI pages — plus integrating slot selection into the existing OPD booking flow.

**Entry Points:**
- Doctor Master → Action dropdown → **"Doctor Schedule Configure"** (per-doctor)
- Master → General → **"Doctor Schedule"** (global list of all doctors' schedules)

**Architecture**: All data access via Stored Procedures → Dapper (EMR.Api) → HttpClient (EMR.Web). No direct DB queries from EMR.Web.

---

## Phase 1 — Database Layer (`SQLScripts/33_doctor_schedule.sql`)

### 1.1 — `DoctorScheduleMaster` Table

| Column | Type | Notes |
|---|---|---|
| `ScheduleId` | INT IDENTITY PK | |
| `DoctorId` | INT FK → DoctorMaster | |
| `BranchId` | INT FK → Branchmaster | |
| `RoomId` | INT NULL FK → DoctorRoomMaster | Optional |
| `DayOfWeek` | TINYINT | 1=Mon … 7=Sun |
| `StartTime` | TIME | |
| `EndTime` | TIME | |
| `SlotDurationMinutes` | INT | e.g. 10, 15, 20, 30 |
| `MaxPatientsPerSlot` | INT DEFAULT 1 | |
| `MaxPatientsPerSession` | INT NULL | Overall cap per session |
| `ScheduleType` | VARCHAR(20) DEFAULT 'OPD' | Future: 'IPD' |
| `EffectiveFrom` | DATE | |
| `EffectiveTo` | DATE NULL | NULL = open-ended |
| `IsActive` | BIT DEFAULT 1 | |
| `CreatedBy` | INT FK → Users | |
| `CreatedDate` | DATETIME DEFAULT GETDATE() | |
| `ModifiedBy` | INT NULL | |
| `ModifiedDate` | DATETIME NULL | |

- Index: `(DoctorId, BranchId, DayOfWeek, IsActive)` — supports slot lookup at booking time
- Multiple rows per `DoctorId + BranchId + DayOfWeek` are **allowed** (morning + evening sessions)

### 1.2 — `DoctorScheduleException` Table

| Column | Type | Notes |
|---|---|---|
| `ExceptionId` | INT IDENTITY PK | |
| `DoctorId` | INT FK → DoctorMaster | |
| `BranchId` | INT FK → Branchmaster | |
| `ExceptionDate` | DATE | |
| `Reason` | NVARCHAR(500) NULL | |
| `ExceptionType` | VARCHAR(20) DEFAULT 'Leave' | 'Leave' / 'Holiday' |
| `IsActive` | BIT DEFAULT 1 | |
| `CreatedBy` | INT FK → Users | |
| `CreatedDate` | DATETIME DEFAULT GETDATE() | |

- Unique constraint: `(DoctorId, BranchId, ExceptionDate)`

### 1.3 — Stored Procedures

| SP Name | Purpose |
|---|---|
| `usp_Api_DoctorSchedule_GetByDoctor` | All active schedules for doctor+branch, ordered by DayOfWeek, StartTime |
| `usp_Api_DoctorSchedule_GetById` | Single schedule detail |
| `usp_Api_DoctorSchedule_Upsert` | Create (ScheduleId=0) or Update (ScheduleId>0); validates overlap |
| `usp_Api_DoctorSchedule_Delete` | Soft-delete (IsActive=0); warns if future bookings reference this ScheduleId |
| `usp_Api_DoctorSchedule_GetAvailableSlots` | Given @DoctorId, @BranchId, @Date — verify no exception, compute slot list, LEFT JOIN PatientOPDService to count booked, return IsAvailable per slot |
| `usp_Api_DoctorScheduleException_GetByDoctor` | All exceptions for doctor+branch (optional date range) |
| `usp_Api_DoctorScheduleException_Upsert` | Insert or update exception |
| `usp_Api_DoctorScheduleException_Delete` | Soft delete by ExceptionId |

**Validations enforced inside each SP:**
- `StartTime < EndTime`
- `SlotDurationMinutes` divides evenly into session window
- `EffectiveFrom <= EffectiveTo`
- Overlapping schedule on same `DoctorId + BranchId + DayOfWeek` → return error code
- Doctor active check + effective date range check on slot queries

### 1.4 — `usp_Api_DoctorSchedule_GetAvailableSlots` Logic (detail)

```
INPUT:  @DoctorId INT, @BranchId INT, @Date DATE

1. Resolve @DayOfWeek = DATEPART(WEEKDAY, @Date) normalized to 1=Mon..7=Sun
2. Check DoctorScheduleException for (DoctorId, BranchId, ExceptionDate=@Date, IsActive=1)
   → If found, return HasException=1 with Reason; return empty Slots list
3. Find all active DoctorScheduleMaster rows for (DoctorId, BranchId, DayOfWeek, IsActive=1)
   where EffectiveFrom <= @Date AND (EffectiveTo IS NULL OR EffectiveTo >= @Date)
4. For each schedule row, generate slot times:
   SlotTime = StartTime, StartTime+Duration, StartTime+2*Duration, … while < EndTime
5. For each slot, COUNT PatientOPDService where
   ScheduleId=@ScheduleId AND CAST(VisitDate AS DATE)=@Date AND AppointmentTime=SlotTime
6. Return per slot: SlotTime (HH:mm), BookedCount, MaxPerSlot, IsAvailable=(BookedCount < MaxPerSlot)
   Also check MaxPatientsPerSession: if total booked for session >= MaxPatientsPerSession, mark all remaining slots unavailable
```

---

## Phase 2 — Extend `PatientOPDService` (`SQLScripts/34_opd_schedule_integration.sql`)

1. `ALTER TABLE PatientOPDService ADD ScheduleId INT NULL, AppointmentTime TIME NULL`
2. `ALTER TABLE PatientOPDService ADD CONSTRAINT FK_POPDSvc_Schedule FOREIGN KEY (ScheduleId) REFERENCES DoctorScheduleMaster(ScheduleId)`
3. Update `usp_Patient_Create` — add params `@ScheduleId INT NULL`, `@AppointmentTime TIME NULL`; store on PatientOPDService row
4. Update `usp_Patient_Update` — same additions
5. Update `usp_Api_ServiceBooking_GetByBranch` — include `AppointmentTime` in result set for display in booking list

> **Backward compatibility**: Both columns are nullable — all existing bookings remain valid without any data migration.

---

## Phase 3 — EMR.Api Layer

### 3.1 — `EMR.Api/Models/DoctorScheduleModels.cs`

| Class | Key Fields |
|---|---|
| `DoctorScheduleListItem` | ScheduleId, DoctorId, DayOfWeek, DayName, StartTime, EndTime, SlotDurationMinutes, MaxPatientsPerSlot, MaxPatientsPerSession, RoomName, ScheduleType, EffectiveFrom, EffectiveTo, IsActive |
| `DoctorScheduleDetail` | Extends ListItem + RoomId |
| `DoctorScheduleUpsertRequest` | All writable fields + RequestedByUserId |
| `AvailableSlot` | SlotTime (string "HH:mm"), BookedCount, MaxPerSlot, IsAvailable |
| `AvailableSlotsResult` | Date, DoctorId, DoctorName, Slots: List\<AvailableSlot\>, HasException, ExceptionReason |
| `DoctorScheduleExceptionListItem` | ExceptionId, DoctorId, ExceptionDate, Reason, ExceptionType |
| `DoctorScheduleExceptionUpsertRequest` | DoctorId, BranchId, ExceptionDate, Reason, ExceptionType, RequestedByUserId |

### 3.2 — `EMR.Api/Services/IDoctorScheduleService.cs` + `DoctorScheduleService.cs`

```csharp
Task<IEnumerable<DoctorScheduleListItem>> GetByDoctorAsync(int doctorId, int? branchId);
Task<DoctorScheduleDetail?>               GetByIdAsync(int scheduleId);
Task<int>                                 UpsertAsync(DoctorScheduleUpsertRequest request);
Task<(bool Success, string? Warning)>     DeleteAsync(int scheduleId, int deletedBy);
Task<AvailableSlotsResult>                GetAvailableSlotsAsync(int doctorId, int branchId, DateOnly date);
Task<IEnumerable<DoctorScheduleExceptionListItem>> GetExceptionsByDoctorAsync(int doctorId, int? branchId, DateOnly? from, DateOnly? to);
Task<int>                                 UpsertExceptionAsync(DoctorScheduleExceptionUpsertRequest request);
Task<bool>                                DeleteExceptionAsync(int exceptionId, int deletedBy);
```

All methods: Dapper (`IDbConnectionFactory`) → Stored Procedures. No inline SQL.

### 3.3 — `EMR.Api/Controllers/DoctorSchedulesController.cs`

```
GET    /api/doctorschedules?doctorId=X&branchId=Y
GET    /api/doctorschedules/{id}
POST   /api/doctorschedules                               (ScheduleId=0 in body → create)
PUT    /api/doctorschedules/{id}                          (update)
DELETE /api/doctorschedules/{id}?deletedBy=Y

GET    /api/doctorschedules/availableslots?doctorId=X&branchId=Y&date=YYYY-MM-DD

GET    /api/doctorschedules/exceptions?doctorId=X&branchId=Y&from=YYYY-MM-DD&to=YYYY-MM-DD
POST   /api/doctorschedules/exceptions
DELETE /api/doctorschedules/exceptions/{id}?deletedBy=Y
```

All responses wrapped in `ApiResponse<T>` (same pattern as all existing controllers).
DELETE returns `ApiResponse<object>` with a `Warning` field if future bookings exist.

### 3.4 — `EMR.Api/Program.cs`

```csharp
builder.Services.AddScoped<IDoctorScheduleService, DoctorScheduleService>();
```

---

## Phase 4 — EMR.Web Layer

### 4.1 — `EMR.Web/ApiClients/DoctorScheduleApiClient.cs`

- Interface: `IDoctorScheduleApiClient` — mirrors all EMR.Api endpoints
- Implementation: uses named `HttpClient "EmrApi"` — identical pattern to existing `DoctorApiClient`
- Deserializes `ApiResponse<T>`; returns null / empty on API-down gracefully

### 4.2 — `EMR.Web/Models/ViewModels/DoctorScheduleViewModels.cs`

| Class | Purpose |
|---|---|
| `DoctorScheduleIndexViewModel` | Per-doctor row: HasSchedule bool, schedule count, list of active day names |
| `DoctorScheduleConfigureViewModel` | Doctor info + List\<DoctorScheduleListItem\> grouped by DayOfWeek + exceptions list |
| `DoctorScheduleFormViewModel` | Add/edit slot form model (used in modal): all schedule fields + validation attributes |
| `ExceptionFormViewModel` | Leave/holiday entry: DoctorId, BranchId, ExceptionDate, Reason, ExceptionType |

### 4.3 — `EMR.Web/Controllers/DoctorSchedulesController.cs`

| Action | Method | Description |
|---|---|---|
| `Index` | GET | All active doctors with schedule summary (calls GetByDoctorAsync for each) |
| `Configure(int doctorId)` | GET | Full config page for one doctor; loads schedules + exceptions + rooms dropdown |
| `Upsert` | POST AJAX | Add/edit a schedule slot; returns `{ success, scheduleId, error }` |
| `Delete(int id)` | POST AJAX | Soft-delete a slot; returns `{ success, warning }` |
| `AddException` | POST AJAX | Add leave/holiday exception; returns `{ success, error }` |
| `DeleteException(int id)` | POST AJAX | Remove an exception |
| `GetAvailableSlots` | GET AJAX | Proxy to EMR.Api; consumed by OPD booking slot picker |

### 4.4 — `EMR.Web/Views/DoctorSchedules/Index.cshtml`

- **Stat cards** (3): Total Doctors / Doctors With Schedule / Doctors Without Schedule
- **Table columns**: #, Doctor Name, Speciality, Branch, Scheduled Days (day pills Mon–Sun, highlighted if active), Status badge, Action ("Configure")
- "Configure" → `asp-action="Configure" asp-route-doctorId="@item.DoctorId"`
- Style: mirrors `Doctors/Index.cshtml` (Bootstrap 5, stat-card, table-hover, bi icons)
- Shows API-down error view if `IDoctorApiClient` is unreachable

### 4.5 — `EMR.Web/Views/DoctorSchedules/Configure.cshtml`

**Page Structure:**

```
[Breadcrumb: Doctor Schedule > {DoctorName}]

[Doctor Info Card]
  Name | Speciality | Branch | Status badge

[Weekly Schedule Tabs]  Mon | Tue | Wed | Thu | Fri | Sat | Sun
  Each tab:
    [Session cards — one per DoctorScheduleMaster row for that day]
      StartTime – EndTime | Slot: X min | Max: Y/slot | Room: Z
      [Edit] [Delete] buttons
    [＋ Add Session button]

[Exception / Leave Panel]
  [Date picker] [Reason input] [Type: Leave/Holiday] [Add button]
  [Table of upcoming exceptions with × delete button per row]
```

**Schedule Slot Modal (Add / Edit):**

| Field | Control | Notes |
|---|---|---|
| Branch | Text (read-only, pre-filled) | |
| Day of Week | Text (read-only, pre-filled from tab) | |
| Start Time | `<input type="time">` | Required |
| End Time | `<input type="time">` | Required, must be > StartTime |
| Slot Duration | `<select>` 5/10/15/20/30/60 min | Required |
| Max Patients / Slot | `<input type="number" min="1">` | Required |
| Max Patients / Session | `<input type="number" min="1">` | Optional overall cap |
| Room | `<select>` from DoctorRoomMaster filtered by BranchId | Optional |
| Effective From | `<input type="date">` | Required |
| Effective To | `<input type="date">` | Optional, must be ≥ EffectiveFrom |

Save → AJAX POST to `DoctorSchedules/Upsert` → refresh only the active day tab panel.

---

## Phase 5 — OPD Booking Integration

### 5.1 — `EMR.Web/Views/OPD/PatientRegistration.cshtml`

In the OPD Service section, after doctor dropdown + visit date field:

```
[Doctor selected + Visit Date entered]
    ↓  AJAX → /DoctorSchedules/GetAvailableSlots?doctorId=X&branchId=Y&date=Z
    ↓
[Slot Picker rendered]
    ○ 09:00 AM  (1 / 3 booked)       ← selectable
    ○ 09:15 AM  (2 / 3 booked)       ← selectable
    ● 09:30 AM  (Full)               ← disabled, greyed out
    ○ 09:45 AM  (0 / 3 booked)       ← selectable
```

- **No schedule configured** → info banner: *"No schedule configured for this doctor on this day. Token will be assigned automatically."* — booking continues without ScheduleId.
- **Doctor on leave** → warning banner: *"Doctor is on leave on this date. Please select another date or doctor."* — Save button disabled.
- Hidden inputs `ScheduleId` + `AppointmentTime` populated on slot selection; remain empty if no schedule.

### 5.2 — `EMR.Web/Services/PatientService.cs`

Pass `ScheduleId` (nullable int) and `AppointmentTime` (nullable `"HH:mm"` string) into `usp_Patient_Create` and `usp_Patient_Update`.

---

## Phase 6 — Navigation & Entry Points

### 6.1 — `EMR.Web/Views/Doctors/Index.cshtml` — Action Dropdown

Add after "Edit" `<li>`, before the `<hr>` divider:

```html
<li>
    <a class="dropdown-item"
       asp-controller="DoctorSchedules"
       asp-action="Configure"
       asp-route-doctorId="@item.DoctorId">
        <i class="bi bi-calendar2-week me-2"></i>Doctor Schedule Configure
    </a>
</li>
```

### 6.2 — `EMR.Web/Views/Shared/_Layout.cshtml` — Master > General Submenu

Add immediately after the Doctor Master `<li>`:

```html
<li>
    <a class="dropdown-item"
       asp-controller="DoctorSchedules"
       asp-action="Index">
        <i class="bi bi-calendar2-week-fill me-2"></i>Doctor Schedule
    </a>
</li>
```

### 6.3 — `EMR.Web/Program.cs`

```csharp
builder.Services.AddScoped<IDoctorScheduleApiClient, DoctorScheduleApiClient>();
```

---

## Validation Rules

| Scenario | Where enforced | Rule |
|---|---|---|
| Schedule overlap | SP + client-side warning | Same DoctorId+BranchId+DayOfWeek+Effective period: time ranges must not overlap |
| Time logic | SP + modal JS | StartTime must be < EndTime |
| Slot fit | SP + modal JS | (EndTime − StartTime) must be divisible by SlotDurationMinutes; truncate last partial slot |
| Effective dates | SP + modal validation | EffectiveFrom ≤ EffectiveTo; EffectiveTo NULL = open-ended |
| Room branch | SP | RoomId must belong to same BranchId |
| Delete schedule | SP (soft-warn) | If future PatientOPDService rows reference ScheduleId → return warning message, proceed with delete |
| Exception date | SP + JS | Cannot add exception for a date in the past |
| Slot availability | SP (GetAvailableSlots) | IsAvailable = (BookedCount < MaxPatientsPerSlot) |
| Doctor on leave | SP (GetAvailableSlots) | DoctorScheduleException exists for doctor+branch+visitDate → HasException=true |
| No schedule | Controller/View | No DoctorScheduleMaster row for selected day → advisory banner; ScheduleId + AppointmentTime remain NULL |
| Session cap | SP (GetAvailableSlots) | If MaxPatientsPerSession set → total booked across all slots for schedule+date must be < MaxPatientsPerSession |

---

## Files Summary

### Create

| File | Purpose |
|---|---|
| `SQLScripts/33_doctor_schedule.sql` | `DoctorScheduleMaster` + `DoctorScheduleException` tables + all 8 SPs |
| `SQLScripts/34_opd_schedule_integration.sql` | ALTER PatientOPDService + update `usp_Patient_Create`, `usp_Patient_Update`, `usp_Api_ServiceBooking_GetByBranch` |
| `EMR.Api/Models/DoctorScheduleModels.cs` | All request/response DTOs |
| `EMR.Api/Services/IDoctorScheduleService.cs` | Service interface |
| `EMR.Api/Services/DoctorScheduleService.cs` | Dapper implementation (SPs only, no inline SQL) |
| `EMR.Api/Controllers/DoctorSchedulesController.cs` | REST API controller with ApiResponse<T> wrapper |
| `EMR.Web/ApiClients/DoctorScheduleApiClient.cs` | IDoctorScheduleApiClient interface + implementation |
| `EMR.Web/Models/ViewModels/DoctorScheduleViewModels.cs` | All view models |
| `EMR.Web/Controllers/DoctorSchedulesController.cs` | MVC controller with AJAX actions |
| `EMR.Web/Views/DoctorSchedules/Index.cshtml` | Global schedule list page |
| `EMR.Web/Views/DoctorSchedules/Configure.cshtml` | Per-doctor weekly config page |

### Modify

| File | Change |
|---|---|
| `EMR.Api/Program.cs` | Register `IDoctorScheduleService → DoctorScheduleService` |
| `EMR.Web/Program.cs` | Register `IDoctorScheduleApiClient → DoctorScheduleApiClient` |
| `EMR.Web/Views/Shared/_Layout.cshtml` | Add "Doctor Schedule" link under Master > General submenu |
| `EMR.Web/Views/Doctors/Index.cshtml` | Add "Doctor Schedule Configure" item to action dropdown |
| `EMR.Web/Views/OPD/PatientRegistration.cshtml` | Add slot picker AJAX section after doctor + date selection |
| `EMR.Web/Services/PatientService.cs` | Pass `ScheduleId` + `AppointmentTime` to patient SPs |

---

## Verification Checklist

- [ ] Run `33_doctor_schedule.sql` → `DoctorScheduleMaster` + `DoctorScheduleException` tables exist with all FK constraints and unique index
- [ ] Run `34_opd_schedule_integration.sql` → `PatientOPDService.ScheduleId` + `.AppointmentTime` columns exist; all existing rows unaffected (NULL values)
- [ ] `GET /api/doctorschedules?doctorId=1&branchId=1` → 200, empty array
- [ ] `POST /api/doctorschedules` body: `{ doctorId:1, branchId:1, dayOfWeek:1, startTime:"09:00", endTime:"12:00", slotDurationMinutes:15, maxPatientsPerSlot:3, effectiveFrom:"2026-05-09", requestedByUserId:1 }` → 201 with new ScheduleId
- [ ] `GET /api/doctorschedules/availableslots?doctorId=1&branchId=1&date=2026-05-11` (next Monday) → 12 slots (09:00–11:45), all IsAvailable=true
- [ ] Navigate Master → General → Doctor Schedule → Index page loads, shows doctors with schedule indicators
- [ ] Doctor Master → Action dropdown → "Doctor Schedule Configure" → Configure page loads for that doctor
- [ ] Add Monday morning session via modal → slot card appears in Monday tab without page reload
- [ ] Add leave exception for next Monday → available slots endpoint returns `HasException=true`, empty slots
- [ ] OPD PatientRegistration: select doctor + date with schedule → slot picker renders below date field
- [ ] Select a slot → hidden `ScheduleId` + `AppointmentTime` fields are populated
- [ ] Complete booking → `PatientOPDService` row has `ScheduleId` + `AppointmentTime` populated (verify in DB)
- [ ] Book the same slot until MaxPatientsPerSlot is reached → slot renders as "Full" / disabled for next patient
- [ ] Verify existing bookings (ScheduleId IS NULL) still display correctly in ServiceBooking list

---

## Design Decisions

| Decision | Rationale |
|---|---|
| Slots computed dynamically | No pre-created slot rows; avoids bulk insert and stale-data problems |
| Multiple sessions per day allowed | Supports morning + evening naturally (e.g. 09:00–12:00 + 16:00–19:00); just add two rows for the same day |
| Token number unchanged | `usp_OPD_GetNextTokenNo` (daily sequential) preserved for backward compat; `AppointmentTime` is a purely additive scheduling dimension |
| Nullable ScheduleId + AppointmentTime | Full backward compatibility — all existing bookings remain valid without data migration |
| ScheduleType column | Future-proofs schema for IPD scheduling; IPD excluded from this phase |
| No new auth roles | Reuses existing cookie authentication and role model for this phase |
| No slot pre-booking lock | Slot count checked at submission time (optimistic); race condition risk is minimal at clinic scale |
