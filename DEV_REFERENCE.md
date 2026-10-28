# EMR System — Developer Reference
> **Last Updated:** 2026-06-06  
> This document is the single source of truth for all development work on the EMR system.  
> Keep it updated as the system evolves.

---

## 1. Solution Overview

```
EMR_System.sln
├── EMR.Web          ASP.NET Core 9 MVC — the user-facing web app
└── EMR.Api          ASP.NET Core 9 Web API — back-end data service
```

### Architecture Philosophy
- **EMR.Web** is the primary application. It handles authentication, session, and all rendered Razor views.
- **EMR.Api** is a headless REST API. It owns the heavier read/write operations (patients, vitals, service bookings, payment summaries) and exposes them as JSON.
- **EMR.Web → EMR.Api** communication uses a named `HttpClient` (`"EmrApi"`) with typed interface-based wrapper classes called **ApiClients**.
- Data that is purely administrative (users, branches, roles, masters) is handled **directly by EMR.Web** via **Entity Framework Core (EF Core)** on the `ApplicationDbContext`.
- Clinical/transactional data (patients, vitals, OPD bills, payments) is handled by **EMR.Api** via **Dapper** stored procedures.

---

## 2. Tech Stack

| Concern | Technology |
|---|---|
| Framework | ASP.NET Core 9 / .NET 9 |
| Web UI | Razor Views (MVC), Vanilla CSS + JS |
| EF Core ORM | SQL Server (admin/master tables only, in EMR.Web) |
| Dapper | SQL Server (clinical/transaction tables, in both projects) |
| Authentication | Cookie Authentication (`CookieAuthenticationDefaults`) |
| Password Hashing | BCrypt.Net-Next |
| API Docs | Swashbuckle/Swagger (EMR.Api only) |
| Solution File | `EMR_System.sln` |

---

## 3. Port & URL Configuration

| App | Dev URL | Config Key |
|---|---|---|
| EMR.Web | `https://localhost:5124` | (launch profile) |
| EMR.Api | `https://localhost:5125` | (launch profile) |

- `EMR.Web/appsettings.json` → `ApiSettings:BaseUrl` points to EMR.Api
- `EMR.Api/appsettings.json` → `AllowedOrigins:EmrWeb` points to EMR.Web (CORS)
- The `HttpClientHandler` in EMR.Web accepts any server certificate (dev only — self-signed certs).

---

## 4. Database

| Setting | Value |
|---|---|
| Server (Web) | `103.178.113.61,1232` |
| Server (Api) | `198.38.81.123` |
| Database | `Dev_EMR` |
| User | `sa` |
| Options | `TrustServerCertificate=True; MultipleActiveResultSets=True` |

> ⚠️ For production: move the connection string to a secrets store (Azure Key Vault / env vars).  
> Both EMR.Web and EMR.Api connect to the **same** `Dev_EMR` database.

### EF Core Migrations (EMR.Web only)
```bash
cd EMR.Web
dotnet ef migrations add <MigrationName>
dotnet ef database update
```

---

## 5. Project Structure — EMR.Web

```
EMR.Web/
├── ApiClients/             Typed HTTP clients that call EMR.Api
│   ├── Models/             DTOs mirroring EMR.Api response shapes
│   ├── DoctorApiClient.cs
│   ├── PatientApiClient.cs
│   ├── ServiceBookingApiClient.cs
│   ├── PaymentSummaryApiClient.cs
│   └── VitalApiClient.cs
├── Controllers/            MVC Controllers (one per module)
├── Data/
│   ├── ApplicationDbContext.cs   EF Core context (admin/master tables)
│   └── DbConnectionFactory.cs   IDbConnection factory for Dapper
├── Extensions/
│   └── ClaimsPrincipalExtensions.cs   GetUserId(), GetCurrentBranchId(), etc.
├── Migrations/             EF Core migration files
├── Models/
│   ├── Entities/           C# entity classes mapped to DB tables
│   └── ViewModels/         ViewModels passed to Razor views
├── Services/               Business-logic services (Dapper-based)
│   └── Geography/          Country/State/District/City/Area services
├── SQLScripts/             (empty — main scripts are in root /SQLScripts)
├── Views/                  Razor views organized per controller
│   └── Shared/             _Layout.cshtml, _PaymentModal.cshtml, ApiDown.cshtml
├── wwwroot/                Static assets (CSS, JS, lib, images, uploads)
├── Program.cs              DI registration + middleware pipeline
└── appsettings.json
```

