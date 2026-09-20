# EMR System — End-to-End Project Structure

> Generated 2026-09-20 from a read-through of the code at commit `4e1036a` (branch `main`, with uncommitted Lab work in the tree).
> This supersedes the structural parts of `DEV_REFERENCE.md` (last updated 2026-06-06), which predates the Lab, B2B, multi-company and IPD-master work. Where the two disagree, this file reflects the code. Items marked **(verify)** were inferred and not fully traced.

---

## 1. Big picture

```
 Browser
    │  Razor views, jQuery/Bootstrap, cookie auth
    ▼
┌──────────────────────────────  EMR.Web  (ASP.NET Core 9 MVC)  ─────────────────────────────┐
│ Controllers → ViewModels → Views                                                            │
│      │                                                                                      │
│      ├── EF Core (ApplicationDbContext)  ── users, roles, branches, companies, audit, etc.  │
│      ├── Dapper Services (IDbConnectionFactory) ── legacy/IPD/geography/clinical masters    │
│      └── ApiClients (named HttpClient "EmrApi") ──────────────┐                             │
└───────────────────────────────────────────────────────────────┼─────────────────────────────┘
                                                                ▼  JSON, ApiResponse<T>
┌──────────────────────────────  EMR.Api  (ASP.NET Core 9 Web API)  ─────────────────────────┐
│ Controllers → Services (Dapper) → stored procedures (usp_*)                                 │
└──────────────────────────────────────────────┬──────────────────────────────────────────────┘
                                               ▼
                         SQL Server  ·  database `Dev_EMR`  (shared by both apps)
```

**Rule of thumb:** EMR.Web renders pages and owns identity/session. EMR.Api owns the transactional and Lab logic. All business logic that touches Lab data lives in **SQL Server stored procedures**, not C#.

---

## 2. Repository layout

```
EMR_Web/
├── EMR_System.sln              Contains EMR.Web and EMR.Api ONLY
├── EMR.Web/                    MVC app (port 5124)
├── EMR.Api/                    REST API (port 5125 https / 5201 http)
├── SQLScripts/                 ~216 numbered migration scripts (source of truth for DB schema + SPs)
├── SqlRunner/                  Console tool: run a .sql file against Dev_EMR      (not in .sln)
├── SqlScriptRunner/            Console tool: run scripts / `--query` ad-hoc SQL   (not in .sln)
├── test_video/                 Scratch console app for video-config testing       (not in .sln)
├── DEV_REFERENCE.md            Older developer reference (June) — partly stale
├── REFERENCE.md                Original implementation notes (Feb) — stale
├── LAB_MASTERS_DESIGN_GUIDELINES.md   Rules every Lab Master must follow
├── QUERY_STRING_ENCRYPTION_ARCHITECTURE.md   AES-256 query-string design
├── DOCTOR_SCHEDULE_PLAN.md, Workflow_and_Approval_Plan.html   Planning docs
├── *.command, *.csx, run_update.csx, apply_sql.*   Dev launch / SQL helper scripts (see §11)
└── *.sql (root), sp.txt, scratch_lab_check.cs, test.*, *.log, cookies.txt   Ad-hoc scratch files
```

---

## 3. EMR.Web (presentation + identity)

