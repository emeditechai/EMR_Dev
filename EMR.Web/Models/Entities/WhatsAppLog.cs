using System;

namespace EMR.Web.Models.Entities;

public class WhatsAppLog
{
    public int Id { get; set; }
    public int? ConfigId { get; set; }
    public int BranchId { get; set; }
    public string ModuleCode { get; set; } = "TEST";
    public int? ModuleRefId { get; set; }
    public string RecipientPhone { get; set; } = string.Empty;
    public string MessageText { get; set; } = string.Empty;
    public bool IsSuccess { get; set; }
    public string? MsgId { get; set; }
    public string? Jid { get; set; }
    public string? Status { get; set; }
    public string? ApiResponse { get; set; }
    public string? ErrorMessage { get; set; }
    public DateTime SentDate { get; set; } = DateTime.Now;
}
