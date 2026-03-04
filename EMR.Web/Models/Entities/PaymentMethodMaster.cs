namespace EMR.Web.Models.Entities;

public class PaymentMethodMaster
{
    public int PaymentMethodId { get; set; }
    public string MethodName { get; set; } = string.Empty;
    public string MethodCode { get; set; } = string.Empty;  // CASH, CARD, UPI, CHEQUE, NEFT, WALLET
    public bool RequiresRef { get; set; }
    public bool RequiresChequeNo { get; set; }
    public bool RequiresBankName { get; set; }
    public bool RequiresUPIRef { get; set; }
    public bool RequiresCardLast4 { get; set; }
    public int DisplayOrder { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedDate { get; set; } = DateTime.Now;
}