| Folder | Contents | Count |
|---|---|---|
| `Controllers/` | One MVC controller per module | 89 |
| `Views/<Controller>/` | Razor views, one folder per controller; `Shared/` holds layout + partials | ~88 folders |
| `Models/Entities/` | EF/Dapper entity classes | ~85 |
| `Models/ViewModels/` | Page view models | ~75 |
| `Models/DTOs/` | Lab transport DTOs (`LabOrderDtos`, `LabReportingDtos`, `SampleCollectionDTOs`, `SampleTransferDtos`, `B2BBillingDtos`) | 6 |
| `ApiClients/` | `I<X>ApiClient` + `<X>ApiClient` pairs calling EMR.Api; `ApiClients/Models/` mirrors API shapes | ~108 files |
| `Services/` | Interface + implementation pairs (Dapper/EF); `Services/Geography/` | ~102 files |
| `Data/` | `ApplicationDbContext` (EF), `DbConnectionFactory` (Dapper) | 3 |
| `Migrations/` | EF Core migrations (only 6 exist — most schema is in `SQLScripts/`) | 19 files |
| `Filters/` | `GlobalAuditLogFilter` — logs every non-AJAX GET as a `PAGE_VIEW` audit row | 1 |
| `Middleware/` | `QueryStringDecryptionMiddleware` | 1 |
| `TagHelpers/` | `EncryptedQueryStringTagHelper` (`asp-encrypted-id`, `asp-encrypted-qs`) | 1 |
| `Extensions/` | `ClaimsPrincipalExtensions`, `QueryStringEncryptionExtensions` | 2 |
| `Utils/` | `AgeCalculator` | 1 |
| `wwwroot/` | `css/site.css`, `js/site.js`, `lib/`, `Images/`, `uploads/` (git-ignored, though 20 files are already tracked) | |

### Key shared views
`Views/Shared/_Layout.cshtml` (505 lines; the whole top-nav menu is hand-written here), `_AuthLayout`, `_PaymentModal` (941 lines; shared by OPD/Lab billing), `_LabMasterDashboard` (KPI banner required on every Lab Master list), `ApiDown`, `Error`.

### Composition root — `EMR.Web/Program.cs`
Registers, in order: MVC + `GlobalAuditLogFilter` → EF `ApplicationDbContext` → Dapper `IDbConnectionFactory` and the Dapper services → `HttpClient "Whereby"` (video) → `HttpClient "EmrApi"` and ~40 ApiClients → session (30-min idle) → Data Protection keys persisted **in the database** → cookie auth → singleton `IQueryStringEncryptionService`.

Middleware pipeline: `ForwardedHeaders` → HTTPS redirect → routing → **QueryStringDecryption** → session → authentication → **inline "session revalidation" middleware** → authorization → static assets → default route `{controller=Account}/{action=Login}/{id?}`.

---

## 4. EMR.Api (business + data)

| Folder | Contents | Count |
|---|---|---|
| `Controllers/` | `[ApiController]` REST controllers | 45 |
| `Services/` | Interface + Dapper implementation; each method = one `usp_*` call | ~85 files |
| `Models/` | Request/response models, `ApiResponse<T>` envelope | 45 |
| `Data/` | `DbConnectionFactory` (singleton) | 2 |
| `Middleware/` | `QueryStringDecryptionMiddleware` | 1 |

Everything is `Scoped` per request except the connection factory. Swagger UI is enabled in **all** environments, at `/swagger`.

**Response envelope** (all endpoints): `{ "success": bool, "message": string, "data": T }` via `ApiResponse<T>.Ok(...)` / `.Fail(...)`.

**Typical service method:**
```csharp
using var con = db.CreateConnection();
await con.QueryAsync<T>("usp_Api_<Thing>_GetList", new { ... }, commandType: CommandType.StoredProcedure);
```

### API controllers by domain
- **Lab masters:** `LabTestCategory`, `LabTestSubCategory`, `LabSampleType`, `LabTestMethod`, `LabUnit`, `Analyzers`, `LabInvestigation`, `LabInvestigationProfile`, `LabReferenceRange`, `LabSampleRejection`, `LabSampleRejectionReason`, `LabFranchise`, `LabRateCard`
- **Lab transactions:** `LabOrders`, `SampleCollection`, `SampleTransfer`, `LabReporting`, `B2BBilling`, `LabDashboard`
- **OPD / clinical:** `Patients`, `ServiceBookings`, `Vitals`, `PaymentSummary`, `Doctors`, `DoctorSchedules`, `EmrConsultations`, `PatientPortalApi`, `Reports`
- **Doctor finance:** `DoctorCommissionConfigs`, `DoctorDisbursals`, `DoctorSettlementReports`, `DoctorVisitProcessConfigs`
- **General / IPD / commercial masters:** `GeneralMasters`, `OpdMasters`, `IpdMasters`, `HospitalPackages`, `Corporates`, `CorporateHospitalRates`, `Insurances`, `InsuranceTariffs`, `GovernmentSchemes`, `DiscountTypes`, `ConsentMasters`, `Shifts`, `Housekeeping`

