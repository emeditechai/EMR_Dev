using System.Text.Json;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

// OPD > Certificates (SQLScripts/2341). Additive: reads patients, visits, doctors and vitals; writes only its own tables.

public class CertificateTypeRow
{
    public int CertificateTypeId { get; set; }
    public string TypeCode { get; set; } = "";
    public string TypeName { get; set; } = "";
    public string PrintTitle { get; set; } = "";
    public string NumberPrefix { get; set; } = "";
    public int? DefaultValidityDays { get; set; }
    public int? FeeServiceId { get; set; }
    public string? FeeServiceName { get; set; }
    public decimal? FeeAmount { get; set; }
    public string? LegalNote { get; set; }
    public int SortOrder { get; set; }
    public bool IsActive { get; set; }
}

public class CertificatePurposeRow
{
    public int PurposeId { get; set; }
    public string TypeCode { get; set; } = "";
    public string PurposeName { get; set; } = "";
    public int SortOrder { get; set; }
    public bool IsActive { get; set; }
}

public class VaccineRow
{
    public int VaccineId { get; set; }
    public string VaccineName { get; set; } = "";
    public string? ShortCode { get; set; }
    public string? Diseases { get; set; }
    public string? DefaultRoute { get; set; }
    public string? DefaultSite { get; set; }
    public int DosesInSeries { get; set; } = 1;
    public int? DoseGapDays { get; set; }
    public string? ScheduleAge { get; set; }
    public bool IsUIP { get; set; }
    public int SortOrder { get; set; }
    public bool IsActive { get; set; } = true;
}

public class DisabilityTypeRow
{
    public int DisabilityTypeId { get; set; }
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public string AssessmentForm { get; set; } = "";
}

public class SigningDoctorRow
{
    public int DoctorId { get; set; }
    public string DoctorName { get; set; } = "";
    public string? Speciality { get; set; }
    public string? MedicalLicenseNo { get; set; }
    public bool CanSign { get; set; }
    public string? Qualification { get; set; }
    public string? RegistrationCouncil { get; set; }
    public string? RegistrationNo { get; set; }
    public int? RegistrationYear { get; set; }
    public string? SignaturePath { get; set; }
    public string? StampPath { get; set; }
    public bool InBranch { get; set; }
}