---

## 6. Project Structure — EMR.Api

```
EMR.Api/
├── Controllers/            REST API controllers
│   ├── DoctorsController.cs
│   ├── PatientsController.cs
│   ├── ServiceBookingsController.cs
│   ├── PaymentSummaryController.cs
│   └── VitalsController.cs
├── Data/
│   └── DbConnectionFactory.cs   IDbConnection factory for Dapper
├── Models/                 Request/Response models + ApiResponse<T> wrapper
│   ├── ApiResponse.cs
│   ├── DoctorModels.cs
│   ├── PatientModels.cs
│   ├── PaymentModels.cs
│   ├── ServiceBookingModels.cs
│   └── VitalModels.cs
├── Services/               Service interfaces + implementations (Dapper)
├── Program.cs              DI + CORS + Swagger setup
└── appsettings.json
```

---

## 7. EMR.Api — REST Endpoints

### Standard Response Envelope
All endpoints return `ApiResponse<T>`:
```json
{
  "success": true,
  "message": "...",
  "data": { ... }
}
```

### Patients  `api/patients`
| Method | Route | Description |
|---|---|---|
| GET | `/api/patients?branchId=&page=&pageSize=&search=` | Paged patient list |
| GET | `/api/patients/{id}` | Single patient detail |
| POST | `/api/patients` | Register new patient |
| PUT | `/api/patients/{id}` | Update patient |

### Service Bookings  `api/servicebookings`
| Method | Route | Description |
|---|---|---|
| GET | `/api/servicebookings?branchId=&fromDate=&toDate=&page=&pageSize=&search=` | Paged OPD service list |
| GET | `/api/servicebookings/{id}` | OPD service detail (with line items) |

### Vitals  `api/vitals`
| Method | Route | Description |
|---|---|---|
| GET | `/api/vitals?patientId=&page=&pageSize=` | Paged vital history |
| GET | `/api/vitals/{id}` | Single vital record |
| GET | `/api/vitals/latest/{patientId}` | Latest vital for patient |
| GET | `/api/vitals/print/{patientId}?branchId=` | Print data bundle |
| POST | `/api/vitals` | Create vital (BMI auto-calculated) |
| PUT | `/api/vitals/{id}` | Update vital (BMI re-calculated) |
| DELETE | `/api/vitals/{id}?deletedByUserId=` | Soft-delete vital |

### Payment Summary  `api/paymentsummary`
| Method | Route | Description |
|---|---|---|
| GET | `/api/paymentsummary?moduleCode=OPD&moduleRefId=123` | Payment summary for a bill |

### Doctors  `api/doctors`
| Method | Route | Description |
|---|---|---|
| GET | `/api/doctors` | Doctor list |
| GET | `/api/doctors/{id}` | Doctor detail |

### Swagger UI
Available at `https://localhost:5125/` (root) in Development mode.

---

## 8. EMR.Web — Controller Map

| Controller | Route Prefix | Data Source | Notes |
|---|---|---|---|
| `AccountController` | `/Account` | EF Core | Login, Branch selection, Logout |
| `DashboardController` | `/Dashboard` | EF Core | Summary counts |
| `OPDController` | `/OPD` | EF Core + EMR.Api | Patient registration, service booking, print bill |
| `VitalsController` | `/Vitals` | EMR.Api only | Vital entry, history, print |
| `DoctorsController` | `/Doctors` | EF Core + Dapper | Doctor master CRUD |
| `UsersController` | `/Users` | EF Core | User master CRUD |
| `BranchesController` | `/Branches` | EF Core | Branch master CRUD |
| `HospitalSettingsController` | `/HospitalSettings` | EF Core | Branch-wise settings |
| `ServicesController` | `/Services` | Dapper | Service master CRUD |
| `DepartmentsController` | `/Departments` | Dapper | Department master |
| `DoctorSpecialitiesController` | `/DoctorSpecialities` | Dapper | Speciality master |
| `DoctorRoomsController` | `/DoctorRooms` | Dapper | Room master |
| `FloorsController` | `/Floors` | Dapper | Floor master |
| `AreasController` | `/Areas` | Dapper | Area master |
| `CitiesController` | `/Cities` | Dapper | City master |
| `DistrictsController` | `/Districts` | Dapper | District master |
| `StatesController` | `/States` | Dapper | State master |
| `CountriesController` | `/Countries` | Dapper | Country master |
| `AuditLogsController` | `/AuditLogs` | EF Core | Audit log viewer |
| `AccessController` | `/Access` | EF Core | Role/Access management |
| `IPDController` | `/IPD` | — | Placeholder (not implemented) |

