namespace EMR.Web.ApiClients.Models;

/// <summary>Misc Charges Master (SQLScripts/2239): extra items billed with investigations on a LAB bill.</summary>
public class LabMiscChargeModel
{
    public int Misc_Charge_ID { get; set; }
    public int CompanyId { get; set; }
    public string Charge_Name { get; set; } = string.Empty;
    public string Charge_Type { get; set; } = string.Empty;   // Home Collection / Misc
    public decimal Amount { get; set; }
    public bool Is_Discountable { get; set; }
    public bool Is_GST_Required { get; set; }
    public decimal? GST_Percentage { get; set; }
    public string? Description { get; set; }
    public int Display_Order { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public string? CreatedByName { get; set; }
    public string? ModifiedByName { get; set; }
}

public class LabMiscChargeSaveRequestModel
{
    public int Misc_Charge_ID { get; set; }
    public string Charge_Name { get; set; } = string.Empty;
    public string Charge_Type { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public bool Is_Discountable { get; set; }
    public bool Is_GST_Required { get; set; }
    public decimal? GST_Percentage { get; set; }
    public string? Description { get; set; }
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; } = true;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabMiscChargeToggleStatusRequestModel
{
    public int Misc_Charge_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