public class CertificateListRow
{
    public int CertificateId { get; set; }
    public string TypeCode { get; set; } = "";
    public string TypeName { get; set; } = "";
    public string? CertificateNo { get; set; }
    public string Status { get; set; } = "D";
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = "";
    public string PatientName { get; set; } = "";
    public string? PhoneNumber { get; set; }
    public string? DoctorName { get; set; }
    public string? PurposeText { get; set; }
    public DateTime? IssueDate { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? OPDBillNo { get; set; }
    public string FeeMode { get; set; } = "F";
    public int PrintCount { get; set; }
    public string? CreatedByName { get; set; }
}

public class CertificateRecord
{
    public int CertificateId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string TypeCode { get; set; } = "";
    public string? CertificateNo { get; set; }
    public int PatientId { get; set; }
    public int? OPDServiceId { get; set; }
    public int? DoctorId { get; set; }
    public int? PurposeId { get; set; }
    public string? PurposeText { get; set; }
    public DateTime? IssueDate { get; set; }
    public DateTime? ValidFrom { get; set; }
    public DateTime? ValidTo { get; set; }
    public string? Diagnosis { get; set; }
    public string? Remarks { get; set; }
    public string? BodyJson { get; set; }
    public string FeeMode { get; set; } = "F";
    public int? FeeOPDServiceId { get; set; }
    public string Status { get; set; } = "D";
    public string? VerifyToken { get; set; }
    public int? ReissueOfId { get; set; }
    public DateTime? IssuedOn { get; set; }
    public string? IssuedByName { get; set; }
    public DateTime? CancelledOn { get; set; }
    public string? CancelReason { get; set; }
    public string? CancelledByName { get; set; }
    public int PrintCount { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class CertificatePatient
{
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = "";
    public string? Salutation { get; set; }
    public string FullName { get; set; } = "";
    public string? Gender { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public string? PhoneNumber { get; set; }
    public string? Address { get; set; }
    public string? GuardianName { get; set; }
    public string? RelationName { get; set; }
    public string? PhotoPath { get; set; }
    public string? IdentificationNumber { get; set; }
    public string? EmailId { get; set; }

    public string AgeText(DateTime on)
    {
        if (DateOfBirth is not { } dob) return "";
        var y = on.Year - dob.Year; if (dob.Date > on.AddYears(-y)) y--;
        if (y >= 1) return $"{y} years";
        var m = (on.Year - dob.Year) * 12 + on.Month - dob.Month; if (on.Day < dob.Day) m--;
        return m >= 1 ? $"{m} months" : $"{Math.Max(0, (on.Date - dob.Date).Days)} days";
    }
}

public class CertificateVisit
{
    public int OPDServiceId { get; set; }
    public int PatientId { get; set; }
    public string? OPDBillNo { get; set; }
    public string? TokenNo { get; set; }
    public DateTime? VisitDate { get; set; }
    public string? ServiceType { get; set; }
    public string? ServiceName { get; set; }
    public decimal? Amount { get; set; }
    public int? DoctorId { get; set; }
    public string? DoctorName { get; set; }
}

public class CertificateVaccinationRow
{
    public int VaccinationId { get; set; }
    public int VaccineId { get; set; }
    public string VaccineName { get; set; } = "";
    public int DoseNo { get; set; }
    public DateTime GivenOn { get; set; }
    public string? BatchNo { get; set; }
    public string? Manufacturer { get; set; }
    public DateTime? ExpiryDate { get; set; }
    public string? Route { get; set; }
    public string? Site { get; set; }
    public string? GivenBy { get; set; }
    public DateTime? NextDueDate { get; set; }
    public int? CertificateId { get; set; }
}

public class CertificateDoseInput
{
    public int VaccineId { get; set; }
    public int DoseNo { get; set; } = 1;
    public DateTime? GivenOn { get; set; }
    public string? BatchNo { get; set; }
    public string? Manufacturer { get; set; }
    public DateTime? ExpiryDate { get; set; }
    public string? Route { get; set; }
    public string? Site { get; set; }
    public string? GivenBy { get; set; }
    public DateTime? NextDueDate { get; set; }
}

public class CertificateSaveRequest
{
    public int CertificateId { get; set; }
    public string TypeCode { get; set; } = "";
    public int PatientId { get; set; }
    public int? OPDServiceId { get; set; }
    public int? DoctorId { get; set; }
    public int? PurposeId { get; set; }
    public string? PurposeText { get; set; }
    public DateTime? IssueDate { get; set; }
    public DateTime? ValidFrom { get; set; }
    public DateTime? ValidTo { get; set; }
    public string? Diagnosis { get; set; }
    public string? Remarks { get; set; }
    public JsonElement? Body { get; set; }
    public string FeeMode { get; set; } = "F";
    public int? FeeOPDServiceId { get; set; }
    public List<CertificateDoseInput>? Doses { get; set; }
    public bool Issue { get; set; }
}

public class CertificatePrintModel
{
    public CertificateRecord Certificate { get; set; } = new();
    public CertificateTypeRow Type { get; set; } = new();
    public CertificatePatient Patient { get; set; } = new();
    public SigningDoctorRow? Doctor { get; set; }
    public CertificateVisit? Visit { get; set; }
    public CertificateVisit? FeeBill { get; set; }
    public List<CertificateVaccinationRow> Vaccinations { get; set; } = new();
    public Dictionary<string, string?> Body { get; set; } = new();
    public string? DisabilityName { get; set; }
    public string? DisabilityForm { get; set; }
    public string? HospitalName { get; set; }
    public string? HospitalAddress { get; set; }
    public string? HospitalPhone { get; set; }
    public string? HospitalEmail { get; set; }
    public string? HospitalRegNo { get; set; }
    public string? LogoPath { get; set; }
    public string? BranchName { get; set; }
    public string? VerifyUrl { get; set; }
    public string B(string key) => Body.TryGetValue(key, out var v) ? v ?? "" : "";
}

public class CertificateVerifyModel
{
    public bool Found { get; set; }
    public string? CertificateNo { get; set; }
    public string? TypeName { get; set; }
    public string? Status { get; set; }
    public DateTime? IssueDate { get; set; }
    public DateTime? ValidTo { get; set; }
    public string? PatientMasked { get; set; }
    public string? DoctorName { get; set; }
    public string? DoctorRegNo { get; set; }
    public string? HospitalName { get; set; }
    public string? CancelReason { get; set; }
}

public interface ICertificateService
{
    Task EnsureMastersAsync(int companyId);
    Task<List<CertificateTypeRow>> GetTypesAsync(int companyId, int branchId, bool activeOnly);
    Task<List<CertificatePurposeRow>> GetPurposesAsync(int companyId, bool activeOnly);
    Task<List<VaccineRow>> GetVaccinesAsync(int companyId, bool activeOnly);
    Task<List<DisabilityTypeRow>> GetDisabilityTypesAsync();
    Task<List<SigningDoctorRow>> GetDoctorsAsync(int companyId, int branchId, bool signingOnly);
    Task<List<(int ServiceId, string Name, decimal Charges)>> GetFeeServicesAsync(int companyId, int branchId);
    Task SaveTypeAsync(int companyId, CertificateTypeRow row, int userId);
    Task SavePurposeAsync(int companyId, CertificatePurposeRow row, int userId);
    Task SaveVaccineAsync(int companyId, VaccineRow row, int userId);
    Task SaveDoctorAsync(int companyId, SigningDoctorRow row, int userId);

    Task<(List<CertificateListRow> Rows, int Total)> ListAsync(int branchId, DateTime from, DateTime to, string? type, string? status, string? search, int page, int pageSize);
    Task<List<CertificatePatient>> SearchPatientsAsync(int companyId, string term);
    Task<CertificatePatient?> GetPatientAsync(int companyId, int patientId);
    Task<List<CertificateVisit>> GetVisitsAsync(int companyId, int branchId, int patientId);
    Task<CertificateVisit?> GetVisitAsync(int branchId, int opdServiceId);
    Task<List<CertificateVisit>> GetFeeBillsAsync(int branchId, int patientId, int feeServiceId, int certificateId);
    Task<Dictionary<string, string?>> GetVisitClinicalAsync(int companyId, int patientId, int? opdServiceId);
    Task<List<CertificateVaccinationRow>> GetVaccinationsAsync(int companyId, int patientId);
    Task<CertificateRecord?> GetAsync(int branchId, int certificateId);
    Task<(int Id, string? Error)> SaveAsync(int companyId, int branchId, int userId, CertificateSaveRequest req);
    Task<(string? No, string? Error)> IssueAsync(int branchId, int certificateId, int userId);
    Task<string?> CancelAsync(int branchId, int certificateId, int userId, string reason);
    Task<(int Id, string? Error)> ReissueAsync(int branchId, int certificateId, int userId);
    Task<CertificatePrintModel?> GetPrintModelAsync(int branchId, int certificateId);
    Task MarkPrintedAsync(int certificateId);
    Task<CertificateVerifyModel> VerifyAsync(string token);
}

public class CertificateService(IDbConnectionFactory db) : ICertificateService
{
    public static readonly IReadOnlyDictionary<string, string> StatusNames = new Dictionary<string, string>
    {
        ["D"] = "Draft", ["I"] = "Issued", ["C"] = "Cancelled"
    };

    public async Task EnsureMastersAsync(int companyId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Certificate_EnsureMasters", new { CompanyId = companyId }, commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<List<CertificateTypeRow>> GetTypesAsync(int companyId, int branchId, bool activeOnly)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<CertificateTypeRow>(@"
            SELECT t.CertificateTypeId, t.TypeCode, t.TypeName, t.PrintTitle, t.NumberPrefix, t.DefaultValidityDays, t.FeeServiceId,
                   s.ItemName AS FeeServiceName, s.ItemCharges AS FeeAmount, t.LegalNote, t.SortOrder, t.IsActive
              FROM dbo.CertificateTypeMaster t
              LEFT JOIN dbo.ServiceMaster s ON s.ServiceId = t.FeeServiceId
             WHERE t.CompanyId = @companyId AND (@activeOnly = 0 OR t.IsActive = 1)
             ORDER BY t.SortOrder, t.TypeName", new { companyId, activeOnly })).ToList();
    }

    public async Task<List<CertificatePurposeRow>> GetPurposesAsync(int companyId, bool activeOnly)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<CertificatePurposeRow>(@"
            SELECT PurposeId, TypeCode, PurposeName, SortOrder, IsActive FROM dbo.CertificatePurposeMaster
             WHERE CompanyId = @companyId AND (@activeOnly = 0 OR IsActive = 1) ORDER BY TypeCode, SortOrder, PurposeName",
            new { companyId, activeOnly })).ToList();
    }

    public async Task<List<VaccineRow>> GetVaccinesAsync(int companyId, bool activeOnly)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<VaccineRow>(@"
            SELECT VaccineId, VaccineName, ShortCode, Diseases, DefaultRoute, DefaultSite, DosesInSeries, DoseGapDays, ScheduleAge, IsUIP, SortOrder, IsActive
              FROM dbo.VaccineMaster WHERE CompanyId = @companyId AND (@activeOnly = 0 OR IsActive = 1) ORDER BY SortOrder, VaccineName",
            new { companyId, activeOnly })).ToList();
    }

