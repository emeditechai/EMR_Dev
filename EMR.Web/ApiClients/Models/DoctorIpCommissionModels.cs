namespace EMR.Web.ApiClients.Models;

public class DoctorIpCommissionPendingModel
{
    public int Doctor_ID { get; set; }
    public string Doctor_Name { get; set; } = string.Empty;
    public string? Frequency_Of_Disbursal { get; set; }
    public int Pending_Orders { get; set; }
    public int Pending_Items { get; set; }
    public decimal Pending_Amount { get; set; }
    public decimal Estimated_Commission { get; set; }
    public DateTime First_Order_Date { get; set; }
    public DateTime Last_Order_Date { get; set; }
}

public class DoctorIpCommissionCalculateRequestModel
{
    public int BranchId { get; set; }
    public int? DoctorId { get; set; }
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public int? CompanyId { get; set; }
    public int? UserId { get; set; }
    public string Source { get; set; } = "MANUAL";
}

public class DoctorIpCommissionCalculateResultModel
{
    public int Doctor_ID { get; set; }
    public string Doctor_Name { get; set; } = string.Empty;
    public int Orders_Computed { get; set; }
    public int Items_Computed { get; set; }
    public decimal Total_Commission { get; set; }
}

public class DoctorIpCommissionListModel
{
    public long Commission_Hdr_ID { get; set; }
    public int Doctor_ID { get; set; }
    public string Doctor_Name { get; set; } = string.Empty;
    public int Branch_ID { get; set; }
    public string? Branch_Name { get; set; }
    public int Doctor_IP_Hdr_ID { get; set; }
    public string? Frequency_Of_Disbursal { get; set; }
    public DateTime Period_From { get; set; }
    public DateTime Period_To { get; set; }
    public int Total_Orders { get; set; }
    public int Total_Items { get; set; }
    public decimal Total_Billed_Amount { get; set; }
    public decimal Total_Commission { get; set; }
    public DateTime Computed_Date { get; set; }
    public string Source { get; set; } = string.Empty;
    public string Computed_By_Name { get; set; } = string.Empty;
}

public class DoctorIpCommissionHeaderModel
{
    public long Commission_Hdr_ID { get; set; }
    public int Doctor_ID { get; set; }
    public string Doctor_Name { get; set; } = string.Empty;
    public int Branch_ID { get; set; }
    public string? Branch_Name { get; set; }
    public int Doctor_IP_Hdr_ID { get; set; }
    public string? Frequency_Of_Disbursal { get; set; }
    public DateTime Period_From { get; set; }
    public DateTime Period_To { get; set; }
    public int Total_Orders { get; set; }
    public int Total_Items { get; set; }
    public decimal Total_Billed_Amount { get; set; }
    public decimal Total_Commission { get; set; }
    public DateTime Computed_Date { get; set; }
    public string Source { get; set; } = string.Empty;
    public string Computed_By_Name { get; set; } = string.Empty;
}

public class DoctorIpCommissionDetailItemModel
{
    public long Commission_Dtl_ID { get; set; }
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? Patient_Name { get; set; }
    public string Item_Type { get; set; } = "Test";
    public long Test_ID { get; set; }
    public string? Test_Code { get; set; }
    public string Test_Name { get; set; } = string.Empty;
    public decimal Billed_Amount { get; set; }
    public decimal Commission_Rate { get; set; }
    public decimal Commission_Amount { get; set; }
    public DateTime Order_Date { get; set; }
}

public class DoctorIpCommissionDetailModel
{
    public DoctorIpCommissionHeaderModel Header { get; set; } = new();
    public List<DoctorIpCommissionDetailItemModel> Details { get; set; } = [];
}
