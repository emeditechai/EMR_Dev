using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

public interface ITerminologyService
{
    Task<TermReleasesResult> ReleasesAsync();
    Task<(int JobId, int ReleaseId)> CreateImportAsync(string versionCode, DateTime? releaseDate, string fileName, string hash, long size, string storedFile, string? notes, int? userId);
    Task<TermImportJob?> ImportAsync(int jobId);
    Task<TermPaged<TermImportError>> ImportErrorsAsync(int jobId, int page, int pageSize);
    Task<TermImportJob?> PublishAsync(int releaseId, int? userId);
    Task DiscardAsync(int releaseId, int? userId);
    Task<TermPaged<LoincConceptRow>> SearchAsync(string? q, string? className, bool labOnly, bool includeRetired, string? status, string? orderObs, int page, int pageSize);
    Task<LoincConceptDetail?> ConceptAsync(string code);
    Task<List<LoincClassRow>> ClassesAsync();
    Task<HashSet<string>> ExistingCodesAsync(IEnumerable<string> codes);
    Task<(bool Added, string Message)> SaveLookupAsync(LoincConceptRow c, int? userId);
    Task<TermChangesResult> ChangesAsync(int releaseId, string? changeType, string? search, int page, int pageSize);
    Task<TermInvestigationsResult> InvestigationsAsync(int? companyId, string? search, string? state, int? departmentId, int page, int pageSize);
    Task<TermInvestigationDetail> InvestigationDetailAsync(int investigationId);
    Task<long> ProposeAsync(int investigationId, TermProposeRequest req);
    Task DecideAsync(long mappingId, TermDecideRequest req);
}

/// <summary>
/// Standard Laboratory Test Master (LOINC), SQLScripts/2316: releases, imports, search, release changes and the
/// local investigation mappings - all in schema Terminology; the local Investigation Master is only read.
/// </summary>
public class TerminologyService(IDbConnectionFactory db) : ITerminologyService
{
    private const CommandType Sp = CommandType.StoredProcedure;

    /// <summary>SQL THROW 51xxx = a business rule refused the action: its text is shown to the user.</summary>
    public static string? RuleMessage(Exception ex) =>
        ex is SqlException se && se.Number is >= 51000 and < 52000 ? se.Message : null;

