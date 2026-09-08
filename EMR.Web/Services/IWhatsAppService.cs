using System.Threading.Tasks;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class WhatsAppSendResult
{
    public bool Success { get; set; }
    public string? MsgId { get; set; }
    public string? Jid { get; set; }
    public string? Status { get; set; }
    public string? ErrorMessage { get; set; }
    public string? RawResponse { get; set; }
}

public interface IWhatsAppService
{
    Task<WhatsAppConfiguration?> GetActiveConfigAsync(int branchId);
    Task<WhatsAppSendResult> SendTextMessageAsync(string to, string text, int branchId, string moduleCode = "TEST", int? moduleRefId = null, string? documentUrl = null, string? fileName = null);
    Task<string?> UploadMediaAsync(byte[] fileBytes, string mimeType, int branchId);
    Task TriggerOpdBillWhatsAppAsync(int branchId, int opdServiceId, string? pdfPath = null, string? hostUrl = null);
    Task TriggerLabBillWhatsAppAsync(int branchId, int labOrderId, string? pdfPath = null, string? hostUrl = null);
    Task TriggerVideoConsultationWhatsAppAsync(int branchId, int opdServiceId, string patientPhone, string doctorPhone, string patientName, string doctorName, string date, string time, string patientLink, string doctorLink);
}
