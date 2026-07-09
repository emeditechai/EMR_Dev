using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class DoctorService(IDbConnectionFactory db) : IDoctorService
{
    // ─── GET LIST ─────────────────────────────────────────────────────────────

    public async Task<PagedResult<DoctorListItem>> GetListAsync(int? branchId, string? searchQuery = null, int pageNumber = 1, int pageSize = 10)
    {
        using var con = db.CreateConnection();
        var items = await con.QueryAsync<DoctorListItem>(
            "usp_Api_Doctor_GetList",
            new { BranchId = branchId, SearchQuery = searchQuery, PageNumber = pageNumber, PageSize = pageSize },
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

    public async Task<DoctorDetail?> GetByIdAsync(int doctorId, int? branchId = null)
    {
        using var con = db.CreateConnection();

        using var multi = await con.QueryMultipleAsync(
            "usp_Api_Doctor_GetById",
            new { DoctorId = doctorId, BranchId = branchId },
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
        DoctorListItem? linkedDoctor = null;

        // 1. Try by LinkedUserId
        linkedDoctor = await con.QueryFirstOrDefaultAsync<DoctorListItem>(
            "SELECT DoctorId, ISNULL(NamePrefix + ' ', '') + FullName AS FullName, PrimarySpecialityId, Gender FROM DoctorMaster WHERE LinkedUserId = @userId AND IsActive = 1",
            new { userId });

        // 2. Try by Email
        if (linkedDoctor == null && !string.IsNullOrEmpty(email))
        {
            linkedDoctor = await con.QueryFirstOrDefaultAsync<DoctorListItem>(
                "SELECT DoctorId, ISNULL(NamePrefix + ' ', '') + FullName AS FullName, PrimarySpecialityId, Gender FROM DoctorMaster WHERE EmailId = @email AND IsActive = 1",
                new { email });

            if (linkedDoctor != null)
                await con.ExecuteAsync("UPDATE DoctorMaster SET LinkedUserId = @userId WHERE DoctorId = @doctorId", new { userId, doctorId = linkedDoctor.DoctorId });
        }

        // 3. Try by DisplayName
        if (linkedDoctor == null && !string.IsNullOrEmpty(displayName))
        {
            linkedDoctor = await con.QueryFirstOrDefaultAsync<DoctorListItem>(
                "SELECT DoctorId, ISNULL(NamePrefix + ' ', '') + FullName AS FullName, PrimarySpecialityId, Gender FROM DoctorMaster WHERE FullName = @displayName AND IsActive = 1",
                new { displayName });

            if (linkedDoctor != null)
                await con.ExecuteAsync("UPDATE DoctorMaster SET LinkedUserId = @userId WHERE DoctorId = @doctorId", new { userId, doctorId = linkedDoctor.DoctorId });
        }

        return linkedDoctor;
    }
}