---

## 9. Data Access Patterns

### Pattern A — EF Core (Admin / Master Tables)
Used in: `AccountController`, `DashboardController`, `UsersController`, `BranchesController`, `HospitalSettingsController`, `AuditLogsController`

```csharp
// Injected via constructor
ApplicationDbContext dbContext

// Usage
var branch = await dbContext.BranchMasters.FindAsync(id);
```

Tables managed by EF Core:
- `Users`, `Roles`, `UserBranches`, `UserRoles`
- `BranchMaster`, `HospitalSettings`, `AuditLogs`
- All patient registration lookup masters: `ReligionMaster`, `RelationMaster`, `IdentificationTypeMaster`, `OccupationMaster`, `MaritalStatusMaster`
- `PatientMaster`, `PatientOPDService`, `PatientOPDServiceItem`
- `PaymentHeader`, `PaymentLineItem`, `PaymentDetail`, `PaymentMethodMaster`

### Pattern B — Dapper via Service (Geographic + Clinical Masters)
Used in: Geography services, Doctor/Department/Floor/Room services, PatientService (write side), PaymentService

```csharp
// Injected via IDbConnectionFactory
IDbConnectionFactory dbFactory

// Usage
using var conn = dbFactory.CreateConnection();
var result = await conn.QueryAsync<T>("StoredProcName", new { Param1 = value }, commandType: CommandType.StoredProcedure);
```

### Pattern C — EMR.Api via ApiClient (Clinical Reads)
Used in: `OPDController`, `VitalsController`

```csharp
// Injected via named HttpClient "EmrApi"
IPatientApiClient patientApiClient
IVitalApiClient   vitalApiClient

// Usage (always wrapped in try/catch HttpRequestException)
try
{
    var result = await patientApiClient.GetByBranchAsync(branchId, page, pageSize, search);
}
catch (HttpRequestException)
{
    return View("ApiDown");   // or RedirectToAction("ApiUnavailable", "Home")
}
```

---

## 10. ApiClient Layer (EMR.Web → EMR.Api)

Each ApiClient is an interface + implementation pair under `EMR.Web/ApiClients/`.

| Interface | Implementation | Calls |
|---|---|---|
| `IDoctorApiClient` | `DoctorApiClient` | GET `/api/doctors` |
| `IPatientApiClient` | `PatientApiClient` | GET `/api/patients` |
| `IServiceBookingApiClient` | `ServiceBookingApiClient` | GET `/api/servicebookings` |
| `IPaymentSummaryApiClient` | `PaymentSummaryApiClient` | GET `/api/paymentsummary` |
| `IVitalApiClient` | `VitalApiClient` | All CRUD `/api/vitals` |

**Adding a new API-backed feature:**
1. Create interface + implementation in `EMR.Web/ApiClients/`
2. Add DTO models in `EMR.Web/ApiClients/Models/`
3. Register in `Program.cs` under `// EMR.Api HTTP clients`
4. Mirror the corresponding API models in `EMR.Api/Models/`

---

## 11. Authentication & Session

### Flow
```
/Account/Login → validates credentials (BCrypt) 
              → if multiple branches → /Account/SelectBranch 
              → claims enriched with BranchId, BranchName, ActiveRole, IsSuperAdmin 
              → /Dashboard/Index
```

### Claims Issued
| Claim Type | Value |
|---|---|
| `ClaimTypes.NameIdentifier` | UserId (int) |
| `ClaimTypes.Name` | Username |
| `"DisplayName"` | User's full name |
| `"BranchId"` | Selected BranchId (int) |
| `"BranchName"` | Branch display name |
| `"ActiveRole"` | Role name string |
| `"IsSuperAdmin"` | `"true"` if super admin |

