namespace EMR.Api.Models;

public class DoctorIpListItem
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

public class DoctorIpHeader
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

public class DoctorIpDetailItem
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

public class DoctorIpDetail
{
    public DoctorIpHeader Header { get; set; } = new();
    public List<DoctorIpDetailItem> Details { get; set; } = [];
}

public class DoctorIpDetailInput
{
    public long Test_ID { get; set; }
    public string Item_Type { get; set; } = "Test";
    public decimal Commission_Rate { get; set; }
}

public class DoctorIpSaveRequest
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
    public List<DoctorIpDetailInput> Details { get; set; } = [];
}

public class DoctorIpToggleStatusRequest
{
    public int Doctor_IP_Hdr_ID { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class DoctorIpSpeciality
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public int ReferralDoctorCount { get; set; }
}

public class DoctorIpLookupItem
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}

public class DoctorIpItem
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

public class DoctorIpAccessStatus
{
    public bool IsConfigured { get; set; }
    public int UnlockMinutes { get; set; }
    public bool IsLockedOut { get; set; }
    public int LockedMinutesLeft { get; set; }
    public int AttemptsLeft { get; set; }
}

public class DoctorIpVerifyCodeRequest
{
    public int CompanyId { get; set; }
    public int UserId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string? IpAddress { get; set; }
}

public class DoctorIpVerifyCodeResult
{
    public string Result { get; set; } = string.Empty; // OK / INVALID / LOCKED / NOT_CONFIGURED
    public int UnlockMinutes { get; set; }
    public int AttemptsLeft { get; set; }
    public int LockedMinutesLeft { get; set; }
}

public class DoctorIpSetCodeRequest
{
    public int CompanyId { get; set; }
    public string NewCode { get; set; } = string.Empty;
    public string? CurrentCode { get; set; }
    public int? UserId { get; set; }
}
