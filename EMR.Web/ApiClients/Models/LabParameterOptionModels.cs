namespace EMR.Web.ApiClients.Models;

public class LabParameterOptionModel
{
    public int Option_ID { get; set; }
    public int CompanyId { get; set; }
    public string Option_Code { get; set; } = string.Empty;
    public int Test_ID { get; set; }
    public string? Test_Name { get; set; }
    public string Option_Text { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Is_Abnormal { get; set; } = false;
    public bool Is_Default { get; set; } = false;
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabParameterOptionCreateRequestModel
{
    public int Test_ID { get; set; }
    public string Option_Text { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Is_Abnormal { get; set; } = false;
    public bool Is_Default { get; set; } = false;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabParameterOptionUpdateRequestModel
{
    public int Option_ID { get; set; }
    public int Test_ID { get; set; }
    public string Option_Text { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Is_Abnormal { get; set; } = false;
    public bool Is_Default { get; set; } = false;
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabParameterOptionToggleStatusRequestModel
{
    public int Option_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabParameterOptionLookupModel
{
    public int Id { get; set; }
    public string Text { get; set; } = string.Empty;
}
