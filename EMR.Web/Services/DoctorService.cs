using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class DoctorService(IDbConnectionFactory db) : IDoctorService
{
    public async Task<IEnumerable<DoctorListItemViewModel>> GetListForBranchAsync(int? branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorListItemViewModel>(@"
            SELECT
                d.DoctorId,
                ISNULL(d.NamePrefix + ' ', '') + d.FullName AS FullName,
                ps.SpecialityName AS PrimarySpecialityName,
                ISNULL(dep.DepartmentNames, '') AS DepartmentNames,
                d.PhoneNumber,
                d.EmailId,
                d.IsActive,
                ISNULL(fees.ConsultingFeeNames, '') AS ConsultingFeeNames,
                CAST(CASE WHEN EXISTS (
                    SELECT 1
                    FROM DoctorDepartmentMap ddm2
                    INNER JOIN DepartmentMaster dm2 ON dm2.DeptId = ddm2.DeptId
                    WHERE ddm2.DoctorId = d.DoctorId
                      AND ddm2.IsActive = 1
                      AND dm2.DeptType  = 'OPD'
                ) THEN 1 ELSE 0 END AS BIT) AS HasOPDDept
            FROM DoctorMaster d
            INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId
            OUTER APPLY
            (
                SELECT STUFF((
                    SELECT ', ' + dm.DeptName
                    FROM DoctorDepartmentMap ddm
                    INNER JOIN DepartmentMaster dm ON dm.DeptId = ddm.DeptId
                    WHERE ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
                    FOR XML PATH(''), TYPE
                ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS DepartmentNames
            ) dep
            OUTER APPLY
            (
                SELECT STUFF((
                    SELECT N', ' + s.ItemName + N' (₹' + CAST(CAST(s.ItemCharges AS DECIMAL(18,0)) AS NVARCHAR) + N')'
                    FROM DoctorConsultingFeeMap m
                    INNER JOIN ServiceMaster s ON s.ServiceId = m.ServiceId
                    WHERE m.DoctorId = d.DoctorId
                      AND m.BranchId = ISNULL(@branchId, m.BranchId)
                      AND m.IsActive = 1
                    FOR XML PATH(''), TYPE
                ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS ConsultingFeeNames
            ) fees
            WHERE @branchId IS NULL
               OR d.CreatedBranchId = @branchId
               OR EXISTS (
                    SELECT 1
                    FROM DoctorBranchMap dbm
                    WHERE dbm.DoctorId = d.DoctorId
                      AND dbm.BranchId = @branchId
                      AND dbm.IsActive = 1
               )
            ORDER BY d.FullName", new { branchId });
    }

    public async Task<DoctorMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<DoctorMaster>(
            "SELECT * FROM DoctorMaster WHERE DoctorId = @id", new { id });
    }

    public async Task<DoctorDetailsViewModel?> GetDetailsAsync(int id, int? branchId)
    {
        using var con = db.CreateConnection();

        var doctor = await con.QueryFirstOrDefaultAsync<DoctorDetailsViewModel>(@"
            SELECT
                d.DoctorId,
                ISNULL(d.NamePrefix + ' ', '') + d.FullName AS FullName,
                d.Gender,
                d.DateOfBirth,
                d.EmailId,
                d.PhoneNumber,
                d.MedicalLicenseNo,
                d.PrimarySpecialityId,
                ps.SpecialityName AS PrimarySpecialityName,
                d.SecondarySpecialityId,
                ss.SpecialityName AS SecondarySpecialityName,
                d.JoiningDate,
                d.IsActive,
                d.IsReferralDoctor,
                d.IsSuspended, d.SuspendReason, d.SuspendedAt, su.FullName AS SuspendedByName,
                d.CreatedDate,
                d.ModifiedDate,
                d.LinkedUserId,
                u.Username AS LoginUsername,
                ISNULL(u.IsActive, 0) AS IsLoginActive
            FROM DoctorMaster d
            INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId
            LEFT JOIN DoctorSpecialityMaster ss ON ss.SpecialityId = d.SecondarySpecialityId
            LEFT JOIN Users u ON u.Id = d.LinkedUserId
            LEFT JOIN Users su ON su.Id = d.SuspendedBy
            WHERE d.DoctorId = @id
              AND (
                  @branchId IS NULL
                  OR d.CreatedBranchId = @branchId
                  OR EXISTS (
                        SELECT 1
                        FROM DoctorBranchMap dbm
                        WHERE dbm.DoctorId = d.DoctorId
                          AND dbm.BranchId = @branchId
                          AND dbm.IsActive = 1
                    )
              )", new { id, branchId });

        if (doctor is null) return null;

        var branches = await con.QueryAsync<string>(@"
            SELECT b.BranchName
            FROM DoctorBranchMap dbm
            INNER JOIN Branchmaster b ON b.BranchID = dbm.BranchId
            WHERE dbm.DoctorId = @id AND dbm.IsActive = 1
            ORDER BY b.BranchName", new { id });

        var departments = await con.QueryAsync<string>(@"
            SELECT dm.DeptName
            FROM DoctorDepartmentMap ddm
            INNER JOIN DepartmentMaster dm ON dm.DeptId = ddm.DeptId
            WHERE ddm.DoctorId = @id AND ddm.IsActive = 1
            ORDER BY dm.DeptName", new { id });

        doctor.BranchNames = branches.ToList();
        doctor.DepartmentNames = departments.ToList();

        return doctor;
    }

    public async Task<List<int>> GetBranchIdsAsync(int doctorId)
    {
        using var con = db.CreateConnection();
        var branchIds = await con.QueryAsync<int>(
            "SELECT BranchId FROM DoctorBranchMap WHERE DoctorId = @doctorId AND IsActive = 1",
            new { doctorId });
        return branchIds.ToList();
    }

    public async Task<List<int>> GetDepartmentIdsAsync(int doctorId)
    {
        using var con = db.CreateConnection();
        var deptIds = await con.QueryAsync<int>(
            "SELECT DeptId FROM DoctorDepartmentMap WHERE DoctorId = @doctorId AND IsActive = 1",
            new { doctorId });
        return deptIds.ToList();
    }

    public async Task<bool> IsVisibleForBranchAsync(int doctorId, int? branchId)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1)
            FROM DoctorMaster d
            WHERE d.DoctorId = @doctorId
              AND (
                    @branchId IS NULL
                    OR d.CreatedBranchId = @branchId
                    OR EXISTS (
                        SELECT 1
                        FROM DoctorBranchMap dbm
                        WHERE dbm.DoctorId = d.DoctorId
                          AND dbm.BranchId = @branchId
                          AND dbm.IsActive = 1
                    )
              )", new { doctorId, branchId });

        return count > 0;
    }

    public async Task<int> CreateAsync(DoctorMaster doctor, IEnumerable<int> branchIds, IEnumerable<int> departmentIds, int? userId)
    {
        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();

        try
        {
            var doctorId = await con.ExecuteScalarAsync<int>(@"
                INSERT INTO DoctorMaster
                (
                    CompanyId, NamePrefix, FullName, Gender, DateOfBirth, EmailId, PhoneNumber, MedicalLicenseNo,
                    PrimarySpecialityId, SecondarySpecialityId, JoiningDate, IsActive, IsReferralDoctor,
                    CreatedBranchId, LinkedUserId, CreatedBy, CreatedDate
                )
                VALUES
                (
                    @CompanyId, @NamePrefix, @FullName, @Gender, @DateOfBirth, @EmailId, @PhoneNumber, @MedicalLicenseNo,
                    @PrimarySpecialityId, @SecondarySpecialityId, @JoiningDate, @IsActive, @IsReferralDoctor,
                    @CreatedBranchId, @LinkedUserId, @userId, GETDATE()
                );
                SELECT CAST(SCOPE_IDENTITY() AS INT);",
                new
                {
                    // the doctor belongs to the company it is created in (Doctor Master is company-wise)
                    CompanyId = doctor.CompanyId > 0 ? doctor.CompanyId : 1,
                    doctor.NamePrefix,
                    doctor.FullName,
                    doctor.Gender,
                    doctor.DateOfBirth,
                    doctor.EmailId,
                    doctor.PhoneNumber,
                    doctor.MedicalLicenseNo,
                    doctor.PrimarySpecialityId,
                    doctor.SecondarySpecialityId,
                    doctor.JoiningDate,
                    doctor.IsActive,
                    doctor.IsReferralDoctor,
                    doctor.CreatedBranchId,
                    doctor.LinkedUserId,
                    userId
                }, tx);

            foreach (var branchId in branchIds.Distinct())
            {
                await con.ExecuteAsync(@"
                    INSERT INTO DoctorBranchMap (DoctorId, BranchId, CompanyId, IsActive, CreatedBy, CreatedDate)
                    VALUES (@doctorId, @branchId, ISNULL((SELECT CompanyId FROM BranchMaster WHERE BranchId = @branchId), 1), 1, @userId, GETDATE())",
                    new { doctorId, branchId, userId }, tx);
            }

            foreach (var deptId in departmentIds.Distinct())
            {
                await con.ExecuteAsync(@"
                    INSERT INTO DoctorDepartmentMap (DoctorId, DeptId, IsActive, CreatedBy, CreatedDate)
                    VALUES (@doctorId, @deptId, 1, @userId, GETDATE())",
                    new { doctorId, deptId, userId }, tx);
            }

            tx.Commit();
            return doctorId;
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    public async Task SetLinkedUserAsync(int doctorId, int? linkedUserId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("UPDATE DoctorMaster SET LinkedUserId = @linkedUserId WHERE DoctorId = @doctorId", new { doctorId, linkedUserId });
    }

    public async Task UpdateAsync(DoctorMaster doctor, IEnumerable<int> branchIds, IEnumerable<int> departmentIds, int? userId)
    {
        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();

        try
        {
            await con.ExecuteAsync(@"
                UPDATE DoctorMaster SET
                    NamePrefix            = @NamePrefix,
                    FullName              = @FullName,
                    Gender                = @Gender,
                    DateOfBirth           = @DateOfBirth,
                    EmailId               = @EmailId,
                    PhoneNumber           = @PhoneNumber,
                    MedicalLicenseNo      = @MedicalLicenseNo,
                    PrimarySpecialityId   = @PrimarySpecialityId,
                    SecondarySpecialityId = @SecondarySpecialityId,
                    JoiningDate           = @JoiningDate,
                    IsActive              = @IsActive,
                    IsReferralDoctor      = @IsReferralDoctor,
                    IsSuspended           = @IsSuspended,     -- SQLScripts/2484: reason / who / when set by the controller
                    SuspendReason         = @SuspendReason,
                    SuspendedBy           = @SuspendedBy,
                    SuspendedAt           = @SuspendedAt,
                    LinkedUserId          = @LinkedUserId,
                    ModifiedBy            = @userId,
                    ModifiedDate          = GETDATE()
                WHERE DoctorId = @DoctorId",
                new
                {
                    doctor.DoctorId,
                    doctor.NamePrefix,
                    doctor.FullName,
                    doctor.Gender,
                    doctor.DateOfBirth,
                    doctor.EmailId,
                    doctor.PhoneNumber,
                    doctor.MedicalLicenseNo,
                    doctor.PrimarySpecialityId,
                    doctor.SecondarySpecialityId,
                    doctor.JoiningDate,
                    doctor.IsActive,
                    doctor.IsReferralDoctor,
                    doctor.IsSuspended,
                    doctor.SuspendReason,
                    doctor.SuspendedBy,
                    doctor.SuspendedAt,
                    doctor.LinkedUserId,
                    userId
                }, tx);

            await con.ExecuteAsync("DELETE FROM DoctorBranchMap WHERE DoctorId = @DoctorId", new { doctor.DoctorId }, tx);
            await con.ExecuteAsync("DELETE FROM DoctorDepartmentMap WHERE DoctorId = @DoctorId", new { doctor.DoctorId }, tx);

            foreach (var branchId in branchIds.Distinct())
            {
                await con.ExecuteAsync(@"
                    INSERT INTO DoctorBranchMap (DoctorId, BranchId, CompanyId, IsActive, CreatedBy, CreatedDate)
                    VALUES (@doctorId, @branchId, ISNULL((SELECT CompanyId FROM BranchMaster WHERE BranchId = @branchId), 1), 1, @userId, GETDATE())",
                    new { doctorId = doctor.DoctorId, branchId, userId }, tx);
            }

            foreach (var deptId in departmentIds.Distinct())
            {
                await con.ExecuteAsync(@"
                    INSERT INTO DoctorDepartmentMap (DoctorId, DeptId, IsActive, CreatedBy, CreatedDate)
                    VALUES (@doctorId, @deptId, 1, @userId, GETDATE())",
                    new { doctorId = doctor.DoctorId, deptId, userId }, tx);
            }

            tx.Commit();
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    // ── Suspension (SQLScripts/2484) ─────────────────────────────────────────────────────────────────────────────
    /// <summary>
    /// The refusal for a suspended doctor in a booking - as referral doctor (LAB B2C / B2B) or consulting doctor (OPD) -
    /// with the doctor's name and the reason; null when the doctor may be used. keepOpdServiceId: an OPD visit being
    /// edited - a doctor already on that visit is kept (only changing TO a suspended doctor is refused).
    /// </summary>
    public async Task<string?> SuspensionBlockAsync(int? doctorId, string role, int? keepOpdServiceId = null)
    {
        if (doctorId is not > 0) return null;
        using var con = db.CreateConnection();
        var d = await con.QueryFirstOrDefaultAsync<(string? Name, bool IsSuspended, string? Reason)>(
            "SELECT LTRIM(RTRIM(ISNULL(NamePrefix + ' ', '') + FullName)), IsSuspended, SuspendReason FROM DoctorMaster WHERE DoctorId = @doctorId",
            new { doctorId });
        if (!d.IsSuspended) return null;
        if (keepOpdServiceId is > 0)
        {
            var current = await con.ExecuteScalarAsync<int?>("SELECT ConsultingDoctorId FROM PatientOPDService WHERE OPDServiceId = @id", new { id = keepOpdServiceId });
            if (current == doctorId) return null;   // the visit already has this doctor: not a new booking with them
        }
        return $"{d.Name} is suspended and cannot be chosen as {role}. Reason: {d.Reason}";
    }
}