### Helper Extension Methods (`ClaimsPrincipalExtensions`)
```csharp
User.GetUserId()           // → int
User.GetCurrentBranchId()  // → int?
User.IsSuperAdmin()        // → bool
User.HasAnyRole("Admin", "Receptionist")  // → bool (SuperAdmin always true)
User.GetActiveRole()       // → string
```

### Session Middleware (Program.cs)
On every non-static, non-account request:
1. Validates that `BranchId` claim is still active for the user
2. Validates that `ActiveRole` claim still exists in DB
3. If invalid → signs out and redirects to `/Account/Login`

Cookie options: 8-hour sliding expiration.

---

## 12. EMR.Web — Services Layer

All services are Dapper-based (direct SQL / stored procedures):

| Service | Interface | Key Methods |
|---|---|---|
| `PatientService` | `IPatientService` | Create, Update, UpdateDemographics, GetById, SearchByPhone/Code/Name, GetLatestOPDService, CreateServiceBookingOnly |
| `PatientVitalService` | `IPatientVitalService` | CRUD for vitals (local, used before API was built) |
| `PaymentService` | `IPaymentService` | GetPaymentForBill, settlement logic |
| `DoctorService` | `IDoctorService` | CRUD for doctor master |
| `DoctorConsultingFeeService` | `IDoctorConsultingFeeService` | Fee lookup by doctor+branch |
| `ServiceService` | `IServiceService` | Service master lookup |
| `Geography services` | `ICountry/State/District/City/AreaService` | GetActive, GetByParent |
| `AuditLogService` | `IAuditLogService` | LogAsync(module, action, description) |
| `PasswordHasherService` | `IPasswordHasherService` | BCrypt verify |

---

## 13. EF Core — ApplicationDbContext

**File:** `EMR.Web/Data/ApplicationDbContext.cs`

Key DbSets:
```csharp
DbSet<User>                    Users
DbSet<Role>                    Roles
DbSet<BranchMaster>            BranchMasters
DbSet<UserBranch>              UserBranches
DbSet<UserRole>                UserRoles
DbSet<AuditLog>                AuditLogs
DbSet<HospitalSettings>        HospitalSettings
DbSet<ReligionMaster>          ReligionMasters
DbSet<RelationMaster>          RelationMasters
DbSet<IdentificationTypeMaster> IdentificationTypeMasters
DbSet<OccupationMaster>        OccupationMasters
DbSet<MaritalStatusMaster>     MaritalStatusMasters
DbSet<PatientMaster>           PatientMasters
DbSet<PatientOPDService>       PatientOPDServices
DbSet<PatientOPDServiceItem>   PatientOPDServiceItems
DbSet<PaymentMethodMaster>     PaymentMethodMasters
DbSet<PaymentHeader>           PaymentHeaders
DbSet<PaymentLineItem>         PaymentLineItems
DbSet<PaymentDetail>           PaymentDetails
```

Notable column mappings (non-convention):
- `HospitalSettings.HospitalName` → column `HotelName`
- `BranchMaster.BranchId` → column `BranchID`
- `Role.BranchId` → column `BranchID`
- `UserBranch.BranchId` → column `BranchID`
- `HospitalSettings.BranchId` → column `BranchID`
- `roles` table → lowercase `roles`; `Userroles` table → `Userroles`

---

## 14. SQL Scripts Inventory

All scripts are in `/SQLScripts/` (root level):

| Script | Purpose |
|---|---|
| `01_schema.sql` | Base schema |
| `02_seed_data.sql` | Seed data (roles, users, branch) |
| `03_geography_masters.sql` | Geography table schema |
| `04_india_geography_sample_data.sql` | India geography seed |
| `05_doctor_speciality.sql` | Speciality master |
| `07_doctor_master.sql` | Doctor master |
| `08_user_master_profile_empcode.sql` | User profile fields |
| `09_hospital_settings_*` | HospitalSettings table changes |
| `10_floor_master.sql` | Floor master |
| `11_doctor_room_master.sql` | Doctor room master |
| `12_service_master.sql` | Service master |
| `13_doctor_consulting_fees.sql` | Consulting fee map |
| `14_patient_registration.sql` | PatientMaster schema |
| `14_payment_tables.sql` | Payment schema |
| `15_west_bengal_geography.sql` | WB geography seed |
| `16_patient_opd_service.sql` | OPD service schema |
| `17_patient_stored_procedures.sql` | SP: patient read/write |
| `18_opd_bill_line_items.sql` | Bill line item schema |
| `22_usp_Patient_Create_Update_v2.sql` | SP: patient create/update v2 |
| `23_patient_code_branch_fy.sql` | Branch+FY-based patient code |
| `24_patient_address_field.sql` | Address field |
| `25_relation_master.sql` | Relation master |
| `26_patient_vitals.sql` | Vitals schema |
| `27_api_stored_procedures.sql` | SPs for API service bookings/patients |
| `28_service_master_isregistration.sql` | IsRegistration flag |
| `29_hospital_settings_opd_validity.sql` | OPD validity days setting |
| `30_vital_api_stored_procedures.sql` | SPs for vitals API |
| `31_vital_canmodify_flag.sql` | CanModify flag on vitals |
| `32_vital_create_use_getdate.sql` | GETDATE() for vital creation |

