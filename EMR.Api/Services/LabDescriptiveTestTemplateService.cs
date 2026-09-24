using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabDescriptiveTestTemplateService(IDbConnectionFactory db) : ILabDescriptiveTestTemplateService
{
    public async Task<IEnumerable<LabDescriptiveTestTemplateListItem>> GetListAsync(bool? status, string? search, int? testId, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabDescriptiveTestTemplateListItem>(
            "usp_Api_LabDescriptiveTestTemplate_GetList",
            new { Status = status, Search = search, TestId = testId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabDescriptiveTestTemplateListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabDescriptiveTestTemplateListItem>(
            "usp_Api_LabDescriptiveTestTemplate_GetById",
            new { Template_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabDescriptiveTestTemplateCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Section_Name", req.Section_Name);
        p.Add("@Section_Sequence", req.Section_Sequence);
        p.Add("@Is_Mandatory", req.Is_Mandatory);
        p.Add("@Default_Content_Html", req.Default_Content_Html);
        p.Add("@Placeholder_Tags", req.Placeholder_Tags);
        p.Add("@Modality", req.Modality);
        p.Add("@Body_Part", req.Body_Part);
        p.Add("@Laterality", req.Laterality);
        p.Add("@Contrast_Required", req.Contrast_Required);
        p.Add("@Contrast_Agent", req.Contrast_Agent);
        p.Add("@Views_Projections", req.Views_Projections);
        p.Add("@Preparation_Instructions", req.Preparation_Instructions);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabDescriptiveTestTemplate_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task<List<int>> BatchCreateAsync(LabDescriptiveTestTemplateBatchCreateRequest req)
    {
        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();

        var ids = new List<int>();
        foreach (var section in req.Sections)
        {
            var p = new DynamicParameters();
            p.Add("@Test_ID", req.Test_ID);
            p.Add("@Section_Name", section.Section_Name);
            p.Add("@Section_Sequence", section.Section_Sequence);
            p.Add("@Is_Mandatory", section.Is_Mandatory);
            p.Add("@Default_Content_Html", section.Default_Content_Html);
            p.Add("@Placeholder_Tags", section.Placeholder_Tags);
            p.Add("@Modality", req.Modality);
            p.Add("@Body_Part", req.Body_Part);
            p.Add("@Laterality", req.Laterality);
            p.Add("@Contrast_Required", req.Contrast_Required);
            p.Add("@Contrast_Agent", req.Contrast_Agent);
            p.Add("@Views_Projections", req.Views_Projections);
            p.Add("@Preparation_Instructions", req.Preparation_Instructions);
            p.Add("@CompanyId", req.CompanyId);
            p.Add("@UserId", req.UserId);
            p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

            await con.ExecuteAsync("usp_Api_LabDescriptiveTestTemplate_Create", p, transaction: tx, commandType: CommandType.StoredProcedure);
            ids.Add(p.Get<int>("@NewId"));
        }

        tx.Commit();
        return ids;
    }

    public async Task UpdateAsync(LabDescriptiveTestTemplateUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabDescriptiveTestTemplate_Update",
            new
            {
                Template_ID = req.Template_ID,
                Test_ID = req.Test_ID,
                Section_Name = req.Section_Name,
                Section_Sequence = req.Section_Sequence,
                Is_Mandatory = req.Is_Mandatory,
                Default_Content_Html = req.Default_Content_Html,
                Placeholder_Tags = req.Placeholder_Tags,
                Modality = req.Modality,
                Body_Part = req.Body_Part,
                Laterality = req.Laterality,
                Contrast_Required = req.Contrast_Required,
                Contrast_Agent = req.Contrast_Agent,
                Views_Projections = req.Views_Projections,
                Preparation_Instructions = req.Preparation_Instructions,
                IsActive = req.IsActive,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabDescriptiveTestTemplateToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabDescriptiveTestTemplate_ToggleStatus",
            new
            {
                Template_ID = req.Template_ID,
                IsActive = req.IsActive,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabDescriptiveTestTemplate_Delete",
            new { Template_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<LabDescriptiveTestTemplateListItem>> GetByTestIdAsync(int testId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabDescriptiveTestTemplateListItem>(
            "usp_Api_LabDescriptiveTestTemplate_GetList",
            new { Status = (bool?)null, Search = (string?)null, TestId = testId, CompanyId = (int?)null },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task BatchUpdateAsync(LabDescriptiveTestTemplateBatchUpdateRequest req)
    {
        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();

        foreach (var section in req.Sections)
        {
            await con.ExecuteAsync(
                "usp_Api_LabDescriptiveTestTemplate_Update",
                new
                {
                    Template_ID = section.Template_ID,
                    Test_ID = req.Test_ID,
                    Section_Name = section.Section_Name,
                    Section_Sequence = section.Section_Sequence,
                    Is_Mandatory = section.Is_Mandatory,
                    Default_Content_Html = section.Default_Content_Html,
                    Placeholder_Tags = section.Placeholder_Tags,
                    Modality = req.Modality,
                    Body_Part = req.Body_Part,
                    Laterality = req.Laterality,
                    Contrast_Required = req.Contrast_Required,
                    Contrast_Agent = req.Contrast_Agent,
                    Views_Projections = req.Views_Projections,
                    Preparation_Instructions = req.Preparation_Instructions,
                    IsActive = section.IsActive,
                    UserId = req.UserId
                },
                transaction: tx,
                commandType: CommandType.StoredProcedure
            );
        }

        tx.Commit();
    }

    public async Task<IEnumerable<LabDescriptiveTestTemplateGroupedItem>> GetGroupedListAsync(bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        var allItems = await con.QueryAsync<LabDescriptiveTestTemplateListItem>(
            "usp_Api_LabDescriptiveTestTemplate_GetList",
            new { Status = status, Search = search, TestId = (int?)null, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );

        return allItems.GroupBy(x => x.Test_ID).Select(g =>
        {
            var first = g.First();
            return new LabDescriptiveTestTemplateGroupedItem
            {
                Test_ID = first.Test_ID,
                Test_Name = first.Test_Name,
                Test_Code = first.Test_Code,
                Modality = first.Modality,
                Body_Part = first.Body_Part,
                SectionCount = g.Count(),
                IsActive = g.All(s => s.IsActive)
            };
        });
    }

    public async Task<IEnumerable<RadiologyTestItem>> GetRadiologyTestsAsync(int? companyId, string? search)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<RadiologyTestItem>(
            "usp_Api_LabDescriptiveTestTemplate_GetRadiologyTests",
            new { CompanyId = companyId, Search = search },
            commandType: CommandType.StoredProcedure
        );
    }
}
