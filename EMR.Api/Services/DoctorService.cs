using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class DoctorService(IDbConnectionFactory db) : IDoctorService
{
    // ─── GET LIST ─────────────────────────────────────────────────────────────

    public async Task<PagedResult<DoctorListItem>> GetListAsync(int? companyId, int? branchId, string? searchQuery = null, int pageNumber = 1, int pageSize = 10)
    {
        using var con = db.CreateConnection();
        var items = await con.QueryAsync<DoctorListItem>(
            "usp_Api_Doctor_GetList",
            new { CompanyId = companyId, BranchId = branchId, SearchQuery = searchQuery, PageNumber = pageNumber, PageSize = pageSize },
            commandType: CommandType.StoredProcedure);
            
        return new PagedResult<DoctorListItem>
        {
            Items = items.ToList(),
            TotalCount = items.FirstOrDefault()?.TotalCount ?? 0,
            Page = pageNumber,
            PageSize = pageSize
        };
    }

    // ─── GET BY ID ────────────────────────────────────────────────────────────

    public async Task<DoctorDetail?> GetByIdAsync(int doctorId, int? branchId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();

        using var multi = await con.QueryMultipleAsync(
            "usp_Api_Doctor_GetById",
            new { DoctorId = doctorId, BranchId = branchId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);

        var detail     = await multi.ReadFirstOrDefaultAsync<DoctorDetail>();
        if (detail is null) return null;

        detail.BranchIds     = (await multi.ReadAsync<int>()).ToList();
        detail.DepartmentIds = (await multi.ReadAsync<int>()).ToList();
        return detail;
    }

    // ─── CREATE ───────────────────────────────────────────────────────────────

    public async Task<int> CreateAsync(DoctorCreateRequest req)
    {
        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();
        try
        {
            var doctorId = await con.QuerySingleAsync<int>(
                "usp_Api_Doctor_Create",
                new
                {
                    CompanyId = req.CompanyId > 0 ? req.CompanyId : 1,
                    req.FullName,
                    req.Gender,
                    req.DateOfBirth,
                    req.EmailId,
                    req.PhoneNumber,
                    req.MedicalLicenseNo,
                    req.PrimarySpecialityId,
                    req.SecondarySpecialityId,
                    req.JoiningDate,
                    req.IsActive,
                    req.CreatedBranchId,
                    UserId = req.RequestedByUserId
                },
                tx,
                commandType: CommandType.StoredProcedure);


            // Insert branch/department maps
            foreach (var bid in req.BranchIds.Distinct())
                await con.ExecuteAsync(
                    "INSERT INTO DoctorBranchMap (DoctorId,BranchId,IsActive,CreatedBy,CreatedDate) VALUES (@DoctorId,@BranchId,1,@UserId,GETDATE())",
                    new { DoctorId = doctorId, BranchId = bid, UserId = req.RequestedByUserId }, tx);

            foreach (var did in req.DepartmentIds.Distinct())
                await con.ExecuteAsync(
                    "INSERT INTO DoctorDepartmentMap (DoctorId,DeptId,IsActive,CreatedBy,CreatedDate) VALUES (@DoctorId,@DeptId,1,@UserId,GETDATE())",
                    new { DoctorId = doctorId, DeptId = did, UserId = req.RequestedByUserId }, tx);

            tx.Commit();
            return doctorId;
        }
        catch { tx.Rollback(); throw; }
    }

    // ─── UPDATE ───────────────────────────────────────────────────────────────

    public async Task<bool> UpdateAsync(DoctorUpdateRequest req)
    {
        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();
        try
        {
            var rows = await con.ExecuteAsync(
                "usp_Api_Doctor_Update",
                new
                {
                    req.DoctorId,
                    req.FullName,
                    req.Gender,
                    req.DateOfBirth,
                    req.EmailId,
                    req.PhoneNumber,
                    req.MedicalLicenseNo,
                    req.PrimarySpecialityId,
                    req.SecondarySpecialityId,
                    req.JoiningDate,
                    req.IsActive,
                    UserId = req.RequestedByUserId
                },
                tx,
                commandType: CommandType.StoredProcedure);

            if (rows == 0) { tx.Rollback(); return false; }

            // Refresh maps
            await con.ExecuteAsync("DELETE FROM DoctorBranchMap     WHERE DoctorId = @DoctorId", new { req.DoctorId }, tx);
            await con.ExecuteAsync("DELETE FROM DoctorDepartmentMap  WHERE DoctorId = @DoctorId", new { req.DoctorId }, tx);

            foreach (var bid in req.BranchIds.Distinct())
                await con.ExecuteAsync(
                    "INSERT INTO DoctorBranchMap (DoctorId,BranchId,IsActive,CreatedBy,CreatedDate) VALUES (@DoctorId,@BranchId,1,@UserId,GETDATE())",
                    new { req.DoctorId, BranchId = bid, UserId = req.RequestedByUserId }, tx);

            foreach (var did in req.DepartmentIds.Distinct())
                await con.ExecuteAsync(
                    "INSERT INTO DoctorDepartmentMap (DoctorId,DeptId,IsActive,CreatedBy,CreatedDate) VALUES (@DoctorId,@DeptId,1,@UserId,GETDATE())",
                    new { req.DoctorId, DeptId = did, UserId = req.RequestedByUserId }, tx);

            tx.Commit();
            return true;
        }
        catch { tx.Rollback(); throw; }
    }

    // ─── GET LINKED DOCTOR ────────────────────────────────────────────────────

    public async Task<DoctorListItem?> GetLinkedDoctorAsync(int userId, string? email, string? displayName)
    {
        using var con = db.CreateConnection();
        const string select = "SELECT TOP 1 DoctorId, ISNULL(NamePrefix + ' ', '') + FullName AS FullName, PrimarySpecialityId, Gender FROM DoctorMaster WHERE IsActive = 1 AND ";

        // 1. a doctor login (Users.User_Type 'D') names its doctor (SQLScripts/2197)
        var linkedDoctor = await con.QueryFirstOrDefaultAsync<DoctorListItem>(select +
            "DoctorId = (SELECT ReferenceUserID FROM Users WHERE Id = @userId AND User_Type = 'D')", new { userId });

        // 2. the doctor's link to this user
        linkedDoctor ??= await con.QueryFirstOrDefaultAsync<DoctorListItem>(select + "LinkedUserId = @userId", new { userId });

        // 3. a general user matched once by e-mail, else display name, to a doctor that has no login yet -
        //    then recorded as that doctor's login (User_Type 'D') and linked. A doctor with a login is never re-linked.
        const string noLogin = " AND LinkedUserId IS NULL AND NOT EXISTS (SELECT 1 FROM Users x WHERE x.User_Type = 'D' AND x.ReferenceUserID = DoctorMaster.DoctorId)" +
                               " AND EXISTS (SELECT 1 FROM Users me WHERE me.Id = @userId AND me.User_Type = 'U')";
        var matched = false;
        if (linkedDoctor == null && !string.IsNullOrEmpty(email))
            matched = (linkedDoctor = await con.QueryFirstOrDefaultAsync<DoctorListItem>(select + "EmailId = @email" + noLogin, new { email, userId })) != null;
        if (linkedDoctor == null && !string.IsNullOrEmpty(displayName))
            matched = (linkedDoctor = await con.QueryFirstOrDefaultAsync<DoctorListItem>(select + "FullName = @displayName" + noLogin, new { displayName, userId })) != null;

        if (linkedDoctor != null && matched)
            await con.ExecuteAsync(@"
                UPDATE Users SET User_Type = 'D', ReferenceUserID = @doctorId WHERE Id = @userId AND User_Type = 'U'
                  AND NOT EXISTS (SELECT 1 FROM Users x WHERE x.User_Type = 'D' AND x.ReferenceUserID = @doctorId);
                UPDATE DoctorMaster SET LinkedUserId = @userId WHERE DoctorId = @doctorId AND LinkedUserId IS NULL;",
                new { userId, doctorId = linkedDoctor.DoctorId });

        return linkedDoctor;
    }
}
