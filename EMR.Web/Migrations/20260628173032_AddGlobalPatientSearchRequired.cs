using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace EMR.Web.Migrations
{
    /// <inheritdoc />
    public partial class AddGlobalPatientSearchRequired : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.EnsureSchema(
                name: "dbo");

            migrationBuilder.AddColumn<TimeSpan>(
                name: "AppointmentTime",
                table: "PatientOPDService",
                type: "time",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "ScheduleId",
                table: "PatientOPDService",
                type: "int",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "PhotoPath",
                table: "PatientMaster",
                type: "nvarchar(500)",
                maxLength: 500,
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "GlobalPatientSearchRequired",
                table: "HospitalSettings",
                type: "bit",
                nullable: false,
                defaultValue: false);

            migrationBuilder.CreateTable(
                name: "DoctorSpecialityMaster",
                schema: "dbo",
                columns: table => new
                {
                    SpecialityId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    SpecialityName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    SpecialityCode = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_DoctorSpecialityMaster", x => x.SpecialityId);
                });

            migrationBuilder.CreateTable(
                name: "EmrInvestigationMaster",
                schema: "dbo",
                columns: table => new
                {
                    InvestigationId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    InvestigationName = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    Category = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: true),
                    Unit = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: true),
                    NormalRange = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: true),
                    Description = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: false),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmrInvestigationMaster", x => x.InvestigationId);
                });

            migrationBuilder.CreateTable(
                name: "EmrMedicationMaster",
                schema: "dbo",
                columns: table => new
                {
                    MedicationId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    MedicationName = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    GenericName = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: true),
                    Category = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: true),
                    Strength = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: true),
                    Unit = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: true),
                    RouteOfAdministration = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: false),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmrMedicationMaster", x => x.MedicationId);
                });

            migrationBuilder.CreateTable(
                name: "EmrPatientConsultation",
                schema: "dbo",
                columns: table => new
                {
                    ConsultationId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    OPDServiceId = table.Column<int>(type: "int", nullable: false),
                    PatientId = table.Column<int>(type: "int", nullable: false),
                    DoctorId = table.Column<int>(type: "int", nullable: false),
                    TemplateId = table.Column<int>(type: "int", nullable: false),
                    OPDBillNo = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: false),
                    PatientCode = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: false),
                    PatientName = table.Column<string>(type: "nvarchar(150)", maxLength: 150, nullable: false),
                    Gender = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: true),
                    Age = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: true),
                    MobileNumber = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: true),
                    VisitDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    VisitType = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: false),
                    ConsultationType = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: false),
                    EmrDataJson = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: false),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmrPatientConsultation", x => x.ConsultationId);
                });

            migrationBuilder.CreateTable(
                name: "EmrTemplates",
                schema: "dbo",
                columns: table => new
                {
                    TemplateId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    TemplateName = table.Column<string>(type: "nvarchar(150)", maxLength: 150, nullable: false),
                    Description = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmrTemplates", x => x.TemplateId);
                });

            migrationBuilder.CreateTable(
                name: "ServiceMaster",
                columns: table => new
                {
                    ServiceId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    ItemCode = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: false),
                    ItemName = table.Column<string>(type: "nvarchar(150)", maxLength: 150, nullable: false),
                    ServiceType = table.Column<string>(type: "nvarchar(20)", maxLength: 20, nullable: false),
                    ItemCharges = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    IsRegistration = table.Column<bool>(type: "bit", nullable: false),
                    ConsultingType = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    BranchId = table.Column<int>(type: "int", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ServiceMaster", x => x.ServiceId);
                });

            migrationBuilder.CreateTable(
                name: "SmtpEmailConfiguration",
                columns: table => new
                {
                    Id = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    BranchId = table.Column<int>(type: "int", nullable: false),
                    ConfigName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    ProviderType = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: false),
                    SmtpHost = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    SmtpPort = table.Column<int>(type: "int", nullable: false),
                    UseSsl = table.Column<bool>(type: "bit", nullable: false),
                    UseStartTls = table.Column<bool>(type: "bit", nullable: false),
                    SenderEmail = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    SenderDisplayName = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: true),
                    Username = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    PasswordEncrypted = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: false),
                    IsDefault = table.Column<bool>(type: "bit", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    LastTestedDate = table.Column<DateTime>(type: "datetime2", nullable: true),
                    LastTestResult = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: true),
                    CreatedBy = table.Column<int>(type: "int", nullable: false),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SmtpEmailConfiguration", x => x.Id);
                    table.ForeignKey(
                        name: "FK_SmtpEmailConfiguration_Branchmaster_BranchId",
                        column: x => x.BranchId,
                        principalTable: "Branchmaster",
                        principalColumn: "BranchID",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "EmrTemplateSections",
                schema: "dbo",
                columns: table => new
                {
                    SectionId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    TemplateId = table.Column<int>(type: "int", nullable: false),
                    SectionName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    DisplayOrder = table.Column<int>(type: "int", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmrTemplateSections", x => x.SectionId);
                    table.ForeignKey(
                        name: "FK_EmrTemplateSections_EmrTemplates_TemplateId",
                        column: x => x.TemplateId,
                        principalSchema: "dbo",
                        principalTable: "EmrTemplates",
                        principalColumn: "TemplateId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "EmrTemplateSpecialityMap",
                schema: "dbo",
                columns: table => new
                {
                    TemplateId = table.Column<int>(type: "int", nullable: false),
                    SpecialityId = table.Column<int>(type: "int", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmrTemplateSpecialityMap", x => new { x.TemplateId, x.SpecialityId });
                    table.ForeignKey(
                        name: "FK_EmrTemplateSpecialityMap_DoctorSpecialityMaster_SpecialityId",
                        column: x => x.SpecialityId,
                        principalSchema: "dbo",
                        principalTable: "DoctorSpecialityMaster",
                        principalColumn: "SpecialityId",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_EmrTemplateSpecialityMap_EmrTemplates_TemplateId",
                        column: x => x.TemplateId,
                        principalSchema: "dbo",
                        principalTable: "EmrTemplates",
                        principalColumn: "TemplateId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "EmailLogs",
                columns: table => new
                {
                    Id = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    BranchId = table.Column<int>(type: "int", nullable: false),
                    ConfigId = table.Column<int>(type: "int", nullable: false),
                    RecipientEmail = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    Subject = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    SentDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    Status = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: false),
                    ErrorMessage = table.Column<string>(type: "nvarchar(max)", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmailLogs", x => x.Id);
                    table.ForeignKey(
                        name: "FK_EmailLogs_Branchmaster_BranchId",
                        column: x => x.BranchId,
                        principalTable: "Branchmaster",
                        principalColumn: "BranchID",
                        onDelete: ReferentialAction.Restrict);
                    table.ForeignKey(
                        name: "FK_EmailLogs_SmtpEmailConfiguration_ConfigId",
                        column: x => x.ConfigId,
                        principalTable: "SmtpEmailConfiguration",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "EmrTemplateFields",
                schema: "dbo",
                columns: table => new
                {
                    FieldId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    SectionId = table.Column<int>(type: "int", nullable: false),
                    FieldName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    FieldType = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: false),
                    OptionsJson = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    IsRequired = table.Column<bool>(type: "bit", nullable: false),
                    DisplayOrder = table.Column<int>(type: "int", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EmrTemplateFields", x => x.FieldId);
                    table.ForeignKey(
                        name: "FK_EmrTemplateFields_EmrTemplateSections_SectionId",
                        column: x => x.SectionId,
                        principalSchema: "dbo",
                        principalTable: "EmrTemplateSections",
                        principalColumn: "SectionId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_EmailLogs_BranchId",
                table: "EmailLogs",
                column: "BranchId");

            migrationBuilder.CreateIndex(
                name: "IX_EmailLogs_ConfigId",
                table: "EmailLogs",
                column: "ConfigId");

            migrationBuilder.CreateIndex(
                name: "IX_EmrTemplateFields_SectionId",
                schema: "dbo",
                table: "EmrTemplateFields",
                column: "SectionId");

            migrationBuilder.CreateIndex(
                name: "IX_EmrTemplateSections_TemplateId",
                schema: "dbo",
                table: "EmrTemplateSections",
                column: "TemplateId");

            migrationBuilder.CreateIndex(
                name: "IX_EmrTemplateSpecialityMap_SpecialityId",
                schema: "dbo",
                table: "EmrTemplateSpecialityMap",
                column: "SpecialityId");

            migrationBuilder.CreateIndex(
                name: "IX_SmtpEmailConfiguration_BranchId",
                table: "SmtpEmailConfiguration",
                column: "BranchId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "EmailLogs");

            migrationBuilder.DropTable(
                name: "EmrInvestigationMaster",
                schema: "dbo");

            migrationBuilder.DropTable(
                name: "EmrMedicationMaster",
                schema: "dbo");

            migrationBuilder.DropTable(
                name: "EmrPatientConsultation",
                schema: "dbo");

            migrationBuilder.DropTable(
                name: "EmrTemplateFields",
                schema: "dbo");

            migrationBuilder.DropTable(
                name: "EmrTemplateSpecialityMap",
                schema: "dbo");

            migrationBuilder.DropTable(
                name: "ServiceMaster");

            migrationBuilder.DropTable(
                name: "SmtpEmailConfiguration");

            migrationBuilder.DropTable(
                name: "EmrTemplateSections",
                schema: "dbo");

            migrationBuilder.DropTable(
                name: "DoctorSpecialityMaster",
                schema: "dbo");

            migrationBuilder.DropTable(
                name: "EmrTemplates",
                schema: "dbo");

            migrationBuilder.DropColumn(
                name: "AppointmentTime",
                table: "PatientOPDService");

            migrationBuilder.DropColumn(
                name: "ScheduleId",
                table: "PatientOPDService");

            migrationBuilder.DropColumn(
                name: "PhotoPath",
                table: "PatientMaster");

            migrationBuilder.DropColumn(
                name: "GlobalPatientSearchRequired",
                table: "HospitalSettings");
        }
    }
}
