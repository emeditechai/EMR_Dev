using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class PatientService(IDbConnectionFactory db) : IPatientService
{
    // ─── GET BY BRANCH (paged) ────────────────────────────────────────────────

    public async Task<PagedResult<PatientListItem>> GetByBranchAsync(
        int? branchId, int page, int pageSize, string? search = null)
    {
        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<PatientListItemWithTotal>(
            "usp_Api_Patient_GetByBranch",
            new { BranchId = branchId, PageNumber = page, PageSize = pageSize, Search = search },
            commandType: CommandType.StoredProcedure)).ToList();

        return new PagedResult<PatientListItem>
        {
            Items      = rows.Cast<PatientListItem>().ToList(),
            TotalCount = rows.FirstOrDefault()?.TotalCount ?? 0,
            Page       = page,
            PageSize   = pageSize
        };
    }

    // ─── GET BY ID ────────────────────────────────────────────────────────────

    public async Task<PatientDetail?> GetByIdAsync(int patientId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<PatientDetail>(
            "usp_Api_Patient_GetById",
            new { PatientId = patientId },
            commandType: CommandType.StoredProcedure);
    }

    // ─── CREATE ───────────────────────────────────────────────────────────────

    public async Task<int> CreateAsync(PatientCreateRequest req)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<int>(
            "usp_Api_Patient_Create",
            new
            {
                req.PhoneNumber,
                req.SecondaryPhoneNumber,
                req.Salutation,
                req.FirstName,
                req.MiddleName,
                req.LastName,
                req.Gender,
                req.DateOfBirth,
                req.EmailId,
                req.GuardianName,
                req.Address,
                req.RelationId,
                req.BloodGroup,
                req.KnownAllergies,
                req.Remarks,
                req.BranchId,
                UserId = req.RequestedByUserId
            },
            commandType: CommandType.StoredProcedure);
    }

    // ─── UPDATE ───────────────────────────────────────────────────────────────

    public async Task<bool> UpdateAsync(PatientUpdateRequest req)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync(
            "usp_Api_Patient_Update",
            new
            {
                req.PatientId,
                req.PhoneNumber,
                req.SecondaryPhoneNumber,
                req.Salutation,
                req.FirstName,
                req.MiddleName,
                req.LastName,
                req.Gender,
                req.DateOfBirth,
                req.EmailId,
                req.GuardianName,
                req.Address,
                req.RelationId,
                req.BloodGroup,
                req.KnownAllergies,
                req.Remarks,
                UserId = req.RequestedByUserId
            },
            commandType: CommandType.StoredProcedure);
        return rows > 0;
    }

    // ─── Private helper with TotalCount ──────────────────────────────────────
    private class PatientListItemWithTotal : PatientListItem
    {
        public int TotalCount { get; set; }
    }
}
