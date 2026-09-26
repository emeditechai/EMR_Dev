using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabBulkUploadApiClient
{
    Task<(byte[] Content, string FileName)> DownloadTemplateAsync(string module, bool withData, int companyId, int? branchId, bool isHO);
    Task<LabBulkUploadResultModel> ImportAsync(string module, Stream file, string fileName, bool dryRun, int companyId, int? userId, int? branchId, bool isHO);
}
