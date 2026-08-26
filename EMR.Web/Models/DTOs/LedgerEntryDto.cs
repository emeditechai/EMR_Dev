using System;

namespace EMR.Web.Models.DTOs;

public class LedgerEntryDto
{
    public int VoucherTypeId { get; set; }
    public DateTime TransactionDate { get; set; }
    public string ReferenceType { get; set; } = string.Empty;
    public int ReferenceId { get; set; }
    public int? BranchId { get; set; }
    public int? CompanyId { get; set; }
    public decimal TotalAmount { get; set; }
    public string? Narration { get; set; }
    public int DebitLedgerId { get; set; }
    public int CreditLedgerId { get; set; }
    public int? CreatedBy { get; set; }
}
