using System.Data;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services.BulkUpload;

public class RefSpeciality { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; }
public class RefDoctorDept { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public string Type { get; set; } = ""; }
public class RefExecutive { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public string Type { get; set; } = ""; }

/// <summary>
/// Doctor Master (Doctors/Index) upload, one template for referral doctors (IsReferralDoctor = 1) and one for the
/// others (OPD / IPD doctors). Saves the same columns and branch / department maps as the Doctor form
/// (EMR.Web DoctorService); logins, suspension and consulting fees stay on the Doctor screens.
/// BulkContext.IsHO carries "may assign several branches" (Administrator / super admin at the Head Office branch,
/// as on the form); otherwise a doctor gets only the signed-in branch.
/// </summary>
public class DoctorBulkHandler(IDbConnectionFactory db, LabBulkLookups lookups, bool referral) : ILabBulkUploadHandler
{
    public const string ReferralModule = "doctor-referral";
    public const string OpdIpdModule = "doctor-opd-ipd";

    private const string CId = "Doctor ID";
    private const string CPrefix = "Prefix";
    private const string CName = "Doctor Name";
    private const string CGender = "Gender";
    private const string CDob = "Date of Birth";
    private const string CEmail = "Email ID";
    private const string CPhone = "Phone Number";
    private const string CLicense = "Medical License No";
    private const string CPrimary = "Primary Speciality";
    private const string CSecondary = "Secondary Speciality";
    private const string CJoining = "Joining Date";
    private const string CExecutive = "Marketing Executive";
    private const string CStatus = "Status";
    private static readonly string[] CDepts = ["Department 1", "Department 2", "Department 3", "Department 4", "Department 5"];
    private static readonly string[] CBranches = ["Branch 1", "Branch 2", "Branch 3"];

    private const string RefSpecialitySheet = "REF_Speciality";
    private const string RefDeptSheet = "REF_Department";
    private const string RefBranchSheet = "REF_Branch";
    private const string RefExecutiveSheet = "REF_MarketingExecutive";

    private static readonly string[] Prefixes = ["Dr.", "Prof.", "Mr.", "Ms."];
    private static readonly string[] Genders = ["Male", "Female", "Other"];
    // same rule as DoctorFormViewModel.PhoneNumber
    private static readonly Regex PhoneRegex = new(@"^(?:\+?91[\- ]?|0)?[6-9]\d{9}$", RegexOptions.Compiled);
    private static readonly Regex EmailRegex = new(@"^[^@\s]+@[^@\s]+\.[^@\s]+$", RegexOptions.Compiled);

    public string Module => referral ? ReferralModule : OpdIpdModule;
    public string Title => referral ? "Referral Doctor" : "Doctor (OPD / IPD)";
    private string OtherTemplate => referral ? "OPD / IPD Doctors" : "Referral Doctors";

    private sealed class ExistingDoctor
    {
        public int DoctorId { get; set; }
        public string? NamePrefix { get; set; }
        public string FullName { get; set; } = "";
        public string? Gender { get; set; }
        public DateTime? DateOfBirth { get; set; }
        public string? EmailId { get; set; }
        public string? PhoneNumber { get; set; }
        public string? MedicalLicenseNo { get; set; }
        public int PrimarySpecialityId { get; set; }
        public int? SecondarySpecialityId { get; set; }
        public DateTime? JoiningDate { get; set; }
        public bool IsActive { get; set; }
        public bool IsReferralDoctor { get; set; }
        public int? MarketingExecutiveId { get; set; }
        public bool HasLogin { get; set; }
        public bool Visible { get; set; }
        public List<int> BranchIds { get; set; } = [];
        public List<int> DeptIds { get; set; } = [];
    }

    /// <summary>The values bulk upload writes; also used to detect unchanged rows.</summary>
    private sealed record DoctorValues(
        string Prefix, string Name, string Gender, DateTime? Dob, string Email, string Phone, string? License,
        int PrimaryId, int? SecondaryId, DateTime? Joining, int? ExecutiveId, bool Active, List<int> BranchIds, List<int> DeptIds);

