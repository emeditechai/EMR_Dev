using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class RelationMaster
{
    public int RelationId { get; set; }

    [Required, MaxLength(100)]
    public string RelationName { get; set; } = string.Empty;

    public int SortOrder { get; set; } = 0;

    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
