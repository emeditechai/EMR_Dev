namespace EMR.Web.Models.Entities;

public class DiscountTypeMaster
{
    public int DiscountTypeId { get; set; }
    public string DiscountTypeName { get; set; } = null!;
    public char DiscountFlag { get; set; } = 'P';
    public decimal? PercentageFrom { get; set; }
    public decimal? PercentageTo { get; set; }
    public decimal? DiscountAmount { get; set; }
    public bool IsActive { get; set; }
    public int? BranchId { get; set; }
    public int? CompanyId { get; set; }
    public int CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
