using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class IdentificationTypeMaster
{
    public int IdentificationTypeId { get; set; }

    [Required, MaxLength(100)]
    public string IdentificationTypeName { get; set; } = string.Empty;

    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