---

## 5. Data-access patterns (choose by module)

| Pattern | Where | Mechanism |
|---|---|---|
| **A. EF Core** | Identity & config: Users, Roles, UserBranches, Branches, Companies, HospitalSettings, AuditLogs, Email/SMTP/WhatsApp/Video config, Data Protection keys | `ApplicationDbContext` (85 DbSets) |
| **B. Dapper in Web** | Older/IPD masters (geography, departments, doctors, floors→beds, tariffs, OT, ICU, procedures…), patient registration, payments, ledger, cancellation/refund, email/WhatsApp/video services | `IDbConnectionFactory` in `EMR.Web/Data` |
| **C. Web → Api → SP** | **All Lab modules**, OPD reads, vitals, doctor schedules/commission, reports, patient portal, plus a growing set of masters | `ApiClient` → `EMR.Api` controller → service → `usp_Api_*` |

Several masters (Corporate, Insurance, GovernmentScheme, DiscountType, Doctor…) have **both** a Web-side service and an ApiClient registered — **(verify)** which one each controller actually uses before changing it.

Always wrap ApiClient calls in `try/catch (HttpRequestException)` → `View("ApiDown")`.

---

## 6. Authentication, tenancy & session

```
/Account/Login ─► SelectBranch ─► SelectRole ─► /Dashboard
```
- **Passwords:** BCrypt. **Cookie auth**, `ExpireTimeSpan = 1 hour` sliding (DEV_REFERENCE says 8h — code says 1h). Server session idle timeout 30 min.
- **Claims issued** (`AccountController`): `NameIdentifier`, `Name`, `DisplayName`, `CompanyId`, `BranchId`, `BranchName`, `BranchCode`, `IsHOBranch`, `ActiveRole`, `ClaimTypes.Role` (one per role), `IsSuperAdmin`, optional `ProfilePicturePath`.
- **Helpers** (`ClaimsPrincipalExtensions`): `GetUserId()`, `GetCurrentBranchId()`, `GetCompanyId()` (defaults to 1), `GetCompanyName/Code()`, `IsHOBranch()`, `IsSuperAdmin()`, `IsCompanyAdmin()`, `HasAnyRole()`, `GetActiveRole()`, `GetDisplayName()`.
- **Tenancy model (new since the June docs):** `CompanyMaster` → many `BranchMaster` → users mapped via `UserBranches`. Lab masters are scoped by **`CompanyId`**; transactions by **`BranchId`**; HO branches (`IsHOBranch`) get extra reach. Corporate rate lists are global (nullable `branch_id`).
- **Per-request revalidation:** inline middleware in `Program.cs` re-checks on every non-static, non-account request that the user's branch is still active and the `ActiveRole` still exists; otherwise it signs out.
- **EMR.Api has no authentication or authorization** (`[Authorize]` / auth middleware absent). It trusts the caller and relies on `branchId`/`companyId`/`userId` passed in requests. See §12.

### Query-string encryption
`?q=<AES-256-CBC, Base64Url>` is decrypted by middleware in **both** apps into ordinary query values, so actions still bind `int id` normally. Views emit links with `asp-encrypted-id` / `asp-encrypted-qs`. Details: `QUERY_STRING_ENCRYPTION_ARCHITECTURE.md`.

### Audit
`GlobalAuditLogFilter` logs page views (GETs, non-AJAX). Write operations are logged explicitly via `IAuditLogService.LogAsync(module, action, description, …)`. `2046_enhance_audit_logs_tracking.sql` extended the table.

---

## 7. Module map (menu → controller → API)

