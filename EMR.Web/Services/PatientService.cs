using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class PatientService(IDbConnectionFactory db) : IPatientService
{
    // ─── List ─────────────────────────────────────────────────────────────────

    public async Task<IEnumerable<PatientListItemViewModel>> GetListForBranchAsync(int? branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PatientListItemViewModel>(@"
            SELECT
                p.PatientId,
                p.PatientCode,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                )) AS FullName,
                p.PhoneNumber,
                p.Gender,
                p.BloodGroup,
                p.CreatedDate,
                p.IsActive,
                d.FullName AS ConsultingDoctorName
            FROM PatientMaster p
            OUTER APPLY (
                SELECT TOP 1 ConsultingDoctorId
                FROM PatientOPDService
                WHERE PatientId = p.PatientId AND IsActive = 1
                ORDER BY OPDServiceId DESC
            ) latest
            LEFT JOIN DoctorMaster d ON d.DoctorId = latest.ConsultingDoctorId
            WHERE p.IsActive = 1
              AND (@BranchId IS NULL OR p.BranchId = @BranchId)
            ORDER BY p.CreatedDate DESC",
            new { BranchId = branchId });
    }

    // ─── Get By ID ────────────────────────────────────────────────────────────

    public async Task<PatientMaster?> GetByIdAsync(int patientId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PatientMaster>(
            "SELECT * FROM PatientMaster WHERE PatientId = @PatientId",
            new { PatientId = patientId });
    }

    // ─── Quick Search ─────────────────────────────────────────────────────────

    public async Task<IEnumerable<PatientQuickSearchResult>> SearchByPhoneAsync(string phone)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PatientQuickSearchResult>(@"
            SELECT TOP 10
                p.PatientId,
                p.PatientCode,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                )) AS FullName,
                p.PhoneNumber,
                p.Gender,
                p.BloodGroup
            FROM PatientMaster p
            WHERE p.IsActive = 1
              AND (p.PhoneNumber LIKE @Phone OR p.SecondaryPhoneNumber LIKE @Phone)
            ORDER BY p.CreatedDate DESC",
            new { Phone = "%" + phone + "%" });
    }

    public async Task<IEnumerable<PatientQuickSearchResult>> SearchByCodeAsync(string code)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PatientQuickSearchResult>(@"
            SELECT TOP 10
                p.PatientId,
                p.PatientCode,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                )) AS FullName,
                p.PhoneNumber,
                p.Gender,
                p.BloodGroup
            FROM PatientMaster p
            WHERE p.IsActive = 1
              AND p.PatientCode LIKE @Code
            ORDER BY p.PatientCode",
            new { Code = "%" + code + "%" });
    }

    // ─── Create ───────────────────────────────────────────────────────────────

    public async Task<string> CreateAsync(PatientMaster patient, PatientOPDService opdService, int? userId)
    {
        using var con = db.CreateConnection();

        var p = new DynamicParameters();

        // PatientMaster fields
        p.Add("@PhoneNumber",            patient.PhoneNumber);
        p.Add("@SecondaryPhoneNumber",   patient.SecondaryPhoneNumber);
        p.Add("@Salutation",             patient.Salutation);
        p.Add("@FirstName",              patient.FirstName);
        p.Add("@MiddleName",             patient.MiddleName);
        p.Add("@LastName",               patient.LastName);
        p.Add("@Gender",                 patient.Gender);
        p.Add("@ReligionId",             patient.ReligionId);
        p.Add("@EmailId",                patient.EmailId);
        p.Add("@GuardianName",           patient.GuardianName);
        p.Add("@CountryId",              patient.CountryId);
        p.Add("@StateId",                patient.StateId);
        p.Add("@DistrictId",             patient.DistrictId);
        p.Add("@CityId",                 patient.CityId);
        p.Add("@AreaId",                 patient.AreaId);
        p.Add("@IdentificationTypeId",   patient.IdentificationTypeId);
        p.Add("@IdentificationNumber",   patient.IdentificationNumber);
        p.Add("@IdentificationFilePath", patient.IdentificationFilePath);
        p.Add("@OccupationId",           patient.OccupationId);
        p.Add("@MaritalStatusId",        patient.MaritalStatusId);
        p.Add("@BloodGroup",             patient.BloodGroup);
        p.Add("@KnownAllergies",         patient.KnownAllergies);
        p.Add("@Remarks",                patient.Remarks);
        p.Add("@BranchId",               patient.BranchId);
        p.Add("@UserId",                 userId);

        // PatientOPDService fields
        p.Add("@ConsultingDoctorId", opdService.ConsultingDoctorId);
        p.Add("@ServiceType",        opdService.ServiceType);
        p.Add("@ServiceId",          opdService.ServiceId);
        p.Add("@ServiceCharges",     opdService.ServiceCharges);

        // OUTPUT parameters
        p.Add("@PatientCode",  dbType: DbType.String,  size: 20, direction: ParameterDirection.Output);
        p.Add("@NewPatientId", dbType: DbType.Int32,             direction: ParameterDirection.Output);

        await con.ExecuteAsync("dbo.usp_Patient_Create", p,
            commandType: CommandType.StoredProcedure);

        return p.Get<string>("@PatientCode");
    }

    // ─── Update ───────────────────────────────────────────────────────────────

    public async Task UpdateAsync(PatientMaster patient, PatientOPDService opdService, int? userId)
    {
        using var con = db.CreateConnection();

        var p = new DynamicParameters();

        // PatientMaster fields
        p.Add("@PatientId",              patient.PatientId);
        p.Add("@PhoneNumber",            patient.PhoneNumber);
        p.Add("@SecondaryPhoneNumber",   patient.SecondaryPhoneNumber);
        p.Add("@Salutation",             patient.Salutation);
        p.Add("@FirstName",              patient.FirstName);
        p.Add("@MiddleName",             patient.MiddleName);
        p.Add("@LastName",               patient.LastName);
        p.Add("@Gender",                 patient.Gender);
        p.Add("@ReligionId",             patient.ReligionId);
        p.Add("@EmailId",                patient.EmailId);
        p.Add("@GuardianName",           patient.GuardianName);
        p.Add("@CountryId",              patient.CountryId);
        p.Add("@StateId",                patient.StateId);
        p.Add("@DistrictId",             patient.DistrictId);
        p.Add("@CityId",                 patient.CityId);
        p.Add("@AreaId",                 patient.AreaId);
        p.Add("@IdentificationTypeId",   patient.IdentificationTypeId);
        p.Add("@IdentificationNumber",   patient.IdentificationNumber);
        p.Add("@IdentificationFilePath", patient.IdentificationFilePath);
        p.Add("@OccupationId",           patient.OccupationId);
        p.Add("@MaritalStatusId",        patient.MaritalStatusId);
        p.Add("@BloodGroup",             patient.BloodGroup);
        p.Add("@KnownAllergies",         patient.KnownAllergies);
        p.Add("@Remarks",                patient.Remarks);
        p.Add("@UserId",                 userId);

        // PatientOPDService fields
        p.Add("@OPDServiceId",       opdService.OPDServiceId);
        p.Add("@BranchId",           opdService.BranchId);
        p.Add("@ConsultingDoctorId", opdService.ConsultingDoctorId);
        p.Add("@ServiceType",        opdService.ServiceType);
        p.Add("@ServiceId",          opdService.ServiceId);
        p.Add("@ServiceCharges",     opdService.ServiceCharges);

        await con.ExecuteAsync("dbo.usp_Patient_Update", p,
            commandType: CommandType.StoredProcedure);
    }

    // ─── Demographics-only Update ────────────────────────────────────

    public async Task UpdateDemographicsAsync(PatientMaster patient, int? userId)
    {
        using var con = db.CreateConnection();
        patient.ModifiedBy   = userId;
        patient.ModifiedDate = DateTime.UtcNow;
        await con.ExecuteAsync(@"
            UPDATE PatientMaster SET
                PhoneNumber            = @PhoneNumber,
                SecondaryPhoneNumber   = @SecondaryPhoneNumber,
                Salutation             = @Salutation,
                FirstName              = @FirstName,
                MiddleName             = @MiddleName,
                LastName               = @LastName,
                Gender                 = @Gender,
                ReligionId             = @ReligionId,
                EmailId                = @EmailId,
                GuardianName           = @GuardianName,
                CountryId              = @CountryId,
                StateId                = @StateId,
                DistrictId             = @DistrictId,
                CityId                 = @CityId,
                AreaId                 = @AreaId,
                IdentificationTypeId   = @IdentificationTypeId,
                IdentificationNumber   = @IdentificationNumber,
                IdentificationFilePath = @IdentificationFilePath,
                OccupationId           = @OccupationId,
                MaritalStatusId        = @MaritalStatusId,
                BloodGroup             = @BloodGroup,
                KnownAllergies         = @KnownAllergies,
                Remarks                = @Remarks,
                ModifiedBy             = @ModifiedBy,
                ModifiedDate           = @ModifiedDate
            WHERE PatientId = @PatientId", patient);
    }

    // ─── Delete ───────────────────────────────────────────────────────────────

    public async Task DeleteAsync(int patientId, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "UPDATE PatientMaster SET IsActive=0, ModifiedBy=@UserId, ModifiedDate=SYSUTCDATETIME() WHERE PatientId=@PatientId",
            new { PatientId = patientId, UserId = userId });
    }

    // ─── Latest OPD Service ───────────────────────────────────────────────────

    public async Task<PatientOPDService?> GetLatestOPDServiceAsync(int patientId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PatientOPDService>(@"
            SELECT TOP 1 *
            FROM PatientOPDService
            WHERE PatientId = @PatientId AND IsActive = 1
            ORDER BY OPDServiceId DESC",
            new { PatientId = patientId });
    }

    // ─── OPD Doctors ─────────────────────────────────────────────────────────

    public async Task<IEnumerable<(int DoctorId, string FullName)>> GetOpdDoctorsAsync(int? branchId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync(@"
            SELECT DISTINCT d.DoctorId, d.FullName
            FROM DoctorMaster d
            INNER JOIN DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
            INNER JOIN DepartmentMaster    dm  ON dm.DeptId    = ddm.DeptId  AND dm.DeptType = 'OPD' AND dm.IsActive = 1
            WHERE d.IsActive = 1
              AND (@BranchId IS NULL
                   OR d.CreatedBranchId = @BranchId
                   OR EXISTS (
                        SELECT 1 FROM DoctorBranchMap dbm
                        WHERE dbm.DoctorId = d.DoctorId AND dbm.BranchId = @BranchId AND dbm.IsActive = 1))
            ORDER BY d.FullName",
            new { BranchId = branchId });

        return rows.Select(r => ((int)r.DoctorId, (string)r.FullName));
    }

    // ─── Services by Type ─────────────────────────────────────────────────────

    public async Task<IEnumerable<(int ServiceId, string ItemName, decimal ItemCharges)>> GetServicesByTypeAsync(string serviceType, int? branchId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync(@"
            SELECT s.ServiceId, s.ItemName, s.ItemCharges
            FROM ServiceMaster s
            WHERE s.IsActive = 1
              AND s.ServiceType = @ServiceType
              AND (@BranchId IS NULL OR s.BranchId = @BranchId)
            ORDER BY s.ItemName",
            new { ServiceType = serviceType, BranchId = branchId });

        return rows.Select(r => ((int)r.ServiceId, (string)r.ItemName, (decimal)r.ItemCharges));
    }
}
