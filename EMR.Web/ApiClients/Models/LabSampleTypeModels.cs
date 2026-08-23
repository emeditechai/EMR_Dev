using System.ComponentModel.DataAnnotations;

namespace EMR.Web.ApiClients.Models;

public enum ContainerTypeEnum
{
    [Display(Name = "Red Top Vial")]
    RedTopVial = 1,

    [Display(Name = "Purple Top (EDTA)")]
    PurpleTopEdta = 2,

    [Display(Name = "Yellow Top (SST)")]
    YellowTopSst = 3,

    [Display(Name = "Blue Top (Sodium Citrate)")]
    BlueTopSodiumCitrate = 4,

    [Display(Name = "Green Top (Heparin)")]
    GreenTopHeparin = 5,

    [Display(Name = "Grey Top (Sodium Fluoride)")]
    GreyTopSodiumFluoride = 6,

    [Display(Name = "Sterile Container / Swab")]
    SterileContainer = 7
}

public class LabSampleTypeModel
{
    public int Sample_Type_ID { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string Sample_Name { get; set; } = string.Empty;
    public string Sample_Code { get; set; } = string.Empty;
    public string Container_Type { get; set; } = string.Empty;
    public decimal Volume_Value { get; set; }
    public int? Unit_ID { get; set; }
    public string Volume_Unit { get; set; } = string.Empty;
    public string? Unit_Name { get; set; }
    public string? Unit_Symbol { get; set; }
    public string Volume_Required { get; set; } = string.Empty;
    public string? Storage_Temperature { get; set; }
    public string? Rejection_Criteria { get; set; }
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabSampleTypeCreateRequestModel
{
    public string Sample_Name { get; set; } = string.Empty;
    public ContainerTypeEnum Container_Type { get; set; }
    public decimal Volume_Value { get; set; }
    public int? Unit_ID { get; set; }
    public string? Volume_Unit { get; set; }
    public string? Storage_Temperature { get; set; }
    public string? Rejection_Criteria { get; set; }
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int BranchId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabSampleTypeUpdateRequestModel
{
    public int Sample_Type_ID { get; set; }
    public string Sample_Name { get; set; } = string.Empty;
    public ContainerTypeEnum Container_Type { get; set; }
    public decimal Volume_Value { get; set; }
    public int? Unit_ID { get; set; }
    public string? Volume_Unit { get; set; }
    public string? Storage_Temperature { get; set; }
    public string? Rejection_Criteria { get; set; }
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabSampleTypeToggleStatusRequestModel
{
    public int Sample_Type_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