### Operations
| Menu | Web controller | API |
|---|---|---|
| OPD Dashboard, Patient Registration, Service Booking, Token Mgmt | `OPD` | `Patients`, `ServiceBookings`, `PaymentSummary` |
| Doctor Roster / Schedules | `DoctorRoster`, `DoctorSchedules` | `DoctorSchedules` |
| Patient Vitals | `Vitals` | `Vitals` |
| Doctor Commission & Disbursals; settlement RPT-01…08 | `DoctorDisbursal`, `DoctorSettlementReports` | `DoctorDisbursals`, `DoctorSettlementReports` |
| Bill Cancellation & Refund (`moduleCode` = OPD / LAB) | `BillCancellation` | Web-side `CancellationService` (Dapper) |
| EMR consultation, templates, investigations, medications | `EmrTemplates`, `EmrInvestigations`, `EmrMedications` | `EmrConsultations` |
| Video consultation (Whereby), WhatsApp, Email | `VideoConfig`, `WhatsAppConfig`, `SmtpConfig`, `EmailTemplate`, `EmailLogs` | Web-side services |
| Patient Portal (separate login) | `PatientPortal` | `PatientPortalApi` |
| IPD | `IPD` — **placeholder only**; the IPD *masters* (ward, bed, OT, ICU, tariffs) are done | `IpdMasters` |

### Lab (largest and most active area)
**Transaction pipeline**
```
Order booking ─► Sample collection ─► (optional) Sample transfer ─► Report entry ─► Validate / Approve
 LabOrderBooking   SampleCollection      SampleTransfer              LabReporting
```
| Step | Web controller (key actions) | API route | Main tables |
|---|---|---|---|
| Booking B2C/B2B, payment, print bill, barcode | `LabOrderBooking` (B2CBooking, B2BBooking, SaveBookingWithPayment, PrintBill…) | `api/LabOrders` | `LabOrder`, `LabOrderItem` |
| Sample collect / recollect / reject, print barcode | `SampleCollection` | `api/SampleCollection` | `SampleCollection`, `SampleCollectionStatus` (PENDING, COLLECTED, RE_COLLECT, REJECTED) |
| Send to another branch, receive, worksheet print | `SampleTransfer` | `api/SampleTransfer` (eligible, execute, history, target-branches, receivable, worksheet-data, receive) | cols on `SampleCollection` + `SampleTransferAudit` |
| Result entry, delta check, validate | `LabReporting` | `api/LabReporting` (headers, detail, save-entry, update-sample-status) | `labentrydetails`, `Reportentrystatus` (DRAFT → REPORT_ENTRY → REPORT_VALIDATED / RE_COLLECTED), `LabReportTestRemarks` |
| B2B franchise wallet, invoices, multi-bill settlement | `LabOrderBooking` (B2BInvoices, B2BSettlement, FranchiseWalletTopUp…) | `api/B2BBilling` | `LabFranchiseMaster`, `LabFranchiseWallet(+Transaction)`, credit-limit table |
| Lab dashboard | `LabDashboard` | `api/LabDashboard/stats` | — |

Sample transfer routes a sample to a target branch and **hides it from the source branch's reporting worklist** (`usp_LabReporting_GetHeaderList` was changed in `2064`).

**Lab masters** (Masters → Lab Master): Test Category, Test Sub Category, Sample Type, Test Method, Unit, Analyzer, Investigation, Investigation Profile, Reference Range (multi-range bulk insert, "common for all" flag), Sample Rejection Reason, Franchise Setup, and three rate lists (B2C, Franchise, Corporate — include packages/profiles).

### Masters & admin
Company, Branch, User (incl. `IsLogisticsBoy`), Roles/Access, Hospital Settings; geography (Country→State→District→City→Area); Doctor, Referral Doctor, Speciality, Sub-Speciality, Department, Clinical Unit; Building, Floor, Ward, Nursing Station, Room, Bed Category, Bed, Tariff Category, Bed/Room Tariff; Hospital Service (+rates), Procedure (+tariff), OT (+equipment, tariff), Anaesthesia, ICU; Corporate, Insurance/TPA, Government Scheme, Discount Type, Shift, Consent, Housekeeping, Hospital Package.

