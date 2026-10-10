namespace EMR.Web.ApiClients.Models;

public class DoctorIpListModel
{
    public int Doctor_IP_Hdr_ID { get; set; }
    public int Doctor_ID { get; set; }
    public string Doctor_Name { get; set; } = string.Empty;
    public int? Speciality_ID { get; set; }
    public string? Speciality_Name { get; set; }
    public int Branch_ID { get; set; }
    public string? Branch_Name { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool IsActive { get; set; }
    public string Frequency_Of_Disbursal { get; set; } = "Monthly";
    public int Item_Count { get; set; }
    public decimal? Avg_Rate { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? UpdatedDate { get; set; }
}

public class DoctorIpHeaderModel
{
    public int Doctor_IP_Hdr_ID { get; set; }
    public int CompanyId { get; set; }
    public int Doctor_ID { get; set; }
    public string Doctor_Name { get; set; } = string.Empty;
    public int? Speciality_ID { get; set; }
    public string? Speciality_Name { get; set; }
    public int Branch_ID { get; set; }
    public string? Branch_Name { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool IsActive { get; set; }
    public string Frequency_Of_Disbursal { get; set; } = "Monthly";
    public int? Created_By { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? Updated_By { get; set; }
    public DateTime? UpdatedDate { get; set; }
}

public class DoctorIpDetailItemModel
{
    public long Doctor_IP_Dtl_ID { get; set; }
    public int Doctor_IP_Hdr_ID { get; set; }
    public long Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
    public string Item_Type { get; set; } = string.Empty;
    public int? Department_ID { get; set; }
    public string? Department_Name { get; set; }
    public int? Category_ID { get; set; }
    public string? Category_Name { get; set; }
    public int? Sub_Category_ID { get; set; }
    public string? Sub_Category_Name { get; set; }
    public decimal MRP { get; set; }
    public decimal Commission_Rate { get; set; }
}

public class DoctorIpDetailModel
{
    public DoctorIpHeaderModel Header { get; set; } = new();
    public List<DoctorIpDetailItemModel> Details { get; set; } = [];
}

public class DoctorIpDetailInputModel
{
    public long Test_ID { get; set; }
    public string Item_Type { get; set; } = "Test";
    public decimal Commission_Rate { get; set; }
}

public class DoctorIpSaveRequestModel
{
    public int Doctor_IP_Hdr_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Doctor_ID { get; set; }
    public int? Speciality_ID { get; set; }
    public int Branch_ID { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool IsActive { get; set; } = true;
    public string Frequency_Of_Disbursal { get; set; } = "Monthly";
    public int? UserId { get; set; }
    public List<DoctorIpDetailInputModel> Details { get; set; } = [];
}

public class DoctorIpToggleStatusRequestModel
{
    public int Doctor_IP_Hdr_ID { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class DoctorIpSpecialityModel
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public int ReferralDoctorCount { get; set; }
}

public class DoctorIpLookupModel
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}

public class DoctorIpItemModel
{
    public long Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
    public string Item_Type { get; set; } = string.Empty;
    public int? Department_ID { get; set; }
    public string? Department_Name { get; set; }
    public int? Category_ID { get; set; }
    public string? Category_Name { get; set; }
    public int? Sub_Category_ID { get; set; }
    public string? Sub_Category_Name { get; set; }
    public decimal MRP { get; set; }
}

public class DoctorIpAccessStatusModel
{
    public bool IsConfigured { get; set; }
    public int UnlockMinutes { get; set; }
    public bool IsLockedOut { get; set; }
    public int LockedMinutesLeft { get; set; }
    public int AttemptsLeft { get; set; }
}

public class DoctorIpVerifyCodeRequestModel
{
    public int CompanyId { get; set; }
    public int UserId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string? IpAddress { get; set; }
}

public class DoctorIpVerifyCodeResultModel
{
    public string Result { get; set; } = string.Empty;
    public int UnlockMinutes { get; set; }
    public int AttemptsLeft { get; set; }
    public int LockedMinutesLeft { get; set; }
}

public class DoctorIpSetCodeRequestModel
{
    public int CompanyId { get; set; }
    public string NewCode { get; set; } = string.Empty;
    public string? CurrentCode { get; set; }
    public int? UserId { get; set; }
}