---

## 15. Module Status

| Module | Status | Notes |
|---|---|---|
| Login & Auth | ✅ Complete | Cookie auth, BCrypt, multi-branch |
| Branch Selection | ✅ Complete | Post-login branch picker |
| Dashboard | ✅ Complete | Summary stats via EF Core |
| User Master | ✅ Complete | CRUD + branch/role mapping |
| Branch Master | ✅ Complete | CRUD |
| Role & Access | ✅ Complete | Role-based access control |
| Hospital Settings | ✅ Complete | Per-branch settings, logo, OPD validity |
| Geography Masters | ✅ Complete | Country/State/District/City/Area |
| Doctor Speciality | ✅ Complete | |
| Department Master | ✅ Complete | |
| Doctor Master | ✅ Complete | CRUD + room mapping + consulting fees |
| Floor & Room Master | ✅ Complete | |
| Service Master | ✅ Complete | IsRegistration flag |
| OPD Patient Registration | ✅ Complete | New patient + OPD bill + line items |
| OPD Patient List | ✅ Complete | Via EMR.Api (paged, searchable) |
| OPD Service Booking | ✅ Complete | Via EMR.Api (paged, detail, print) |
| New Service Booking | ✅ Complete | Book for existing patient |
| Print Bill | ✅ Complete | Via EMR.Api + hospital settings |
| Patient Vitals | ✅ Complete | Full CRUD via EMR.Api |
| Vital History | ✅ Complete | Paged, per patient |
| Vital Print | ✅ Complete | Hospital-branded vital sheet |
| Payment Modal | ✅ Complete | Shared `_PaymentModal.cshtml` |
| Audit Logs | ✅ Complete | All CRUD operations logged |
| IPD | ⬜ Not Started | Controller stub only |

---

## 16. Business Rules

1. **Super Admin**: Username `admin` is treated as super admin; bypasses role checks. Claims: `IsSuperAdmin=true`.
2. **Branch Scope**: All transactional data (patients, OPD, vitals) is scoped to `BranchId` from the user's session claim.
3. **Multi-branch Users**: Users can be mapped to multiple branches. Branch must be selected after login.
4. **Multi-role Users**: Users can have multiple roles. One is active per session.
5. **Patient Uniqueness**: Phone number + Relation must be unique per active patient.
6. **Patient Code**: Auto-generated using Branch + Financial Year format (see `23_patient_code_branch_fy.sql`).
7. **OPD Registration Validity**: `HospitalSettings.OpdRegistrationValidityDays` controls re-registration validity. Checked in `OPDController.GetRegistrationValidity()`.
8. **BMI Calculation**: Auto-calculated server-side in EMR.Api when vitals are created or updated.
9. **Vital CanModify**: Vitals older than a configured window become read-only (`CanModify = false`).
10. **Soft Deletes**: Vitals use soft-delete (flag). Patients use `IsActive` flag.
11. **File Uploads**: Identification documents saved to `wwwroot/uploads/patients/`. Allowed: PDF, JPG, JPEG, PNG.

---

## 17. Shared Views / Partials

| Partial | Purpose |
|---|---|
| `_Layout.cshtml` | Main app layout with sidebar nav, user info |
| `_AuthLayout.cshtml` | Minimal layout for login page |
| `_PaymentModal.cshtml` | Payment entry modal (shared across OPD/IPD) |
| `ApiDown.cshtml` | Shown when EMR.Api is unreachable |
| `Error.cshtml` | Generic error page |

---