### Reports
`Reports` (Daily Collection, Patient Register, OPD; IPD/Patient/Billing/Pharmacy entries exist in the menu) and `DoctorSettlementReports`.

---

## 8. One vertical slice, end to end (Lab Test Category)

Every Lab master repeats this shape — copy it when adding one.

| Layer | File |
|---|---|
| View | `EMR.Web/Views/LabTestCategories/{Index,Create,Edit,Details}.cshtml` (+ `_LabMasterDashboard`) |
| ViewModel | `EMR.Web/Models/ViewModels/LabTestCategoryViewModels.cs` |
| Controller | `EMR.Web/Controllers/LabTestCategoriesController.cs` (`[Authorize]`, uses `User.GetCompanyId()`) |
| ApiClient | `EMR.Web/ApiClients/ILabTestCategoryApiClient.cs`, `LabTestCategoryApiClient.cs`, `ApiClients/Models/LabTestCategoryModels.cs` |
| Registration | `EMR.Web/Program.cs` under `// EMR.Api HTTP clients` |
| API controller | `EMR.Api/Controllers/LabTestCategoryController.cs` → route `api/lab-test-categories` |
| API service | `EMR.Api/Services/{ILabTestCategoryService,LabTestCategoryService}.cs` |
| API models | `EMR.Api/Models/LabTestCategoryModels.cs` |
| Registration | `EMR.Api/Program.cs` |
| DB | `SQLScripts/20xx_*.sql` → table `LabTestCategoryMaster`, procs `usp_Api_LabTestCategoryMaster_{GetList,GetById,Create,Update,…}` |

---

## 9. Database & SQL scripts

