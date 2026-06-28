namespace EMR.Web.Models.Entities;

public class EmailLog
{
    public int Id { get; set; }
    
    public int BranchId { get; set; }
    public BranchMaster Branch { get; set; } = null!;

    public int ConfigId { get; set; }
    public SmtpEmailConfiguration Config { get; set; } = null!;

    public required string RecipientEmail { get; set; }
    public string? Subject { get; set; }
    
    public DateTime SentDate { get; set; }
    
    public required string Status { get; set; }
    
    public string? ErrorMessage { get; set; }
}
