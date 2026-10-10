namespace EMR.Web.Models.ViewModels;

/// <summary>
/// Supplier details printed on the B2B tax invoice. Taken from Hospital Settings of the invoice branch (display
/// name, logo, contacts - same source as the other print pages), Company Master (legal name, GSTIN, PAN) and the
/// branch address; bank details from the primary active account in BankMaster, if one is set up.
/// </summary>
public class B2BInvoiceLetterheadViewModel
{
    public string DisplayName { get; set; } = string.Empty;
    public string? LegalName { get; set; }
    public string? Tagline { get; set; }
    public string? LogoPath { get; set; }
    public string? Address { get; set; }
    public string? Phone { get; set; }
    public string? Email { get; set; }
    public string? Website { get; set; }
    public string? RegistrationNumber { get; set; }
    public string? GSTIN { get; set; }
    public string? PAN { get; set; }
    public string? State { get; set; }
    /// <summary>First two digits of the GSTIN (GST state code), when a GSTIN is set.</summary>
    public string? StateCode { get; set; }

    public string? BankName { get; set; }
    public string? BankAccountNumber { get; set; }
    public string? BankBranch { get; set; }
    public string? BankIfsc { get; set; }
    public string? UpiId { get; set; }

    public bool HasBank => !string.IsNullOrWhiteSpace(BankAccountNumber) || !string.IsNullOrWhiteSpace(UpiId);
    public string PayeeName => !string.IsNullOrWhiteSpace(LegalName) ? LegalName! : DisplayName;
}
