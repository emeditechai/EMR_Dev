namespace EMR.Api.Models;

public class LabFranchiseModel
{
    public int Franchise_ID { get; set; }
    public int CompanyId { get; set; }
    public string Franchise_Code { get; set; } = string.Empty;
    public string Franchise_Name { get; set; } = string.Empty;
    public string Mobile_No { get; set; } = string.Empty;
    public string? Email { get; set; }
    public int Franchise_Type { get; set; }
    public string Franchise_Type_Name { get; set; } = string.Empty;
    public int Parent_Branch_ID { get; set; }
    public string? Parent_Branch_Name { get; set; }
    public DateTime? Onboarding_Date { get; set; }
    public DateTime? Go_Live_Date { get; set; }
    public string? Agreement_Doc_Path { get; set; }
    public DateTime? Agreement_Valid_From { get; set; }
    public DateTime? Agreement_Valid_To { get; set; }
    public bool Status { get; set; } // Is Suspended bit: false = No/Active, true = Suspended
    public string? Suspension_Reason { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Credit Limit Details
    public int Credit_ID { get; set; }
    public int Credit_Facility_Type { get; set; }
    public string Credit_Facility_Type_Name { get; set; } = string.Empty;
    public decimal Credit_Limit { get; set; }
    public int? Credit_Days { get; set; }
    public int Grace_Days { get; set; }
    public decimal? Security_Deposit_Amount { get; set; }
    public DateTime? Security_Deposit_Received_On { get; set; }
    public decimal? Interest_On_Overdue_Percent { get; set; }
    public decimal Temporary_Limit_Increase { get; set; }
    public DateTime? Temp_Limit_Valid_Till { get; set; }
}

public class LabFranchiseCreateRequestModel
{
    public int CompanyId { get; set; } = 1;
    public string Franchise_Name { get; set; } = string.Empty;
    public string Mobile_No { get; set; } = string.Empty;
    public string? Email { get; set; }
    public int Franchise_Type { get; set; }
    public int Parent_Branch_ID { get; set; }
    public DateTime? Onboarding_Date { get; set; }
    public DateTime? Go_Live_Date { get; set; }
    public string? Agreement_Doc_Path { get; set; }
    public DateTime? Agreement_Valid_From { get; set; }
    public DateTime? Agreement_Valid_To { get; set; }
    public bool Status { get; set; } = false;
    public bool IsActive { get; set; } = true;

    // Credit Limit Details
    public int Credit_Facility_Type { get; set; } = 1;
    public decimal Credit_Limit { get; set; } = 0;
    public int? Credit_Days { get; set; }
    public int Grace_Days { get; set; } = 0;
    public decimal? Security_Deposit_Amount { get; set; }
    public DateTime? Security_Deposit_Received_On { get; set; }
    public decimal? Interest_On_Overdue_Percent { get; set; }
    public decimal Temporary_Limit_Increase { get; set; } = 0;
    public DateTime? Temp_Limit_Valid_Till { get; set; }

    public int? UserId { get; set; }
}

public class LabFranchiseUpdateRequestModel
{
    public int Franchise_ID { get; set; }
    public string Franchise_Name { get; set; } = string.Empty;
    public string Mobile_No { get; set; } = string.Empty;
    public string? Email { get; set; }
    public int Franchise_Type { get; set; }
    public int Parent_Branch_ID { get; set; }
    public DateTime? Onboarding_Date { get; set; }
    public DateTime? Go_Live_Date { get; set; }
    public string? Agreement_Doc_Path { get; set; }
    public DateTime? Agreement_Valid_From { get; set; }
    public DateTime? Agreement_Valid_To { get; set; }
    public bool Status { get; set; }
    public bool IsActive { get; set; }

    // Credit Limit Details
    public int Credit_Facility_Type { get; set; }
    public decimal Credit_Limit { get; set; }
    public int? Credit_Days { get; set; }
    public int Grace_Days { get; set; }
    public decimal? Security_Deposit_Amount { get; set; }
    public DateTime? Security_Deposit_Received_On { get; set; }
    public decimal? Interest_On_Overdue_Percent { get; set; }
    public decimal Temporary_Limit_Increase { get; set; }
    public DateTime? Temp_Limit_Valid_Till { get; set; }

    public int? UserId { get; set; }
}

public class LabFranchiseToggleStatusRequestModel
{
    public int Franchise_ID { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class LabFranchiseToggleSuspensionRequestModel
{
    public int Franchise_ID { get; set; }
    public bool Status { get; set; } // true = Suspended, false = Active
    public string? Suspension_Reason { get; set; }
    public int? UserId { get; set; }
}
