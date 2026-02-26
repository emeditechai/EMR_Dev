using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class DoctorRoomFormViewModel
{
    public int RoomId { get; set; }

    [Required(ErrorMessage = "Room Name is required.")]
    [MaxLength(10, ErrorMessage = "Maximum 10 characters allowed.")]
    [Display(Name = "Room Name")]
    public string RoomName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Floor is required.")]
    [Display(Name = "Floor")]
    public int? FloorId { get; set; }

    public List<SelectListItem> FloorOptions { get; set; } = [];

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}
