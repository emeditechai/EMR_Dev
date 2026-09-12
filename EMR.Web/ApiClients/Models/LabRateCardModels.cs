namespace EMR.Web.ApiClients.Models;

public class LabRateCardHeaderModel
{
    public int RateCard_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string Branch_Name { get; set; } = string.Empty;
    public int? B2CIdentity_ID { get; set; }
    public string? Entity_Name { get; set; }
    public string Rate_Type { get; set; } = string.Empty;
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool Status { get; set; }
    public int ItemCount { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabRateCardDetailModel
{
    public int Detail_ID { get; set; }
    public int RateCard_ID { get; set; }
    public string Item_Type { get; set; } = string.Empty;
    public int Item_ID { get; set; }
    public string Item_Name { get; set; } = string.Empty;
    public string Item_Code { get; set; } = string.Empty;
    public decimal Default_Rate { get; set; }
    public int? Department_ID { get; set; }
    public int? Category_ID { get; set; }
    public int? SubCategory_ID { get; set; }
    public bool Is_Profile_Test { get; set; }
    public decimal Rate { get; set; }
    public bool Is_Discount_Allowed { get; set; } = true;
    public bool Status { get; set; }
}

public class LabRateCardFullModel
{
    public LabRateCardHeaderModel Header { get; set; } = new();
    public List<LabRateCardDetailModel> Details { get; set; } = [];
}

public class LabRateCardSaveRequestModel
{
    public int? RateCard_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public int? B2CIdentity_ID { get; set; }
    public string Rate_Type { get; set; } = string.Empty;
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
    public List<LabRateCardDetailModel> Details { get; set; } = [];
}

public class LabRateCardToggleStatusRequestModel
{
    public int RateCard_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabItemModel
{
    public string Item_Type { get; set; } = string.Empty;
    public int Item_ID { get; set; }
    public string Item_Code { get; set; } = string.Empty;
    public string Item_Name { get; set; } = string.Empty;
    public int? Department_ID { get; set; }
    public int? Category_ID { get; set; }
    public int? SubCategory_ID { get; set; }
    public decimal Default_Rate { get; set; }
    public bool Is_Profile_Test { get; set; }
}