    public async Task<TermReleasesResult> ReleasesAsync()
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("Terminology.usp_Release_List", commandType: Sp);
        return new TermReleasesResult
        {
            Releases = (await m.ReadAsync<TermReleaseRow>()).ToList(),
            Stats = await m.ReadSingleOrDefaultAsync<TermRepositoryStats>() ?? new TermRepositoryStats()
        };
    }

    public async Task<(int JobId, int ReleaseId)> CreateImportAsync(string versionCode, DateTime? releaseDate, string fileName, string hash, long size, string storedFile, string? notes, int? userId)
    {
        using var con = db.CreateConnection();
        var r = await con.QuerySingleAsync<(int ImportJobId, int ReleaseId)>("Terminology.usp_Import_Create", new
        {
            VersionCode = versionCode, ReleaseDate = releaseDate, SourceFileName = fileName, SourceFileHash = hash,
            FileSizeBytes = size, StoredFile = storedFile, Notes = notes, UserId = userId
        }, commandType: Sp);
        return (r.ImportJobId, r.ReleaseId);
    }

    public async Task<TermImportJob?> ImportAsync(int jobId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<TermImportJob>("Terminology.usp_Import_Get", new { ImportJobId = jobId }, commandType: Sp);
    }

    public async Task<TermPaged<TermImportError>> ImportErrorsAsync(int jobId, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("Terminology.usp_Import_Errors", new { ImportJobId = jobId, PageNumber = page, PageSize = pageSize }, commandType: Sp);
        return new TermPaged<TermImportError> { TotalCount = await m.ReadSingleAsync<int>(), Items = (await m.ReadAsync<TermImportError>()).ToList(), Page = page, PageSize = pageSize };
    }

    public async Task<TermImportJob?> PublishAsync(int releaseId, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<TermImportJob>("Terminology.usp_Release_Publish", new { ReleaseId = releaseId, UserId = userId }, commandType: Sp, commandTimeout: 900);
    }

    public async Task DiscardAsync(int releaseId, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("Terminology.usp_Release_Discard", new { ReleaseId = releaseId, UserId = userId }, commandType: Sp, commandTimeout: 600);
    }

    public async Task<TermPaged<LoincConceptRow>> SearchAsync(string? q, string? className, bool labOnly, bool includeRetired, string? status, string? orderObs, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("Terminology.usp_Loinc_Search", new
        {
            Query = q, ClassName = className, LabOnly = labOnly, IncludeRetired = includeRetired, Status = status, OrderObs = orderObs,
            PageNumber = page, PageSize = pageSize
        }, commandType: Sp, commandTimeout: 60);
        return new TermPaged<LoincConceptRow> { TotalCount = await m.ReadSingleAsync<int>(), Items = (await m.ReadAsync<LoincConceptRow>()).ToList(), Page = page, PageSize = pageSize };
    }

    public async Task<LoincConceptDetail?> ConceptAsync(string code)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("Terminology.usp_Loinc_Get", new { LoincCode = code }, commandType: Sp);
        var c = await m.ReadSingleOrDefaultAsync<LoincConceptRow>();
        if (c is null) return null;
        return new LoincConceptDetail
        {
            Concept = c,
            Mappings = (await m.ReadAsync<LoincConceptMappingRef>()).ToList(),
            History = (await m.ReadAsync<LoincConceptHistory>()).ToList()
        };
    }

    public async Task<List<LoincClassRow>> ClassesAsync()
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<LoincClassRow>("Terminology.usp_Loinc_Classes", commandType: Sp)).ToList();
    }

    public async Task<HashSet<string>> ExistingCodesAsync(IEnumerable<string> codes)
    {
        var list = codes.Where(c => !string.IsNullOrWhiteSpace(c)).Distinct().ToList();
        if (list.Count == 0) return [];
        using var con = db.CreateConnection();
        return (await con.QueryAsync<string>("SELECT LoincCode FROM Terminology.LoincConcept WHERE LoincCode IN @list", new { list })).ToHashSet();
    }

    public async Task<(bool Added, string Message)> SaveLookupAsync(LoincConceptRow c, int? userId)
    {
        using var con = db.CreateConnection();
        var r = await con.QuerySingleAsync<(bool Added, string Message)>("Terminology.usp_Loinc_SaveLookup", new
        {
            c.LoincCode, c.LongCommonName, c.ShortName, c.Component, c.Property, c.TimeAspect, c.SystemName, c.ScaleType, c.MethodName,
            c.ClassName, c.ClassType, c.Status, c.OrderObs, c.ExampleUcumUnits, c.VersionLastChanged, UserId = userId
        }, commandType: Sp);
        return r;
    }

    public async Task<TermChangesResult> ChangesAsync(int releaseId, string? changeType, string? search, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("Terminology.usp_Release_Changes", new
        {
            ReleaseId = releaseId, ChangeType = changeType, Search = search, PageNumber = page, PageSize = pageSize
        }, commandType: Sp, commandTimeout: 60);
        var counts = (await m.ReadAsync<(string ChangeType, int Cnt)>()).ToDictionary(x => x.ChangeType, x => x.Cnt);
        var total = await m.ReadSingleAsync<int>();
        return new TermChangesResult { Counts = counts, Page = new TermPaged<TermChangeRow> { TotalCount = total, Items = (await m.ReadAsync<TermChangeRow>()).ToList(), Page = page, PageSize = pageSize } };
    }

    public async Task<TermInvestigationsResult> InvestigationsAsync(int? companyId, string? search, string? state, int? departmentId, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("Terminology.usp_Mapping_Investigations", new
        {
            CompanyId = companyId, Search = search, State = state, DepartmentId = departmentId, PageNumber = page, PageSize = pageSize
        }, commandType: Sp);
        var kpis = await m.ReadSingleAsync<TermInvestigationKpis>();
        var total = await m.ReadSingleAsync<int>();
        var items = (await m.ReadAsync<TermInvestigationRow>()).ToList();
        return new TermInvestigationsResult
        {
            Kpis = kpis,
            Page = new TermPaged<TermInvestigationRow> { TotalCount = total, Items = items, Page = page, PageSize = pageSize },
            Departments = (await m.ReadAsync<TermDeptOption>()).ToList()
        };
    }

    public async Task<TermInvestigationDetail> InvestigationDetailAsync(int investigationId)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("Terminology.usp_Mapping_ForInvestigation", new { InvestigationId = investigationId }, commandType: Sp, commandTimeout: 60);
        return new TermInvestigationDetail
        {
            Investigation = await m.ReadSingleOrDefaultAsync<TermInvestigationRow>(),
            Mappings = (await m.ReadAsync<TermMappingRow>()).ToList(),
            Audit = (await m.ReadAsync<TermMappingAuditRow>()).ToList(),
            Suggestions = (await m.ReadAsync<TermSuggestionRow>()).ToList()
        };
    }

    public async Task<long> ProposeAsync(int investigationId, TermProposeRequest req)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<long>("Terminology.usp_Mapping_Propose", new
        {
            InvestigationId = investigationId, LoincCode = req.LoincCode.Trim(), Method = req.Method ?? "Manual", Notes = req.Notes,
            UserId = req.UserId, CompanyId = req.CompanyId
        }, commandType: Sp);
    }

    public async Task DecideAsync(long mappingId, TermDecideRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("Terminology.usp_Mapping_Decide", new { MappingId = mappingId, Decision = req.Decision, Note = req.Note, UserId = req.UserId }, commandType: Sp);
    }
}
