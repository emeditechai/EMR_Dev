using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace EMR.Web.Migrations
{
    /// <inheritdoc />
    public partial class AddHospitalSettings : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "HospitalSettings",
                columns: table => new
                {
                    Id = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    BranchID = table.Column<int>(type: "int", nullable: false),
                    HotelName = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: true),
                    Address = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: true),
                    ContactNumber1 = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: true),
                    ContactNumber2 = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: true),
                    EmailAddress = table.Column<string>(type: "nvarchar(150)", maxLength: 150, nullable: true),
                    Website = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: true),
                    GSTCode = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: true),
                    LogoPath = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: true),
                    CheckInTime = table.Column<TimeSpan>(type: "time", nullable: true),
                    CheckOutTime = table.Column<TimeSpan>(type: "time", nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    LastModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true),
                    LastModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ByPassActualDayRate = table.Column<bool>(type: "bit", nullable: false),
                    DiscountApprovalRequired = table.Column<bool>(type: "bit", nullable: false),
                    MinimumBookingAmountRequired = table.Column<bool>(type: "bit", nullable: false),
                    MinimumBookingAmount = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    NoShowGraceHours = table.Column<int>(type: "int", nullable: false),
                    CancellationRefundApprovalThreshold = table.Column<decimal>(type: "decimal(18,2)", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_HospitalSettings", x => x.Id);
                    table.ForeignKey(
                        name: "FK_HospitalSettings_Branchmaster_BranchID",
                        column: x => x.BranchID,
                        principalTable: "Branchmaster",
                        principalColumn: "BranchID",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateIndex(
                name: "IX_HospitalSettings_BranchID",
                table: "HospitalSettings",
                column: "BranchID");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "HospitalSettings");
        }
    }
}