## 18. Adding a New Feature — Checklist

### New module fully via EMR.Web + EF Core
1. Create Entity in `EMR.Web/Models/Entities/`
2. Add `DbSet<>` in `ApplicationDbContext`
3. Add EF Core migration
4. Create ViewModel in `EMR.Web/Models/ViewModels/`
5. Create Controller in `EMR.Web/Controllers/`
6. Create Views in `EMR.Web/Views/<ControllerName>/`
7. Add nav link in `_Layout.cshtml`
8. Add audit log calls: `await auditLogService.LogAsync("Module", "Action", "description")`

### New module via EMR.Api
1. **In EMR.Api:**
   - Add model in `EMR.Api/Models/`
   - Add service interface + implementation in `EMR.Api/Services/`
   - Register service in `EMR.Api/Program.cs`
   - Add controller in `EMR.Api/Controllers/`
   - Write stored procedures in a new numbered SQL script
2. **In EMR.Web:**
   - Add ApiClient interface + implementation in `EMR.Web/ApiClients/`
   - Add DTO models in `EMR.Web/ApiClients/Models/`
   - Register in `EMR.Web/Program.cs` under `// EMR.Api HTTP clients`
   - Create controller, views, nav link

### Data dictionary (every schema change)
`Docs/DataDictionary/Data_Dictionary_OPD_LAB_Pharmacy_Accounts_Inventory.docx` is regenerated from the database by
`Tools/datadictionary/update_data_dictionary.py` (see `Tools/datadictionary/README.md`).
1. In the SQL script, add `MS_Description` to new tables and to columns holding codes (e.g. `P = paid, U = unpaid`).
2. Name reference columns after the parent key (`PatientId`, `LabOrderId` ...) or declare the foreign key.
3. Place new tables in their module in `Tools/datadictionary/dd_config.py` (a new module gets its own entry).
4. Apply the script to the database, then commit — the post-commit hook (`sh Tools/datadictionary/install_hooks.sh`,
   once per machine) refreshes the document and commits it. Without the hook, run the updater by hand.

---

## 19. Run Instructions

### Development (both projects side by side)
```bash
# Terminal 1 — Start EMR.Api
cd /Users/abhikporel/dev/EMR_Web/EMR.Api
dotnet run

# Terminal 2 — Start EMR.Web
cd /Users/abhikporel/dev/EMR_Web/EMR.Web
dotnet run
```

Then open the URL printed by EMR.Web (typically `https://localhost:5124`).

### API Only
```bash
cd EMR.Api
dotnet run
# Swagger UI at https://localhost:5125
```

---

## 20. Known Quirks & Gotchas

- `HospitalSettings.HospitalName` is stored in column `HotelName` (legacy column name — mapped in EF config).
- EMR.Web's `HttpClient` for EMR.Api uses `DangerousAcceptAnyServerCertificateValidator` for dev — do not ship this to production.
- The `Userroles` table name is lowercase in DB but the entity is `UserRole`. EF mapping handles this.
- `BranchID` column (uppercase D) is mapped explicitly in multiple entities.
- `ApiDown.cshtml` is shown when `HttpRequestException` is caught from any ApiClient call. Always wrap ApiClient calls in `try/catch (HttpRequestException)`.
- Vitals: `RecordedOn` uses `GETDATE()` (local server time), not `GETUTCDATE()` — see `32_vital_create_use_getdate.sql`.
- Patient list page (`OPD/Index`) uses **EMR.Api strictly** — no DB fallback.
- Service booking suggestions search (autocomplete) also goes through EMR.Api.

---

## 21. Next Development Areas (Backlog)

- **IPD Module** — inpatient admission, discharge, ward management
- **Doctor Schedule** — appointment calendar (see `DOCTOR_SCHEDULE_PLAN.md`)
- **Prescription / Clinical Notes** — post-consultation records
- **Lab / Diagnostics** — test orders and results
- **Reports** — patient census, revenue reports, OPD summary
- **Dashboard Enhancements** — live counters via EMR.Api, charts
- **Role-based Menu Rendering** — show/hide sidebar items based on role
- **MFA** — `RequiresMFA` column exists on Users table but not enforced
- **Pagination UX** — consistent pagination component across all lists
- **Notifications** — appointment reminders, payment due alerts

---

*End of DEV_REFERENCE.md*