- **Server / DB:** `103.178.113.61,1232` / `Dev_EMR` — **both** apps now use the same server (DEV_REFERENCE lists two different IPs; it's outdated).
- **Convention:** `SQLScripts/NN_*.sql` for early core (01–108); **Lab scripts start at 2000** and run to `2086` today. Scripts are idempotent (`IF NOT EXISTS …`) and start with `USE [Dev_EMR]`. Add new work as the next number (`2087_…`).
- Unnumbered files (`fix_*`, `temp_*`, `insert_templates`, `Clear_OPD_Transactions`) are one-offs.
- `01_schema.sql` / `02_seed_data.sql` are the base schema and seed; **later scripts alter it**, so a fresh DB needs all scripts applied in order. Only 6 EF migrations exist and they don't cover most tables.
- **Gotcha:** SPs must be created with `SET QUOTED_IDENTIFIER ON` (see `2062_fix_quoted_identifier_all_stored_procedures.sql`).
- **Column-name quirks** (mapped in `ApplicationDbContext`): `HospitalSettings.HospitalName` ↔ `HotelName`; `BranchID` upper-case D; tables `roles`, `Userroles`, `Branchmaster` are lower/mixed case; Lab tables mix PascalCase and snake-style columns (`Category_ID`, `Display_Order`).
- Recent script themes: 2044–2050 franchise + reporting tables; 2051–2059 B2B billing/invoice/settlement; 2060–2063 rate cards + package fixes; 2064–2068, 2073 sample transfer; 2069–2071 reference ranges; 2074–2076 roles (Technician, Finance, Manager; roles no longer branch-scoped); 2077–2086 reporting flow, rejection & recollect.

---

## 10. Lab Master design rules (from `LAB_MASTERS_DESIGN_GUIDELINES.md`)

1. **Code field first** on every form — read-only, auto-generated (`LCAT0001`, `LSUBCAT0001`, `SMP0001`, `MTH0001`, `UNT0001`).
2. **Display Order only on Test Category**; all others default `Display_Order = 1` and hide it.
3. Every Lab Master `Index` embeds `_LabMasterDashboard`.
4. **Departments filtered to `DeptType = 'Lab'`** in the SP, the API and the Web controller — stated as "must never change".
5. Lab SQL scripts numbered from 2000.
6. Duplicate rules: name unique per branch/category/department as tabulated in that doc.

---

## 11. Running & tooling

```bash
# Terminal 1
cd EMR.Api && dotnet run          # https://localhost:5125  (Swagger at /swagger)
# Terminal 2
cd EMR.Web && dotnet run          # http://localhost:5124 ; https profile: https://localhost:7099
```
- `EMR.Web/appsettings.json → ApiSettings:BaseUrl` must point at the API (`https://localhost:5125`). The Web `HttpClient` **accepts any TLS cert** (dev convenience).
- Apply a SQL script: `dotnet run --project SqlRunner -- --file SQLScripts/2087_x.sql`. `SqlScriptRunner --query "<sql>"` runs ad-hoc queries.
- The `*.command` launchers **hard-code `/Users/purojitbhar/My work/EMR_Dev/…`** — another machine's path. They won't work here without editing.
- `appsettings.Development.json` is git-ignored.

---

## 12. Risks & inconsistencies spotted while mapping

**Security (recommend fixing first)**
1. **Live `sa` database password is committed in plaintext** in `EMR.Web/appsettings.json`, `EMR.Api/appsettings.json`, `SqlRunner/Program.cs`, `SqlScriptRunner/Program.cs` and `test_video/Program.cs`. It's in git history, so rotate it, then move to user-secrets / env vars. Connecting as `sa` from an app is itself over-privileged.
2. **EMR.Api is unauthenticated.** Anyone who can reach port 5125 can read/write any branch's data and pass any `userId`. Add an API key/JWT or restrict it to the Web host at the network level.
3. `DataProtectionKeys/key-*.xml` and `cookies.txt` are tracked in git (keys are also stored in the DB, so the file is redundant).
4. Swagger is exposed in every environment; TLS validation is disabled for the API client; `AllowedHosts: *`; forwarded headers trust any proxy.

**Correctness / hygiene**
5. Menu links `Medicines / Index` (`_Layout.cshtml` line ~215) but there is **no `MedicinesController`** — dead link (`EmrMedications` is the real one).
6. Two menu entries for **Unit Master** (`LabUnits`) — one under General Masters, one under Lab Master (intentional per the guidelines doc, but same controller).
7. `SqlRunner`, `SqlScriptRunner`, `test_video` aren't in the `.sln`; root has many scratch files (`test*.cs/js/csx`, `update_sp*.sql`, `reports_sps_fixed{,2,3}.sql`, logs).
8. CORS `AllowedOrigins:EmrWeb` is `https://localhost:5124` but the HTTPS profile is `7099` — harmless for server-to-server calls, misleading otherwise.
9. `LabOrderBookingController` is ~2,900 lines (booking, geo lookups, B2B invoicing, settlement, wallet in one controller) — the main candidate for splitting.
10. Duplicate data paths (Web service **and** ApiClient) for several masters; DEV_REFERENCE says everything Web-side is Dapper/EF and clinical reads are API, which is no longer the dividing line.
11. Working tree has ~45 modified and several untracked files (Lab reporting/sample transfer/roles work, scripts `2072`–`2086`) not yet committed.

---

## 13. Adding a feature — checklist

**New Lab (or any API-backed) master**
1. SQL: next-numbered script — table + `usp_Api_<X>_{GetList,GetById,Create,Update,…}`; `SET QUOTED_IDENTIFIER ON`; Lab dept filter if relevant.
2. `EMR.Api`: models → `I<X>Service`/`<X>Service` → controller (`ApiResponse<T>`) → register in `Program.cs`.
3. `EMR.Web`: `ApiClients/Models/<X>Models.cs` → `I<X>ApiClient` + impl → register under `// EMR.Api HTTP clients` → ViewModels → controller (`[Authorize]`, `User.GetCompanyId()`, catch `HttpRequestException`, `IAuditLogService`) → views (`asp-encrypted-id` links) → menu entry in `_Layout.cshtml`.
4. Follow the Lab design rules in §10 and the dashboard partial.

**New identity/config entity (EF):** entity → `DbSet` + mapping in `ApplicationDbContext` → `dotnet ef migrations add` (or an idempotent SQL script, as the team mostly does) → controller/views/menu.