    private static DoctorValues From(ExistingDoctor d) => new(
        d.NamePrefix ?? "Dr.", d.FullName, d.Gender ?? "", d.DateOfBirth, d.EmailId ?? "", d.PhoneNumber ?? "",
        string.IsNullOrWhiteSpace(d.MedicalLicenseNo) ? null : d.MedicalLicenseNo, d.PrimarySpecialityId, d.SecondarySpecialityId,
        d.JoiningDate, d.MarketingExecutiveId, d.IsActive, [.. d.BranchIds.Order()], [.. d.DeptIds.Order()]);

    private static string Norm(string? s) => (s ?? "").Trim().ToUpperInvariant();
    /// <summary>Last 10 digits of a phone number, so "+91 98300 12345" and "9830012345" match.</summary>
    private static string Digits(string? phone) { var d = Regex.Replace(phone ?? "", @"\D", ""); return d.Length > 10 ? d[^10..] : d; }

    // ── lookups ──────────────────────────────────────────────────────────────────────────────────────────────
    private async Task<List<T>> QueryAsync<T>(string sql, object args)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<T>(sql, args)).ToList();
    }

    private async Task<BulkLookup<RefSpeciality>> SpecialitiesAsync(int companyId) => new(
        await QueryAsync<RefSpeciality>("""
            SELECT SpecialityId AS Id, ISNULL(SpecialityCode, '') AS Code, SpecialityName AS Name
            FROM dbo.DoctorSpecialityMaster
            WHERE IsActive = 1 AND (CompanyId = @CompanyId OR CompanyId IS NULL)
            ORDER BY SpecialityName
            """, new { CompanyId = companyId }),
        x => x.Id, x => string.Equals(x.Code, x.Name, StringComparison.OrdinalIgnoreCase) ? "" : x.Code, x => x.Name);

    /// <summary>
    /// Department types a doctor of this template may be given, as the modules list doctors (data dictionary:
    /// DoctorDepartmentMap -> DepartmentMaster.DeptType): OPD booking = OPD department (usp_Api_OPDDoctor_GetList);
    /// IPD = non-referral doctor with an IPD department (usp_Api_Ipd_Lookups, usp_Api_IpdAdmission_Save);
    /// LAB referral = IsReferralDoctor with a LAB department (usp_Lab_GetReferralDoctors).
    /// </summary>
    private string[] AllowedTypes => referral ? ["LAB", "OPD", "IPD"] : ["OPD", "IPD"];
    private bool IsAllowed(RefDoctorDept d) => AllowedTypes.Contains(d.Type.Trim().ToUpperInvariant());

    /// <summary>Active departments of every type: resolves the cells and exports the doctor's current departments.</summary>
    private async Task<BulkLookup<RefDoctorDept>> DepartmentsAsync(int companyId) => new(
        await QueryAsync<RefDoctorDept>("""
            SELECT DeptId AS Id, ISNULL(DeptCode, '') AS Code, DeptName AS Name, ISNULL(DeptType, '') AS Type
            FROM dbo.DepartmentMaster
            WHERE IsActive = 1 AND (CompanyId = @CompanyId OR CompanyId IS NULL)
            ORDER BY DeptType, DeptName
            """, new { CompanyId = companyId }),
        x => x.Id, x => x.Code, x => x.Name);

    private async Task<BulkLookup<RefExecutive>> ExecutivesAsync(int companyId) => new(
        await QueryAsync<RefExecutive>("""
            SELECT ExecutiveId AS Id, ISNULL(ExecutiveCode, '') AS Code, ExecutiveName AS Name, ISNULL(ExecutiveType, '') AS Type
            FROM dbo.MarketingExecutive
            WHERE IsActive = 1 AND IsDeleted = 0 AND CompanyId = @CompanyId
            ORDER BY ExecutiveName
            """, new { CompanyId = companyId }),
        x => x.Id, x => x.Code, x => x.Name);

    /// <summary>All company doctors with their maps; Visible = the signed-in branch may see / edit it (as on Doctors/Index).</summary>
    private async Task<List<ExistingDoctor>> DoctorsAsync(BulkContext ctx)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("""
            SELECT d.DoctorId, d.NamePrefix, d.FullName, d.Gender, d.DateOfBirth, d.EmailId, d.PhoneNumber, d.MedicalLicenseNo,
                   d.PrimarySpecialityId, d.SecondarySpecialityId, d.JoiningDate, d.IsActive, ISNULL(d.IsReferralDoctor, 0) AS IsReferralDoctor,
                   d.MarketingExecutiveId,
                   CAST(CASE WHEN d.LinkedUserId IS NOT NULL
                              OR EXISTS (SELECT 1 FROM dbo.Users u WHERE u.User_Type = 'D' AND u.ReferenceUserID = d.DoctorId)
                             THEN 1 ELSE 0 END AS BIT) AS HasLogin,
                   CAST(CASE WHEN @BranchId IS NULL OR d.CreatedBranchId = @BranchId
                              OR EXISTS (SELECT 1 FROM dbo.DoctorBranchMap m WHERE m.DoctorId = d.DoctorId AND m.BranchId = @BranchId AND m.IsActive = 1)
                             THEN 1 ELSE 0 END AS BIT) AS Visible
            FROM dbo.DoctorMaster d
            WHERE d.CompanyId = @CompanyId;
            SELECT m.DoctorId, m.BranchId FROM dbo.DoctorBranchMap m JOIN dbo.DoctorMaster d ON d.DoctorId = m.DoctorId
            WHERE d.CompanyId = @CompanyId AND m.IsActive = 1;
            SELECT m.DoctorId, m.DeptId FROM dbo.DoctorDepartmentMap m JOIN dbo.DoctorMaster d ON d.DoctorId = m.DoctorId
            WHERE d.CompanyId = @CompanyId AND m.IsActive = 1;
            """, new { ctx.CompanyId, ctx.BranchId });
        var doctors = (await multi.ReadAsync<ExistingDoctor>()).ToDictionary(d => d.DoctorId);
        foreach (var (doctorId, branchId) in await multi.ReadAsync<(int, int)>())
            if (doctors.TryGetValue(doctorId, out var d)) d.BranchIds.Add(branchId);
        foreach (var (doctorId, deptId) in await multi.ReadAsync<(int, int)>())
            if (doctors.TryGetValue(doctorId, out var d)) d.DeptIds.Add(deptId);
        return [.. doctors.Values];
    }

    // ── template ─────────────────────────────────────────────────────────────────────────────────────────────
    public async Task<BulkTemplate> BuildTemplateAsync(BulkContext ctx, bool withData)
    {
        var specialities = await SpecialitiesAsync(ctx.CompanyId);
        var depts = await DepartmentsAsync(ctx.CompanyId);
        var branches = await lookups.BranchesAsync(ctx.CompanyId);
        var executives = await ExecutivesAsync(ctx.CompanyId);
        var multiBranch = ctx.IsHO;

        var columns = new List<BulkColumn>
        {
            new() { Header = CId, Kind = BulkColumnKind.Integer, Min = 1, Note = "Leave blank to add a new doctor. Fill with the Doctor ID (from 'Template with Existing Data') to update that doctor.", Width = 10 },
            new() { Header = CPrefix, Required = true, Options = Prefixes, Note = "Default Dr.", Width = 8 },
            new() { Header = CName, Required = true, Note = "Without the prefix. Max 150 characters.", Width = 28 },
            new() { Header = CGender, Required = true, Options = Genders, Width = 9 },
            new() { Header = CDob, AllowNone = true, Kind = BulkColumnKind.Date, Note = "Not in the future.", Width = 12 },
            new() { Header = CEmail, Required = true, Note = "Unique among doctors. Max 150 characters. For a doctor with a login it is the sign-in: change it on the Doctor Edit screen.", Width = 28 },
            new() { Header = CPhone, Required = true, Note = "10-digit mobile starting with 6-9 (+91 / 0 allowed).", Width = 15 },
            new() { Header = CLicense, AllowNone = true, Note = "Medical License / MMC. Unique when given. Max 80 characters.", Width = 16 },
            new() { Header = CPrimary, Required = true, RefSheet = RefSpecialitySheet, Width = 24 },
            new() { Header = CSecondary, AllowNone = true, RefSheet = RefSpecialitySheet, Note = "Different from the primary speciality.", Width = 24 },
            new() { Header = CJoining, AllowNone = true, Kind = BulkColumnKind.Date, Width = 12 },
            new() { Header = CExecutive, AllowNone = true, RefSheet = RefExecutiveSheet, Note = "Active marketing executive (Master > Marketing Executive).", Width = 24 },
            new() { Header = CStatus, Options = BulkValues.StatusOptions, Note = "Default Active.", Width = 10 }
        };
        for (var i = 0; i < CDepts.Length; i++)
            columns.Add(new()
            {
                Header = CDepts[i], Required = i == 0, RefSheet = RefDeptSheet, Width = 26,
                Note = i == 0
                    ? (referral
                        ? "At least one Lab department (the lab booking lists referral doctors by their Lab department). OPD / IPD departments may be added."
                        : "At least one OPD or IPD department: OPD booking lists doctors with an OPD department, IPD admission needs an IPD department.") +
                      " When updating, filling any Department column replaces the doctor's departments; all blank keeps them."
                    : ""
            });
        for (var i = 0; i < CBranches.Length; i++)
            columns.Add(new()
            {
                Header = CBranches[i], RefSheet = RefBranchSheet, Width = 20,
                Note = i == 0
                    ? (multiBranch
                        ? "Branches the doctor works in; your signed-in branch is always added. When updating, filling any Branch column replaces the doctor's branches; all blank keeps them."
                        : "Only your signed-in branch can be assigned (several branches need an Administrator at the Head Office branch). Leave blank.")
                    : ""
            });

        var t = new BulkTemplate
        {
            SheetName = referral ? "ReferralDoctor" : "Doctor",
            Columns = columns,
            RefSheets =
            [
                new() { Name = RefSpecialitySheet, Headers = ["Select Value", "Speciality"],
                        Rows = specialities.Items.Select(s => new object?[] { specialities.Pick(s), s.Name }).ToList() },
                new() { Name = RefDeptSheet, Headers = ["Select Value", "Department Code", "Department Name", "Type"],
                        Rows = depts.Items.Where(IsAllowed).Select(d => new object?[] { depts.Pick(d), d.Code, d.Name, d.Type }).ToList() },
                new() { Name = RefBranchSheet, Headers = ["Select Value", "Branch Code", "Branch Name"],
                        Rows = branches.Items.Select(b => new object?[] { branches.Pick(b), b.Code, b.Name }).ToList() },
                new() { Name = RefExecutiveSheet, Headers = ["Select Value", "Executive Code", "Executive Name", "Type"],
                        Rows = executives.Items.Select(e => new object?[] { executives.Pick(e), e.Code, e.Name, e.Type }).ToList() }
            ],
            Notes =
            [
                referral
                    ? "This template is for referral doctors (Is Referral Doctor = Yes). OPD / IPD doctors use the other template."
                    : "This template is for OPD / IPD doctors (Is Referral Doctor = No). Referral doctors use the other template.",
                referral
                    ? "Departments: Lab, OPD and IPD types; at least one Lab department."
                    : "Departments: OPD and IPD types only. A doctor with an OPD department appears in OPD booking, with an IPD department in IPD admission.",
                "Doctor login, suspension and consulting charges are managed on the Doctor screens and are not changed by bulk upload.",
                "Only doctors of your signed-in branch (created at or assigned to it) can be updated."
            ]
        };

        if (withData)
        {
            string? DeptPick(int id) => depts.ById(id) is { } d ? depts.Pick(d) : null;
            foreach (var d in (await DoctorsAsync(ctx)).Where(d => d.Visible && d.IsReferralDoctor == referral).OrderBy(d => d.FullName))
            {
                var deptPicks = d.DeptIds.Select(DeptPick).Where(p => p != null).Take(CDepts.Length).ToList();
                var branchPicks = d.BranchIds.Select(id => branches.ById(id) is { } b ? branches.Pick(b) : null).Where(p => p != null).Take(CBranches.Length).ToList();
                var row = new List<object?>
                {
                    d.DoctorId, d.NamePrefix, d.FullName, d.Gender, d.DateOfBirth, d.EmailId, d.PhoneNumber,
                    string.IsNullOrWhiteSpace(d.MedicalLicenseNo) ? null : d.MedicalLicenseNo,
                    specialities.ById(d.PrimarySpecialityId) is { } p ? specialities.Pick(p) : null,
                    specialities.ById(d.SecondarySpecialityId) is { } s ? specialities.Pick(s) : null,
                    d.JoiningDate,
                    executives.ById(d.MarketingExecutiveId) is { } e ? executives.Pick(e) : null,
                    BulkValues.Status(d.IsActive)
                };
                for (var i = 0; i < CDepts.Length; i++) row.Add(i < deptPicks.Count ? deptPicks[i] : null);
                for (var i = 0; i < CBranches.Length; i++) row.Add(i < branchPicks.Count ? branchPicks[i] : null);
                t.DataRows.Add([.. row]);
            }
        }
        return t;
    }

    // ── import ───────────────────────────────────────────────────────────────────────────────────────────────
    public async Task ImportAsync(IReadOnlyList<BulkRow> rows, BulkContext ctx, LabBulkUploadResult result)
    {
        if (ctx.BranchId is not int signedInBranch)
        {
            foreach (var row in rows)
            {
                var r = new RowReader(row);
                r.Fail(string.Empty, LabBulkUploadRules.AccessDenied, "Select a branch before uploading doctors.");
                result.AddFailure(r);
            }
            return;
        }

        var specialities = await SpecialitiesAsync(ctx.CompanyId);
        var depts = await DepartmentsAsync(ctx.CompanyId);
        var branches = await lookups.BranchesAsync(ctx.CompanyId);
        var executives = await ExecutivesAsync(ctx.CompanyId);
        var doctors = await DoctorsAsync(ctx);
        var byId = doctors.ToDictionary(d => d.DoctorId);
        var multiBranch = ctx.IsHO;

        var seenIds = new Dictionary<int, int>();
        var seenEmails = new Dictionary<string, int>();
        var seenLicenses = new Dictionary<string, int>();
        var seenNamePhones = new Dictionary<string, int>();

        foreach (var row in rows)
        {
            var r = new RowReader(row);
            var id = r.Int(CId, min: 1);
            ExistingDoctor? current = null;
            if (id is int doctorId)
            {
                if (!byId.TryGetValue(doctorId, out current) || !current.Visible)
                {
                    r.Fail(CId, LabBulkUploadRules.NotFound, $"Doctor ID {doctorId} does not exist for your branch. Leave it blank to add a new doctor.");
                    current = null;
                }
                else if (current.IsReferralDoctor != referral)
                {
                    r.Fail(CId, LabBulkUploadRules.InvalidValue, $"Doctor ID {doctorId} ({current.FullName}) is {(current.IsReferralDoctor ? "a referral doctor" : "an OPD / IPD doctor")}: use the {OtherTemplate} template, or change 'Is Referral Doctor' on the Doctor Edit screen.");
                    current = null;
                }
                else if (!seenIds.TryAdd(doctorId, r.RowNo))
                    r.Fail(CId, LabBulkUploadRules.DuplicateInFile, $"Doctor ID {doctorId} is already used in row {seenIds[doctorId]}.");
            }
            var isInsert = id == null;

            var prefix = r.Option(CPrefix, Prefixes, current: current?.NamePrefix);
            var name = r.Text(CName, required: isInsert, maxLength: 150);
            var gender = r.Option(CGender, Genders, required: isInsert, current: current?.Gender);
            var dob = r.Date(CDob);
            var email = r.Text(CEmail, required: isInsert, maxLength: 150);
            var phone = r.Text(CPhone, required: isInsert, maxLength: 20);
            var license = r.Text(CLicense, maxLength: 80);
            var primary = r.Ref(CPrimary, specialities, required: isInsert, master: "Speciality");
            var secondary = r.Ref(CSecondary, specialities, master: "Speciality");
            var joining = r.Date(CJoining);
            var executive = r.Ref(CExecutive, executives, master: "Marketing executive");
            var status = r.Status(CStatus);
            var deptRefs = CDepts.Select(c => r.Ref(c, depts, master: "Department")).ToList();
            var branchRefs = CBranches.Select(c => r.Ref(c, branches, master: "Branch")).ToList();
            var deptsGiven = CDepts.Any(c => !r.IsBlank(c));
            var branchesGiven = CBranches.Any(c => !r.IsBlank(c));
            r.RecordKey = id is int k ? $"{k} {current?.FullName ?? name}".Trim() : name ?? email ?? string.Empty;

            if (email != null && !EmailRegex.IsMatch(email))
                r.Fail(CEmail, LabBulkUploadRules.InvalidValue, $"Email ID '{email}' is not a valid email address.");
            if (phone != null && !PhoneRegex.IsMatch(phone))
                r.Fail(CPhone, LabBulkUploadRules.InvalidValue, $"Phone Number '{phone}' must be a 10-digit mobile number starting with 6-9 (+91 optional).");
            if (dob > DateTime.Today)
                r.Fail(CDob, LabBulkUploadRules.InvalidValue, "Date of Birth cannot be in the future.");
            if (isInsert && !deptsGiven)
                r.Fail(CDepts[0], LabBulkUploadRules.Required, "At least one Department is required.");

            if (r.HasErrors || (!isInsert && current == null))
            {
                result.AddFailure(r);
                continue;
            }

            // final values: blank keeps the stored value, "(None)" clears an optional one
            var before = current != null ? From(current) : null;
            var deptIds = deptsGiven ? deptRefs.Where(d => d != null).Select(d => d!.Id).Distinct().Order().ToList() : before?.DeptIds ?? [];
            List<int> branchIds;
            if (branchesGiven)
            {
                var given = branchRefs.Where(b => b != null).Select(b => b!.Id).ToList();
                if (!multiBranch && given.Any(b => b != signedInBranch))
                    r.Fail(CBranches[0], LabBulkUploadRules.AccessDenied, "You can assign only your signed-in branch. Assigning several branches needs an Administrator at the Head Office branch.");
                branchIds = [.. given.Append(signedInBranch).Distinct().Order()];
            }
            else branchIds = before?.BranchIds ?? [signedInBranch];

            var values = new DoctorValues(
                prefix ?? before?.Prefix ?? "Dr.",
                name?.Trim() ?? before!.Name,
                gender ?? before!.Gender,
                r.IsNone(CDob) ? null : dob ?? before?.Dob,
                email?.Trim() ?? before!.Email,
                phone?.Trim() ?? before!.Phone,
                r.IsNone(CLicense) ? null : license?.Trim() ?? before?.License,
                primary?.Id ?? before!.PrimaryId,
                r.IsNone(CSecondary) ? null : secondary?.Id ?? before?.SecondaryId,
                r.IsNone(CJoining) ? null : joining ?? before?.Joining,
                r.IsNone(CExecutive) ? null : executive?.Id ?? before?.ExecutiveId,
                status ?? before?.Active ?? true,
                branchIds,
                deptIds);

            if (values.SecondaryId.HasValue && values.SecondaryId == values.PrimaryId)
                r.Fail(CSecondary, LabBulkUploadRules.InvalidValue, "Secondary Speciality must be different from Primary Speciality.");
            if (values.DeptIds.Count == 0)
                r.Fail(CDepts[0], LabBulkUploadRules.Required, "At least one Department is required.");
            // department types: checked for new rows and changed department lists (existing mappings re-upload as they are)
            var deptsChanged = before == null || !before.DeptIds.SequenceEqual(values.DeptIds);
            if (deptsChanged && values.DeptIds.Count > 0)
            {
                var keep = before?.DeptIds ?? [];
                for (var i = 0; i < CDepts.Length; i++)
                    if (deptRefs[i] is { } d && !IsAllowed(d) && !keep.Contains(d.Id))
                        r.Fail(CDepts[i], LabBulkUploadRules.InvalidRef,
                            $"'{d.Name}' is a {d.Type} department. {(referral ? "Referral doctors take Lab, OPD or IPD departments." : $"OPD / IPD doctors take OPD or IPD departments{(d.Type.Equals("LAB", StringComparison.OrdinalIgnoreCase) ? "; a Lab department is for referral doctors (Referral Doctors template)" : "")}.")}");
                if (referral && !values.DeptIds.Any(id => depts.ById(id) is { } d && d.Type.Equals("LAB", StringComparison.OrdinalIgnoreCase)))
                    r.Fail(CDepts[0], LabBulkUploadRules.Required, "A referral doctor needs at least one Lab department: the lab booking (B2C / B2B) lists referral doctors by their Lab department.");
                if (!referral && !values.DeptIds.Any(id => depts.ById(id) is { } d && IsAllowed(d)))
                    r.Fail(CDepts[0], LabBulkUploadRules.Required, "An OPD / IPD doctor needs at least one OPD or IPD department.");
            }

            // a doctor's login signs in with the doctor's e-mail: it is changed on the Edit screen, which syncs the login
            var emailChanged = before == null || !string.Equals(before.Email.Trim(), values.Email, StringComparison.OrdinalIgnoreCase);
            if (current?.HasLogin == true && emailChanged)
                r.Fail(CEmail, LabBulkUploadRules.InvalidValue, "This doctor has a login that signs in with this e-mail. Change the e-mail on the Doctor Edit screen.");

            // duplicates (checked for new rows and for changed values, so existing data re-uploads unchanged)
            var self = current?.DoctorId;
            if (emailChanged)
            {
                var key = Norm(values.Email);
                if (doctors.FirstOrDefault(d => d.DoctorId != self && Norm(d.EmailId) == key) is { } clash)
                    r.Fail(CEmail, LabBulkUploadRules.AlreadyExists, $"Email ID '{values.Email}' is already used by doctor {clash.DoctorId} ({clash.FullName}).{(clash.Visible ? $" Put {clash.DoctorId} in '{CId}' to update that doctor." : "")}");
                if (seenEmails.TryGetValue(key, out var first))
                    r.Fail(CEmail, LabBulkUploadRules.DuplicateInFile, $"Email ID '{values.Email}' is already in row {first}.");
            }
            if (values.License != null && (before == null || Norm(before.License) != Norm(values.License)))
            {
                var key = Norm(values.License);
                if (doctors.FirstOrDefault(d => d.DoctorId != self && Norm(d.MedicalLicenseNo) == key) is { } clash)
                    r.Fail(CLicense, LabBulkUploadRules.AlreadyExists, $"Medical License No '{values.License}' is already used by doctor {clash.DoctorId} ({clash.FullName}).");
                if (seenLicenses.TryGetValue(key, out var first))
                    r.Fail(CLicense, LabBulkUploadRules.DuplicateInFile, $"Medical License No '{values.License}' is already in row {first}.");
            }
            var namePhone = $"{Norm(values.Name)}|{Digits(values.Phone)}";
            if (before == null || Norm(before.Name) != Norm(values.Name) || Digits(before.Phone) != Digits(values.Phone))
            {
                if (doctors.FirstOrDefault(d => d.DoctorId != self && Norm(d.FullName) == Norm(values.Name) && Digits(d.PhoneNumber) == Digits(values.Phone)) is { } clash)
                    r.Fail(CName, LabBulkUploadRules.AlreadyExists, $"Doctor '{values.Name}' with this phone number already exists (Doctor ID {clash.DoctorId}).{(clash.Visible ? $" Put {clash.DoctorId} in '{CId}' to update that doctor." : "")}");
                if (seenNamePhones.TryGetValue(namePhone, out var first))
                    r.Fail(CName, LabBulkUploadRules.DuplicateInFile, $"Doctor '{values.Name}' with this phone number is already in row {first}.");
            }

            if (r.HasErrors)
            {
                result.AddFailure(r);
                continue;
            }

            // only rows that will be saved claim e-mail / license / name+phone for the in-file checks
            seenEmails[Norm(values.Email)] = r.RowNo;
            if (values.License != null) seenLicenses[Norm(values.License)] = r.RowNo;
            seenNamePhones[namePhone] = r.RowNo;

            if (before != null && BulkValues.SameJson(before, values))
            {
                result.Unchanged++;
                continue;
            }
            await result.SaveRowAsync(r, ctx, isInsert, () => SaveAsync(current?.DoctorId, values, before, ctx, signedInBranch));
        }
    }

    /// <summary>Insert / update in one transaction: doctor, branch and department maps, marketing executive.</summary>
    private async Task SaveAsync(int? doctorId, DoctorValues v, DoctorValues? before, BulkContext ctx, int signedInBranch)
    {
        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();
        var args = new
        {
            ctx.CompanyId, NamePrefix = v.Prefix, FullName = v.Name, v.Gender, DateOfBirth = v.Dob, EmailId = v.Email, PhoneNumber = v.Phone,
            MedicalLicenseNo = v.License, PrimarySpecialityId = v.PrimaryId, SecondarySpecialityId = v.SecondaryId, JoiningDate = v.Joining,
            IsActive = v.Active, IsReferralDoctor = referral, CreatedBranchId = signedInBranch, UserId = ctx.UserId, DoctorId = doctorId
        };

        int id;
        if (doctorId is null)
        {
            id = await con.ExecuteScalarAsync<int>("""
                INSERT INTO dbo.DoctorMaster
                    (CompanyId, NamePrefix, FullName, Gender, DateOfBirth, EmailId, PhoneNumber, MedicalLicenseNo,
                     PrimarySpecialityId, SecondarySpecialityId, JoiningDate, IsActive, IsReferralDoctor,
                     CreatedBranchId, LinkedUserId, CreatedBy, CreatedDate)
                VALUES
                    (@CompanyId, @NamePrefix, @FullName, @Gender, @DateOfBirth, @EmailId, @PhoneNumber, @MedicalLicenseNo,
                     @PrimarySpecialityId, @SecondarySpecialityId, @JoiningDate, @IsActive, @IsReferralDoctor,
                     @CreatedBranchId, NULL, @UserId, GETDATE());
                SELECT CAST(SCOPE_IDENTITY() AS INT);
                """, args, tx);
        }
        else
        {
            id = doctorId.Value;
            // login, suspension and created branch are not touched
            await con.ExecuteAsync("""
                UPDATE dbo.DoctorMaster SET
                    NamePrefix = @NamePrefix, FullName = @FullName, Gender = @Gender, DateOfBirth = @DateOfBirth,
                    EmailId = @EmailId, PhoneNumber = @PhoneNumber, MedicalLicenseNo = @MedicalLicenseNo,
                    PrimarySpecialityId = @PrimarySpecialityId, SecondarySpecialityId = @SecondarySpecialityId,
                    JoiningDate = @JoiningDate, IsActive = @IsActive, ModifiedBy = @UserId, ModifiedDate = GETDATE()
                WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId;
                """, args, tx);
        }

        if (before == null || !before.BranchIds.SequenceEqual(v.BranchIds))
        {
            await con.ExecuteAsync("DELETE FROM dbo.DoctorBranchMap WHERE DoctorId = @id", new { id }, tx);
            foreach (var branchId in v.BranchIds)
                await con.ExecuteAsync("""
                    INSERT INTO dbo.DoctorBranchMap (DoctorId, BranchId, CompanyId, IsActive, CreatedBy, CreatedDate)
                    VALUES (@id, @branchId, ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @branchId), 1), 1, @UserId, GETDATE())
                    """, new { id, branchId, ctx.UserId }, tx);
        }
        if (before == null || !before.DeptIds.SequenceEqual(v.DeptIds))
        {
            await con.ExecuteAsync("DELETE FROM dbo.DoctorDepartmentMap WHERE DoctorId = @id", new { id }, tx);
            foreach (var deptId in v.DeptIds)
                await con.ExecuteAsync("""
                    INSERT INTO dbo.DoctorDepartmentMap (DoctorId, DeptId, IsActive, CreatedBy, CreatedDate)
                    VALUES (@id, @deptId, 1, @UserId, GETDATE())
                    """, new { id, deptId, ctx.UserId }, tx);
        }
        if (before?.ExecutiveId != v.ExecutiveId)
        {
            var me = await con.QueryFirstAsync<(bool Success, string? Error)>("dbo.usp_Api_Doctor_SetMarketingExecutive",
                new { ctx.CompanyId, UserId = ctx.UserId ?? 0, DoctorId = id, ExecutiveId = v.ExecutiveId }, tx, commandType: CommandType.StoredProcedure);
            if (!me.Success) throw new InvalidOperationException(me.Error ?? "The marketing executive could not be saved.");
        }
        tx.Commit();
    }
}
