using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace EMR.Web.Migrations
{
    /// <inheritdoc />
    public partial class AddVideoWhatsAppTemplates : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "VideoNotificationEnabled",
                table: "WhatsAppConfiguration",
                type: "bit",
                nullable: false,
                defaultValue: true);

            migrationBuilder.AddColumn<string>(
                name: "VideoPatientMessageTemplate",
                table: "WhatsAppConfiguration",
                type: "nvarchar(max)",
                nullable: false,
                defaultValue: "Dear {PatientName}, your Video Consultation with Dr. {DoctorName} on {Date} at {Time} is confirmed. Join using: {Link}");

            migrationBuilder.AddColumn<string>(
                name: "VideoDoctorMessageTemplate",
                table: "WhatsAppConfiguration",
                type: "nvarchar(max)",
                nullable: false,
                defaultValue: "Dear Dr. {DoctorName}, you have a Video Consultation scheduled with {PatientName} on {Date} at {Time}. Start using: {Link}");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "VideoNotificationEnabled",
                table: "WhatsAppConfiguration");
            
            migrationBuilder.DropColumn(
                name: "VideoPatientMessageTemplate",
                table: "WhatsAppConfiguration");

            migrationBuilder.DropColumn(
                name: "VideoDoctorMessageTemplate",
                table: "WhatsAppConfiguration");
        }
    }
}