    public async Task<List<DisabilityTypeRow>> GetDisabilityTypesAsync()
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<DisabilityTypeRow>(
            "SELECT DisabilityTypeId, Name, Category, AssessmentForm FROM dbo.DisabilityTypeMaster WHERE IsActive = 1 ORDER BY SortOrder")).ToList();
    }

    public async Task<List<SigningDoctorRow>> GetDoctorsAsync(int companyId, int branchId, bool signingOnly)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<SigningDoctorRow>(@"
            SELECT d.DoctorId, LTRIM(RTRIM(ISNULL(d.NamePrefix, '') + ' ' + d.FullName)) AS DoctorName, sp.SpecialityName AS Speciality,
                   d.MedicalLicenseNo, ISNULL(p.CanSign, 0) AS CanSign, p.Qualification, p.RegistrationCouncil, p.RegistrationNo,
                   p.RegistrationYear, p.SignaturePath, p.StampPath,
                   CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.DoctorBranchMap m WHERE m.DoctorId = d.DoctorId AND m.BranchId = @branchId AND m.IsActive = 1)
                             THEN 1 ELSE 0 END AS BIT) AS InBranch
              FROM dbo.DoctorMaster d
              LEFT JOIN dbo.CertificateDoctorProfile p ON p.DoctorId = d.DoctorId
              LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
             WHERE d.CompanyId = @companyId AND d.IsActive = 1 AND ISNULL(d.IsReferralDoctor, 0) = 0
               AND (@signingOnly = 0 OR (ISNULL(p.CanSign, 0) = 1
                    AND EXISTS (SELECT 1 FROM dbo.DoctorBranchMap m WHERE m.DoctorId = d.DoctorId AND m.BranchId = @branchId AND m.IsActive = 1)))
             ORDER BY d.FullName", new { companyId, branchId, signingOnly })).ToList();
    }

    public async Task<List<(int ServiceId, string Name, decimal Charges)>> GetFeeServicesAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<(int, string, decimal)>(@"
            SELECT ServiceId, ItemName, ISNULL(ItemCharges, 0) FROM dbo.ServiceMaster
             WHERE CompanyId = @companyId AND IsActive = 1 AND ServiceType = 'Service' AND (BranchId IS NULL OR BranchId = @branchId)
             ORDER BY ItemName", new { companyId, branchId });
        return rows.ToList();
    }

    public async Task SaveTypeAsync(int companyId, CertificateTypeRow r, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE dbo.CertificateTypeMaster
               SET TypeName = @TypeName, PrintTitle = @PrintTitle, NumberPrefix = UPPER(@NumberPrefix), DefaultValidityDays = @DefaultValidityDays,
                   FeeServiceId = @FeeServiceId, LegalNote = @LegalNote, SortOrder = @SortOrder, IsActive = @IsActive,
                   ModifiedBy = @userId, ModifiedDate = GETDATE()
             WHERE CertificateTypeId = @CertificateTypeId AND CompanyId = @companyId",
            new { r.TypeName, r.PrintTitle, r.NumberPrefix, r.DefaultValidityDays, r.FeeServiceId, r.LegalNote, r.SortOrder, r.IsActive, r.CertificateTypeId, companyId, userId });
    }

    public async Task SavePurposeAsync(int companyId, CertificatePurposeRow r, int userId)
    {
        using var con = db.CreateConnection();
        if (r.PurposeId > 0)
            await con.ExecuteAsync(@"UPDATE dbo.CertificatePurposeMaster SET TypeCode = @TypeCode, PurposeName = @PurposeName, SortOrder = @SortOrder,
                IsActive = @IsActive, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE PurposeId = @PurposeId AND CompanyId = @companyId",
                new { r.TypeCode, r.PurposeName, r.SortOrder, r.IsActive, r.PurposeId, companyId, userId });
        else
            await con.ExecuteAsync(@"INSERT dbo.CertificatePurposeMaster (CompanyId, TypeCode, PurposeName, SortOrder, IsActive, CreatedBy)
                VALUES (@companyId, @TypeCode, @PurposeName, @SortOrder, @IsActive, @userId)",
                new { r.TypeCode, r.PurposeName, r.SortOrder, r.IsActive, companyId, userId });
    }

    public async Task SaveVaccineAsync(int companyId, VaccineRow r, int userId)
    {
        using var con = db.CreateConnection();
        var p = new { r.VaccineName, r.ShortCode, r.Diseases, r.DefaultRoute, r.DefaultSite, DosesInSeries = Math.Max(1, r.DosesInSeries), r.DoseGapDays,
                      r.ScheduleAge, r.IsUIP, r.SortOrder, r.IsActive, r.VaccineId, companyId, userId };
        if (r.VaccineId > 0)
            await con.ExecuteAsync(@"UPDATE dbo.VaccineMaster SET VaccineName = @VaccineName, ShortCode = @ShortCode, Diseases = @Diseases,
                DefaultRoute = @DefaultRoute, DefaultSite = @DefaultSite, DosesInSeries = @DosesInSeries, DoseGapDays = @DoseGapDays,
                ScheduleAge = @ScheduleAge, IsUIP = @IsUIP, SortOrder = @SortOrder, IsActive = @IsActive, ModifiedBy = @userId, ModifiedDate = GETDATE()
                WHERE VaccineId = @VaccineId AND CompanyId = @companyId", p);
        else
            await con.ExecuteAsync(@"INSERT dbo.VaccineMaster (CompanyId, VaccineName, ShortCode, Diseases, DefaultRoute, DefaultSite, DosesInSeries,
                DoseGapDays, ScheduleAge, IsUIP, SortOrder, IsActive, CreatedBy)
                VALUES (@companyId, @VaccineName, @ShortCode, @Diseases, @DefaultRoute, @DefaultSite, @DosesInSeries, @DoseGapDays, @ScheduleAge,
                        @IsUIP, @SortOrder, @IsActive, @userId)", p);
    }

    public async Task SaveDoctorAsync(int companyId, SigningDoctorRow r, int userId)
    {
        using var con = db.CreateConnection();
        // only a doctor of this company
        if (await con.ExecuteScalarAsync<int>("SELECT COUNT(1) FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @companyId",
                new { r.DoctorId, companyId }) == 0) return;
        await con.ExecuteAsync(@"
            MERGE dbo.CertificateDoctorProfile AS t
            USING (SELECT @DoctorId AS DoctorId) AS s ON t.DoctorId = s.DoctorId
            WHEN MATCHED THEN UPDATE SET CanSign = @CanSign, Qualification = @Qualification, RegistrationCouncil = @RegistrationCouncil,
                 RegistrationNo = @RegistrationNo, RegistrationYear = @RegistrationYear,
                 SignaturePath = ISNULL(@SignaturePath, t.SignaturePath), StampPath = ISNULL(@StampPath, t.StampPath),
                 ModifiedBy = @userId, ModifiedDate = GETDATE()
            WHEN NOT MATCHED THEN INSERT (DoctorId, CanSign, Qualification, RegistrationCouncil, RegistrationNo, RegistrationYear, SignaturePath, StampPath, ModifiedBy, ModifiedDate)
                 VALUES (@DoctorId, @CanSign, @Qualification, @RegistrationCouncil, @RegistrationNo, @RegistrationYear, @SignaturePath, @StampPath, @userId, GETDATE());",
            new { r.DoctorId, r.CanSign, r.Qualification, r.RegistrationCouncil, r.RegistrationNo, r.RegistrationYear, r.SignaturePath, r.StampPath, userId });
    }

    // ── register ──
    public async Task<(List<CertificateListRow> Rows, int Total)> ListAsync(int branchId, DateTime from, DateTime to, string? type, string? status,
        string? search, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        var p = new { branchId, from = from.Date, to = to.Date.AddDays(1), type = string.IsNullOrWhiteSpace(type) ? null : type,
                      status = string.IsNullOrWhiteSpace(status) ? null : status, search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                      skip = (Math.Max(1, page) - 1) * pageSize, take = pageSize };
        const string where = @"
              FROM dbo.PatientCertificate c
              JOIN dbo.PatientMaster pm ON pm.PatientId = c.PatientId
              LEFT JOIN dbo.CertificateTypeMaster t ON t.CompanyId = c.CompanyId AND t.TypeCode = c.TypeCode
              LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
              LEFT JOIN dbo.PatientOPDService v ON v.OPDServiceId = c.OPDServiceId
              LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
             WHERE c.BranchId = @branchId AND c.CreatedDate >= @from AND c.CreatedDate < @to
               AND (@type IS NULL OR c.TypeCode = @type) AND (@status IS NULL OR c.Status = @status)
               AND (@search IS NULL OR c.CertificateNo LIKE '%' + @search + '%' OR pm.PatientCode LIKE '%' + @search + '%'
                    OR pm.PhoneNumber LIKE '%' + @search + '%' OR pm.FirstName LIKE '%' + @search + '%' OR pm.LastName LIKE '%' + @search + '%')";
        var total = await con.ExecuteScalarAsync<int>("SELECT COUNT(1)" + where, p);
        var rows = await con.QueryAsync<CertificateListRow>(@"
            SELECT c.CertificateId, c.TypeCode, ISNULL(t.TypeName, c.TypeCode) AS TypeName, c.CertificateNo, c.Status, c.PatientId, pm.PatientCode,
                   LTRIM(RTRIM(ISNULL(pm.Salutation, '') + ' ' + ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) AS PatientName,
                   pm.PhoneNumber, LTRIM(RTRIM(ISNULL(d.NamePrefix, '') + ' ' + ISNULL(d.FullName, ''))) AS DoctorName, c.PurposeText,
                   c.IssueDate, c.CreatedDate, v.OPDBillNo, c.FeeMode, c.PrintCount,
                   ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS CreatedByName" + where + @"
             ORDER BY c.CreatedDate DESC, c.CertificateId DESC OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY", p);
        return (rows.ToList(), total);
    }

    // ── patients and visits ──
    private const string PatientSelect = @"
        SELECT pm.PatientId, pm.PatientCode, pm.Salutation,
               LTRIM(RTRIM(ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.MiddleName + ' ', '') + ISNULL(pm.LastName, ''))) AS FullName,
               pm.Gender, pm.DateOfBirth, pm.PhoneNumber, pm.Address, pm.GuardianName, pm.PhotoPath, pm.IdentificationNumber, pm.EmailId";

    public async Task<List<CertificatePatient>> SearchPatientsAsync(int companyId, string term)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<CertificatePatient>(@"
            SELECT TOP 20 x.* FROM (" + PatientSelect + @" FROM dbo.PatientMaster pm
             WHERE pm.CompanyId = @companyId AND pm.IsActive = 1
               AND (pm.PatientCode LIKE @like OR pm.PhoneNumber LIKE @like OR pm.FirstName LIKE @like OR pm.LastName LIKE @like
                    OR (pm.FirstName + ' ' + pm.LastName) LIKE @like)) x
             ORDER BY x.FullName", new { companyId, like = "%" + term.Trim() + "%" })).ToList();
    }

    public async Task<CertificatePatient?> GetPatientAsync(int companyId, int patientId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<CertificatePatient>(PatientSelect + @"
          FROM dbo.PatientMaster pm
         WHERE pm.PatientId = @patientId AND pm.CompanyId = @companyId", new { patientId, companyId });
    }

    private const string VisitSelect = @"
        SELECT v.OPDServiceId, v.PatientId, v.OPDBillNo, v.TokenNo, v.VisitDate, v.ServiceType, s.ItemName AS ServiceName,
               ISNULL(v.TotalAmount, v.ServiceCharges) AS Amount, v.ConsultingDoctorId AS DoctorId,
               LTRIM(RTRIM(ISNULL(d.NamePrefix, '') + ' ' + ISNULL(d.FullName, ''))) AS DoctorName
          FROM dbo.PatientOPDService v
          LEFT JOIN dbo.ServiceMaster s ON s.ServiceId = v.ServiceId
          LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = v.ConsultingDoctorId";

    public async Task<List<CertificateVisit>> GetVisitsAsync(int companyId, int branchId, int patientId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<CertificateVisit>("SELECT TOP 30 * FROM (" + VisitSelect + @"
             WHERE v.PatientId = @patientId AND v.BranchId = @branchId AND ISNULL(v.IsActive, 1) = 1) x ORDER BY x.VisitDate DESC, x.OPDServiceId DESC",
            new { patientId, branchId })).ToList();
    }

    public async Task<CertificateVisit?> GetVisitAsync(int branchId, int opdServiceId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<CertificateVisit>(VisitSelect + " WHERE v.OPDServiceId = @opdServiceId AND v.BranchId = @branchId",
            new { opdServiceId, branchId });
    }

    /// <summary>
    /// The patient's OPD bills in this branch that charge the certificate type's fee service (on the bill or one of its
    /// items) and are not already the fee bill of another certificate that is not cancelled. Amount = that service's charge.
    /// </summary>
    public async Task<List<CertificateVisit>> GetFeeBillsAsync(int branchId, int patientId, int feeServiceId, int certificateId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<CertificateVisit>(@"
            SELECT v.OPDServiceId, v.PatientId, v.OPDBillNo, v.TokenNo, v.VisitDate, v.ServiceType, s.ItemName AS ServiceName,
                   ISNULL(fi.Charges, ISNULL(v.ServiceCharges, v.TotalAmount)) AS Amount, v.ConsultingDoctorId AS DoctorId,
                   LTRIM(RTRIM(ISNULL(d.NamePrefix, '') + ' ' + ISNULL(d.FullName, ''))) AS DoctorName
              FROM dbo.PatientOPDService v
              LEFT JOIN dbo.ServiceMaster s ON s.ServiceId = @feeServiceId
              LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = v.ConsultingDoctorId
              OUTER APPLY (SELECT SUM(i.ServiceCharges) AS Charges FROM dbo.PatientOPDServiceItem i
                            WHERE i.OPDServiceId = v.OPDServiceId AND i.ServiceId = @feeServiceId AND i.IsActive = 1) fi
             WHERE v.PatientId = @patientId AND v.BranchId = @branchId AND ISNULL(v.IsActive, 1) = 1
               AND (v.ServiceId = @feeServiceId OR fi.Charges IS NOT NULL)
               AND NOT EXISTS (SELECT 1 FROM dbo.PatientCertificate c
                                WHERE c.FeeOPDServiceId = v.OPDServiceId AND c.Status <> 'C' AND c.CertificateId <> @certificateId)
             ORDER BY v.VisitDate DESC, v.OPDServiceId DESC", new { branchId, patientId, feeServiceId, certificateId })).ToList();
    }

    /// <summary>Latest vitals of the patient and the diagnosis written in the visit's EMR (read only).</summary>
    public async Task<Dictionary<string, string?>> GetVisitClinicalAsync(int companyId, int patientId, int? opdServiceId)
    {
        using var con = db.CreateConnection();
        var r = new Dictionary<string, string?>();
        var v = await con.QueryFirstOrDefaultAsync(@"
            SELECT TOP 1 Height, Weight, BPSystolic, BPDiastolic, PulseRate, SpO2, Temperature FROM dbo.PatientVitals
             WHERE PatientId = @patientId AND IsActive = 1 ORDER BY RecordedOn DESC, PatientVitalId DESC", new { patientId });
        if (v != null)
        {
            r["height"] = v.Height?.ToString(); r["weight"] = v.Weight?.ToString(); r["pulse"] = v.PulseRate?.ToString();
            r["bp"] = v.BPSystolic != null && v.BPDiastolic != null ? $"{v.BPSystolic}/{v.BPDiastolic}" : null;
            r["spo2"] = v.SpO2?.ToString(); r["temperature"] = v.Temperature?.ToString();
        }
        if (opdServiceId is > 0)
        {
            var json = await con.ExecuteScalarAsync<string?>(@"SELECT TOP 1 EmrDataJson FROM dbo.EmrPatientConsultation
                WHERE OPDServiceId = @opdServiceId AND PatientId = @patientId ORDER BY ConsultationId DESC", new { opdServiceId, patientId });
            var dx = DiagnosisFromEmr(json);
            if (!string.IsNullOrWhiteSpace(dx)) r["diagnosis"] = dx;
        }
        return r;
    }

    // the EMR template's own JSON: every text value under a field whose name mentions diagnosis
    private static string? DiagnosisFromEmr(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var found = new List<string>();
            void Walk(JsonElement e, bool under)
            {
                switch (e.ValueKind)
                {
                    case JsonValueKind.Object:
                        foreach (var p in e.EnumerateObject()) Walk(p.Value, under || p.Name.Contains("diagnos", StringComparison.OrdinalIgnoreCase));
                        break;
                    case JsonValueKind.Array:
                        foreach (var x in e.EnumerateArray()) Walk(x, under);
                        break;
                    case JsonValueKind.String when under:
                        var s = e.GetString()?.Trim();
                        if (!string.IsNullOrEmpty(s) && s.Length < 300 && !found.Contains(s)) found.Add(s);
                        break;
                }
            }
            Walk(doc.RootElement, false);
            var text = string.Join(", ", found);
            return text.Length > 0 ? (text.Length > 480 ? text[..480] : text) : null;
        }
        catch (JsonException) { return null; }
    }

    public async Task<List<CertificateVaccinationRow>> GetVaccinationsAsync(int companyId, int patientId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<CertificateVaccinationRow>(@"
            SELECT pv.VaccinationId, pv.VaccineId, vm.VaccineName, pv.DoseNo, pv.GivenOn, pv.BatchNo, pv.Manufacturer, pv.ExpiryDate,
                   pv.Route, pv.Site, pv.GivenBy, pv.NextDueDate, pv.CertificateId
              FROM dbo.PatientVaccination pv JOIN dbo.VaccineMaster vm ON vm.VaccineId = pv.VaccineId
             WHERE pv.PatientId = @patientId AND pv.CompanyId = @companyId AND pv.IsActive = 1
             ORDER BY pv.GivenOn, vm.SortOrder, pv.DoseNo", new { patientId, companyId })).ToList();
    }

    // ── certificates ──
    public async Task<CertificateRecord?> GetAsync(int branchId, int certificateId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<CertificateRecord>(@"
            SELECT c.*, ISNULL(NULLIF(LTRIM(RTRIM(ui.FullName)), ''), ui.Username) AS IssuedByName,
                   ISNULL(NULLIF(LTRIM(RTRIM(uc.FullName)), ''), uc.Username) AS CancelledByName
              FROM dbo.PatientCertificate c
              LEFT JOIN dbo.Users ui ON ui.Id = c.IssuedBy
              LEFT JOIN dbo.Users uc ON uc.Id = c.CancelledBy
             WHERE c.CertificateId = @certificateId AND c.BranchId = @branchId", new { certificateId, branchId });
    }

    public async Task<(int Id, string? Error)> SaveAsync(int companyId, int branchId, int userId, CertificateSaveRequest req)
    {
        var type = (await GetTypesAsync(companyId, branchId, true)).FirstOrDefault(t => t.TypeCode == req.TypeCode);
        if (type == null) return (0, "Choose the certificate type.");
        if (await GetPatientAsync(companyId, req.PatientId) == null) return (0, "Choose the patient.");
        if (req.OPDServiceId is > 0)
        {
            var visit = await GetVisitAsync(branchId, req.OPDServiceId.Value);
            if (visit == null) return (0, "The OPD visit was not found in this branch.");
        }
        req.FeeMode = req.FeeMode == "B" ? "B" : "F";
        if (req.FeeMode == "B")
        {
            if (type.FeeServiceId is not > 0) return (0, $"No fee service is set for {type.TypeName} (Certificate Masters). Issue it free, or set the fee service first.");
            if (req.FeeOPDServiceId is not > 0) return (0, $"Charged: the fee ({type.FeeServiceName}) is not billed yet. Bill it in OPD > Service Booking, then choose that bill.");
            var bills = await GetFeeBillsAsync(branchId, req.PatientId, type.FeeServiceId.Value, req.CertificateId);
            if (!bills.Any(b => b.OPDServiceId == req.FeeOPDServiceId))
                return (0, $"The chosen bill must be this patient's OPD bill that charges {type.FeeServiceName}, not used by another certificate.");
        }
        else req.FeeOPDServiceId = null;
        if (req.ValidFrom is { } vf && req.ValidTo is { } vt && vt < vf) return (0, "The 'to' date is before the 'from' date.");
        if (req.TypeCode is "SICK" && (req.ValidFrom == null || req.ValidTo == null)) return (0, "Enter the leave period (from and to).");
        if (req.TypeCode is "RESUME" && Body(req).GetValueOrDefault("resumeOn") is not { Length: > 0 }) return (0, "Enter the date the patient is fit to resume duty.");
        if (req.TypeCode is "FIT" && Body(req).GetValueOrDefault("verdict") is not { Length: > 0 }) return (0, "Choose the fitness verdict.");
        if (req.TypeCode is "DIS")
        {
            var b = Body(req);
            if (b.GetValueOrDefault("disabilityTypeId") is not { Length: > 0 }) return (0, "Choose the type of disability.");
            if (!decimal.TryParse(b.GetValueOrDefault("percentage"), out var pct) || pct < 0 || pct > 100) return (0, "Enter the disability percentage (0 to 100).");
        }
        var doses = req.TypeCode == "VACC" ? (req.Doses ?? new()).Where(d => d.VaccineId > 0).ToList() : new();
        if (req.TypeCode == "VACC")
        {
            var vaccines = (await GetVaccinesAsync(companyId, false)).Select(v => v.VaccineId).ToHashSet();
            if (doses.Any(d => !vaccines.Contains(d.VaccineId))) return (0, "Unknown vaccine.");
            if (doses.Any(d => d.GivenOn == null || d.GivenOn > DateTime.Today)) return (0, "Each dose needs the date given (not in the future).");
            if (doses.Count == 0 && (await GetVaccinationsAsync(companyId, req.PatientId)).Count == 0)
                return (0, "Record at least one vaccine dose.");
        }

        var bodyJson = req.Body is { ValueKind: JsonValueKind.Object } bj ? bj.GetRawText() : null;
        var purposeText = req.PurposeText?.Trim();
        if (req.PurposeId is > 0)
            purposeText = (await GetPurposesAsync(companyId, false)).FirstOrDefault(p => p.PurposeId == req.PurposeId)?.PurposeName ?? purposeText;
        var validTo = req.ValidTo;
        if (req.TypeCode == "FIT" && validTo == null && type.DefaultValidityDays is > 0)
            validTo = (req.IssueDate ?? DateTime.Today).AddDays(type.DefaultValidityDays.Value);

        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();
        int id = req.CertificateId;
        var p = new
        {
            companyId, branchId, req.TypeCode, req.PatientId, OPDServiceId = req.OPDServiceId is > 0 ? req.OPDServiceId : null, req.DoctorId,
            PurposeId = req.PurposeId is > 0 ? req.PurposeId : null, PurposeText = purposeText, IssueDate = req.IssueDate?.Date,
            ValidFrom = req.ValidFrom?.Date, ValidTo = validTo?.Date, Diagnosis = req.Diagnosis?.Trim(), Remarks = req.Remarks?.Trim(),
            BodyJson = bodyJson, req.FeeMode, req.FeeOPDServiceId, userId, id
        };
        if (id > 0)
        {
            var status = await con.ExecuteScalarAsync<string?>("SELECT Status FROM dbo.PatientCertificate WITH (UPDLOCK) WHERE CertificateId = @id AND BranchId = @branchId",
                new { id, branchId }, tx);
            if (status == null) return (0, "Certificate not found.");
            if (status != "D") return (0, "An issued or cancelled certificate cannot be changed. Cancel it and reissue.");
            await con.ExecuteAsync(@"UPDATE dbo.PatientCertificate SET TypeCode = @TypeCode, PatientId = @PatientId, OPDServiceId = @OPDServiceId,
                DoctorId = @DoctorId, PurposeId = @PurposeId, PurposeText = @PurposeText, IssueDate = @IssueDate, ValidFrom = @ValidFrom, ValidTo = @ValidTo,
                Diagnosis = @Diagnosis, Remarks = @Remarks, BodyJson = @BodyJson, FeeMode = @FeeMode, FeeOPDServiceId = @FeeOPDServiceId,
                ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE CertificateId = @id", p, tx);
        }
        else
        {
            id = await con.ExecuteScalarAsync<int>(@"INSERT dbo.PatientCertificate (CompanyId, BranchId, TypeCode, PatientId, OPDServiceId, DoctorId, PurposeId,
                PurposeText, IssueDate, ValidFrom, ValidTo, Diagnosis, Remarks, BodyJson, FeeMode, FeeOPDServiceId, Status, CreatedBy)
                VALUES (@companyId, @branchId, @TypeCode, @PatientId, @OPDServiceId, @DoctorId, @PurposeId, @PurposeText, @IssueDate, @ValidFrom, @ValidTo,
                        @Diagnosis, @Remarks, @BodyJson, @FeeMode, @FeeOPDServiceId, 'D', @userId);
                SELECT CAST(SCOPE_IDENTITY() AS INT);", p, tx);
        }
        // doses recorded on this certificate: the draft's set is replaced on every save
        await con.ExecuteAsync("DELETE FROM dbo.PatientVaccination WHERE CertificateId = @id", new { id }, tx);
        foreach (var d in doses)
            await con.ExecuteAsync(@"INSERT dbo.PatientVaccination (CompanyId, BranchId, PatientId, VaccineId, DoseNo, GivenOn, BatchNo, Manufacturer,
                ExpiryDate, Route, Site, GivenBy, NextDueDate, CertificateId, CreatedBy)
                VALUES (@companyId, @branchId, @PatientId, @VaccineId, @DoseNo, @GivenOn, @BatchNo, @Manufacturer, @ExpiryDate, @Route, @Site,
                        @GivenBy, @NextDueDate, @id, @userId)",
                new { companyId, branchId, req.PatientId, d.VaccineId, DoseNo = Math.Max(1, d.DoseNo), GivenOn = d.GivenOn!.Value.Date, d.BatchNo,
                      d.Manufacturer, ExpiryDate = d.ExpiryDate?.Date, d.Route, d.Site, d.GivenBy, NextDueDate = d.NextDueDate?.Date, id, userId }, tx);
        tx.Commit();
        return (id, null);
    }

    private static Dictionary<string, string> Body(CertificateSaveRequest req)
    {
        var r = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (req.Body is { ValueKind: JsonValueKind.Object } b)
            foreach (var p in b.EnumerateObject())
                r[p.Name] = p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString() ?? "" : p.Value.ToString();
        return r;
    }

    public async Task<(string? No, string? Error)> IssueAsync(int branchId, int certificateId, int userId)
    {
        using var con = db.CreateConnection();
        try
        {
            var r = await con.QueryFirstAsync("dbo.usp_Certificate_Issue", new { CertificateId = certificateId, BranchId = branchId, UserId = userId },
                commandType: System.Data.CommandType.StoredProcedure);
            return ((string)r.CertificateNo, null);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50040 or 50041 or 50042)
        {
            return (null, ex.Message);
        }
    }

    public async Task<string?> CancelAsync(int branchId, int certificateId, int userId, string reason)
    {
        if (string.IsNullOrWhiteSpace(reason)) return "Enter the reason for cancelling.";
        using var con = db.CreateConnection();
        var n = await con.ExecuteAsync(@"UPDATE dbo.PatientCertificate SET Status = 'C', CancelledBy = @userId, CancelledOn = GETDATE(),
            CancelReason = @reason, ModifiedBy = @userId, ModifiedDate = GETDATE()
            WHERE CertificateId = @certificateId AND BranchId = @branchId AND Status IN ('I', 'D')",
            new { certificateId, branchId, userId, reason = reason.Trim()[..Math.Min(300, reason.Trim().Length)] });
        if (n == 0) return "Only a draft or an issued certificate can be cancelled.";
        // doses recorded on a cancelled draft are not part of the patient's history
        await con.ExecuteAsync(@"UPDATE pv SET IsActive = 0 FROM dbo.PatientVaccination pv JOIN dbo.PatientCertificate c ON c.CertificateId = pv.CertificateId
            WHERE pv.CertificateId = @certificateId AND c.IssuedOn IS NULL", new { certificateId });
        return null;
    }

    public async Task<(int Id, string? Error)> ReissueAsync(int branchId, int certificateId, int userId)
    {
        using var con = db.CreateConnection();
        var id = await con.ExecuteScalarAsync<int?>(@"
            INSERT dbo.PatientCertificate (CompanyId, BranchId, TypeCode, PatientId, OPDServiceId, DoctorId, PurposeId, PurposeText, IssueDate,
                   ValidFrom, ValidTo, Diagnosis, Remarks, BodyJson, FeeMode, FeeOPDServiceId, Status, ReissueOfId, CreatedBy)
            SELECT CompanyId, BranchId, TypeCode, PatientId, OPDServiceId, DoctorId, PurposeId, PurposeText, CAST(GETDATE() AS DATE),
                   ValidFrom, ValidTo, Diagnosis, Remarks, BodyJson, FeeMode, FeeOPDServiceId, 'D', CertificateId, @userId
              FROM dbo.PatientCertificate WHERE CertificateId = @certificateId AND BranchId = @branchId AND Status = 'C';
            SELECT CAST(SCOPE_IDENTITY() AS INT);", new { certificateId, branchId, userId });
        return id is > 0 ? (id.Value, null) : (0, "Only a cancelled certificate can be reissued.");
    }

    public async Task<CertificatePrintModel?> GetPrintModelAsync(int branchId, int certificateId)
    {
        var c = await GetAsync(branchId, certificateId);
        if (c == null) return null;
        var m = new CertificatePrintModel { Certificate = c };
        m.Type = (await GetTypesAsync(c.CompanyId, branchId, false)).FirstOrDefault(t => t.TypeCode == c.TypeCode)
                 ?? new CertificateTypeRow { TypeCode = c.TypeCode, TypeName = c.TypeCode, PrintTitle = c.TypeCode };
        m.Patient = await GetPatientAsync(c.CompanyId, c.PatientId) ?? new CertificatePatient();
        if (c.DoctorId is > 0) m.Doctor = (await GetDoctorsAsync(c.CompanyId, branchId, false)).FirstOrDefault(d => d.DoctorId == c.DoctorId);
        if (c.OPDServiceId is > 0) m.Visit = await GetVisitAsync(branchId, c.OPDServiceId.Value);
        if (c.FeeOPDServiceId is > 0) m.FeeBill = await GetVisitAsync(branchId, c.FeeOPDServiceId.Value);
        if (c.TypeCode == "VACC")
        {
            var all = await GetVaccinationsAsync(c.CompanyId, c.PatientId);
            // an issued certificate shows the doses recorded up to it, not those added later
            m.Vaccinations = c.Status == "I" && c.IssuedOn is { } on ? all.Where(v => v.CertificateId == c.CertificateId || v.GivenOn <= on.Date).ToList() : all;
        }
        if (!string.IsNullOrWhiteSpace(c.BodyJson))
        {
            try
            {
                using var doc = JsonDocument.Parse(c.BodyJson);
                foreach (var p in doc.RootElement.EnumerateObject())
                    m.Body[p.Name] = p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString() : p.Value.ToString();
            }
            catch (JsonException) { }
        }
        if (c.TypeCode == "DIS" && int.TryParse(m.B("disabilityTypeId"), out var dt))
        {
            var d = (await GetDisabilityTypesAsync()).FirstOrDefault(x => x.DisabilityTypeId == dt);
            m.DisabilityName = d?.Name; m.DisabilityForm = d?.AssessmentForm;
        }
        using var con = db.CreateConnection();
        var h = await con.QueryFirstOrDefaultAsync(@"SELECT TOP 1 h.HotelName, h.Address, h.ContactNumber1, h.EmailAddress, h.RegistrationNumber, h.LogoPath,
                   b.BranchName, b.Address AS BranchAddress
              FROM dbo.BranchMaster b LEFT JOIN dbo.HospitalSettings h ON h.BranchID = b.BranchID
             WHERE b.BranchID = @branchId", new { branchId });
        if (h != null)
        {
            m.HospitalName = h.HotelName ?? h.BranchName; m.HospitalAddress = h.Address ?? h.BranchAddress; m.HospitalPhone = h.ContactNumber1;
            m.HospitalEmail = h.EmailAddress; m.HospitalRegNo = h.RegistrationNumber; m.LogoPath = h.LogoPath; m.BranchName = h.BranchName;
        }
        return m;
    }

    public async Task MarkPrintedAsync(int certificateId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("UPDATE dbo.PatientCertificate SET PrintCount = PrintCount + 1, LastPrintedOn = GETDATE() WHERE CertificateId = @certificateId AND Status = 'I'",
            new { certificateId });
    }

    private static readonly Regex TokenShape = new("^[a-f0-9]{32}$", RegexOptions.Compiled);

    public async Task<CertificateVerifyModel> VerifyAsync(string token)
    {
        if (string.IsNullOrWhiteSpace(token) || !TokenShape.IsMatch(token)) return new CertificateVerifyModel();
        using var con = db.CreateConnection();
        var r = await con.QueryFirstOrDefaultAsync(@"
            SELECT c.CertificateNo, ISNULL(t.TypeName, c.TypeCode) AS TypeName, c.Status, c.IssueDate, c.ValidTo, c.CancelReason,
                   pm.FirstName, pm.LastName, LTRIM(RTRIM(ISNULL(d.NamePrefix, '') + ' ' + ISNULL(d.FullName, ''))) AS DoctorName,
                   ISNULL(NULLIF(dp.RegistrationNo, ''), d.MedicalLicenseNo) AS DoctorRegNo, ISNULL(h.HotelName, b.BranchName) AS HospitalName
              FROM dbo.PatientCertificate c
              JOIN dbo.PatientMaster pm ON pm.PatientId = c.PatientId
              LEFT JOIN dbo.CertificateTypeMaster t ON t.CompanyId = c.CompanyId AND t.TypeCode = c.TypeCode
              LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
              LEFT JOIN dbo.CertificateDoctorProfile dp ON dp.DoctorId = c.DoctorId
              LEFT JOIN dbo.BranchMaster b ON b.BranchID = c.BranchId
              LEFT JOIN dbo.HospitalSettings h ON h.BranchID = c.BranchId
             WHERE c.VerifyToken = @token AND c.Status IN ('I', 'C')", new { token });
        if (r == null) return new CertificateVerifyModel();
        static string Mask(string? s) => string.IsNullOrWhiteSpace(s) ? "" : s.Trim()[0] + new string('*', Math.Max(2, s.Trim().Length - 1));
        return new CertificateVerifyModel
        {
            Found = true, CertificateNo = r.CertificateNo, TypeName = r.TypeName, Status = r.Status, IssueDate = r.IssueDate, ValidTo = r.ValidTo,
            PatientMasked = $"{Mask((string?)r.FirstName)} {Mask((string?)r.LastName)}".Trim(), DoctorName = r.DoctorName, DoctorRegNo = r.DoctorRegNo,
            HospitalName = r.HospitalName, CancelReason = r.Status == "C" ? r.CancelReason : null
        };
    }
}
