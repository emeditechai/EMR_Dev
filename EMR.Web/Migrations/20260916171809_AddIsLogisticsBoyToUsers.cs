using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace EMR.Web.Migrations
{
    /// <inheritdoc />
    public partial class AddIsLogisticsBoyToUsers : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "IsLogisticsBoy",
                table: "Users",
                type: "bit",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<bool>(
                name: "IsVehicleAvailable",
                table: "Users",
                type: "bit",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<string>(
                name: "VehicleRegNo",
                table: "Users",
                type: "nvarchar(50)",
                maxLength: 50,
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "LanguageId",
                table: "PatientMaster",
                type: "int",
                nullable: true);

            migrationBuilder.AlterColumn<string>(
                name: "Age",
                schema: "dbo",
                table: "EmrPatientConsultation",
                type: "nvarchar(50)",
                maxLength: 50,
                nullable: true,
                oldClrType: typeof(string),
                oldType: "nvarchar(20)",
                oldMaxLength: 20,
                oldNullable: true);

            migrationBuilder.AddColumn<string>(
                name: "MetadataJson",
                table: "AuditLogs",
                type: "nvarchar(max)",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "ModuleCode",
                table: "AuditLogs",
                type: "nvarchar(50)",
                maxLength: 50,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "PatientCode",
                table: "AuditLogs",
                type: "nvarchar(50)",
                maxLength: 50,
                nullable: true);

            migrationBuilder.AddColumn<long>(
                name: "ReferenceId",
                table: "AuditLogs",
                type: "bigint",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "ReferenceNo",
                table: "AuditLogs",
                type: "nvarchar(100)",
                maxLength: 100,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "LanguageMaster",
                columns: table => new
                {
                    LanguageId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    LanguageName = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_LanguageMaster", x => x.LanguageId);
                });

            migrationBuilder.CreateIndex(
                name: "IX_AuditLogs_ModuleCode_ReferenceId",
                table: "AuditLogs",
                columns: new[] { "ModuleCode", "ReferenceId" });

            migrationBuilder.CreateIndex(
                name: "IX_AuditLogs_ModuleCode_ReferenceNo",
                table: "AuditLogs",
                columns: new[] { "ModuleCode", "ReferenceNo" });

            migrationBuilder.CreateIndex(
                name: "IX_AuditLogs_PatientCode",
                table: "AuditLogs",
                column: "PatientCode");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "LanguageMaster");

            migrationBuilder.DropIndex(
                name: "IX_AuditLogs_ModuleCode_ReferenceId",
                table: "AuditLogs");

            migrationBuilder.DropIndex(
                name: "IX_AuditLogs_ModuleCode_ReferenceNo",
                table: "AuditLogs");

            migrationBuilder.DropIndex(
                name: "IX_AuditLogs_PatientCode",
                table: "AuditLogs");

            migrationBuilder.DropColumn(
                name: "IsLogisticsBoy",
                table: "Users");

            migrationBuilder.DropColumn(
                name: "IsVehicleAvailable",
                table: "Users");

            migrationBuilder.DropColumn(
                name: "VehicleRegNo",
                table: "Users");

            migrationBuilder.DropColumn(
                name: "LanguageId",
                table: "PatientMaster");

            migrationBuilder.DropColumn(
                name: "MetadataJson",
                table: "AuditLogs");

            migrationBuilder.DropColumn(
                name: "ModuleCode",
                table: "AuditLogs");

            migrationBuilder.DropColumn(
                name: "PatientCode",
                table: "AuditLogs");

            migrationBuilder.DropColumn(
                name: "ReferenceId",
                table: "AuditLogs");

            migrationBuilder.DropColumn(
                name: "ReferenceNo",
                table: "AuditLogs");

            migrationBuilder.AlterColumn<string>(
                name: "Age",
                schema: "dbo",
                table: "EmrPatientConsultation",
                type: "nvarchar(20)",
                maxLength: 20,
                nullable: true,
                oldClrType: typeof(string),
                oldType: "nvarchar(50)",
                oldMaxLength: 50,
                oldNullable: true);
        }
    }
}
