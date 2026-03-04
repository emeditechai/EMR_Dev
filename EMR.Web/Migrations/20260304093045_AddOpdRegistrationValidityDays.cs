using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace EMR.Web.Migrations
{
    /// <inheritdoc />
    public partial class AddOpdRegistrationValidityDays : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "ByPassActualDayRate",
                table: "HospitalSettings");

            migrationBuilder.DropColumn(
                name: "CancellationRefundApprovalThreshold",
                table: "HospitalSettings");

            migrationBuilder.DropColumn(
                name: "DiscountApprovalRequired",
                table: "HospitalSettings");

            migrationBuilder.DropColumn(
                name: "MinimumBookingAmount",
                table: "HospitalSettings");

            migrationBuilder.DropColumn(
                name: "MinimumBookingAmountRequired",
                table: "HospitalSettings");

            migrationBuilder.DropColumn(
                name: "NoShowGraceHours",
                table: "HospitalSettings");

            migrationBuilder.AddColumn<string>(
                name: "ProfilePicturePath",
                table: "Users",
                type: "nvarchar(300)",
                maxLength: 300,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "EmployeeCode",
                table: "UserBranches",
                type: "nvarchar(max)",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "OpdRegistrationValidityDays",
                table: "HospitalSettings",
                type: "int",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "IdentificationTypeMaster",
                columns: table => new
                {
                    IdentificationTypeId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    IdentificationTypeName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_IdentificationTypeMaster", x => x.IdentificationTypeId);
                });

            migrationBuilder.CreateTable(
                name: "MaritalStatusMaster",
                columns: table => new
                {
                    MaritalStatusId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    StatusName = table.Column<string>(type: "nvarchar(50)", maxLength: 50, nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MaritalStatusMaster", x => x.MaritalStatusId);
                });

            migrationBuilder.CreateTable(
                name: "OccupationMaster",
                columns: table => new
                {
                    OccupationId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    OccupationName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_OccupationMaster", x => x.OccupationId);
                });

            migrationBuilder.CreateTable(
                name: "PatientMaster",
                columns: table => new
                {
                    PatientId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    PatientCode = table.Column<string>(type: "nvarchar(30)", maxLength: 30, nullable: false),
                    PhoneNumber = table.Column<string>(type: "nvarchar(15)", maxLength: 15, nullable: false),
                    SecondaryPhoneNumber = table.Column<string>(type: "nvarchar(15)", maxLength: 15, nullable: true),
                    Salutation = table.Column<string>(type: "nvarchar(10)", maxLength: 10, nullable: true),
                    FirstName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    MiddleName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: true),
                    LastName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    Gender = table.Column<string>(type: "nvarchar(10)", maxLength: 10, nullable: false),
                    DateOfBirth = table.Column<DateTime>(type: "datetime2", nullable: true),
                    ReligionId = table.Column<int>(type: "int", nullable: true),
                    EmailId = table.Column<string>(type: "nvarchar(150)", maxLength: 150, nullable: true),
                    GuardianName = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: true),
                    CountryId = table.Column<int>(type: "int", nullable: true),
                    StateId = table.Column<int>(type: "int", nullable: true),
                    DistrictId = table.Column<int>(type: "int", nullable: true),
                    CityId = table.Column<int>(type: "int", nullable: true),
                    AreaId = table.Column<int>(type: "int", nullable: true),
                    Address = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: true),
                    RelationId = table.Column<int>(type: "int", nullable: true),
                    IdentificationTypeId = table.Column<int>(type: "int", nullable: true),
                    IdentificationNumber = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: true),
                    IdentificationFilePath = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: true),
                    OccupationId = table.Column<int>(type: "int", nullable: true),
                    MaritalStatusId = table.Column<int>(type: "int", nullable: true),
                    BloodGroup = table.Column<string>(type: "nvarchar(10)", maxLength: 10, nullable: true),
                    KnownAllergies = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: true),
                    Remarks = table.Column<string>(type: "nvarchar(1000)", maxLength: 1000, nullable: true),
                    BranchId = table.Column<int>(type: "int", nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PatientMaster", x => x.PatientId);
                });

            migrationBuilder.CreateTable(
                name: "PaymentMethodMaster",
                columns: table => new
                {
                    PaymentMethodId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    MethodName = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    MethodCode = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    RequiresRef = table.Column<bool>(type: "bit", nullable: false),
                    RequiresChequeNo = table.Column<bool>(type: "bit", nullable: false),
                    RequiresBankName = table.Column<bool>(type: "bit", nullable: false),
                    RequiresUPIRef = table.Column<bool>(type: "bit", nullable: false),
                    RequiresCardLast4 = table.Column<bool>(type: "bit", nullable: false),
                    DisplayOrder = table.Column<int>(type: "int", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PaymentMethodMaster", x => x.PaymentMethodId);
                });

            migrationBuilder.CreateTable(
                name: "RelationMaster",
                columns: table => new
                {
                    RelationId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    RelationName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    SortOrder = table.Column<int>(type: "int", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_RelationMaster", x => x.RelationId);
                });

            migrationBuilder.CreateTable(
                name: "ReligionMaster",
                columns: table => new
                {
                    ReligionId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    ReligionName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ReligionMaster", x => x.ReligionId);
                });

            migrationBuilder.CreateTable(
                name: "PatientOPDService",
                columns: table => new
                {
                    OPDServiceId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    PatientId = table.Column<int>(type: "int", nullable: false),
                    BranchId = table.Column<int>(type: "int", nullable: true),
                    ConsultingDoctorId = table.Column<int>(type: "int", nullable: true),
                    OPDBillNo = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    TokenNo = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    TotalAmount = table.Column<decimal>(type: "decimal(18,2)", nullable: true),
                    VisitDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    Status = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    ModifiedBy = table.Column<int>(type: "int", nullable: true),
                    ModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PatientOPDService", x => x.OPDServiceId);
                    table.ForeignKey(
                        name: "FK_PatientOPDService_PatientMaster_PatientId",
                        column: x => x.PatientId,
                        principalTable: "PatientMaster",
                        principalColumn: "PatientId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "PatientOPDServiceItem",
                columns: table => new
                {
                    ItemId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    OPDServiceId = table.Column<int>(type: "int", nullable: false),
                    ServiceType = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    ServiceId = table.Column<int>(type: "int", nullable: true),
                    ServiceCharges = table.Column<decimal>(type: "decimal(18,2)", nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PatientOPDServiceItem", x => x.ItemId);
                    table.ForeignKey(
                        name: "FK_PatientOPDServiceItem_PatientOPDService_OPDServiceId",
                        column: x => x.OPDServiceId,
                        principalTable: "PatientOPDService",
                        principalColumn: "OPDServiceId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "PaymentHeader",
                columns: table => new
                {
                    PaymentHeaderId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    ModuleCode = table.Column<string>(type: "nvarchar(450)", nullable: false),
                    ModuleRefId = table.Column<int>(type: "int", nullable: false),
                    OPDServiceId = table.Column<int>(type: "int", nullable: true),
                    BranchId = table.Column<int>(type: "int", nullable: false),
                    PatientId = table.Column<int>(type: "int", nullable: false),
                    SubTotal = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    LineDiscountTotal = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    HeaderDiscountType = table.Column<string>(type: "nvarchar(1)", maxLength: 1, nullable: true),
                    HeaderDiscountValue = table.Column<decimal>(type: "decimal(18,2)", nullable: true),
                    HeaderDiscountAmount = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    NetAmount = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    TotalPaid = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    BalanceDue = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    PaymentStatus = table.Column<string>(type: "nvarchar(1)", maxLength: 1, nullable: false),
                    Notes = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    LastModifiedDate = table.Column<DateTime>(type: "datetime2", nullable: true),
                    LastModifiedBy = table.Column<int>(type: "int", nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PaymentHeader", x => x.PaymentHeaderId);
                    table.ForeignKey(
                        name: "FK_PaymentHeader_PatientOPDService_OPDServiceId",
                        column: x => x.OPDServiceId,
                        principalTable: "PatientOPDService",
                        principalColumn: "OPDServiceId",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "PaymentDetail",
                columns: table => new
                {
                    PaymentDetailId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    PaymentHeaderId = table.Column<int>(type: "int", nullable: false),
                    PaymentMethodId = table.Column<int>(type: "int", nullable: false),
                    PaidAmount = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    TransactionRef = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    ChequeNo = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    BankName = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    UPIRefNo = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    CardLast4 = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    PaymentDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    Notes = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PaymentDetail", x => x.PaymentDetailId);
                    table.ForeignKey(
                        name: "FK_PaymentDetail_PaymentHeader_PaymentHeaderId",
                        column: x => x.PaymentHeaderId,
                        principalTable: "PaymentHeader",
                        principalColumn: "PaymentHeaderId",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_PaymentDetail_PaymentMethodMaster_PaymentMethodId",
                        column: x => x.PaymentMethodId,
                        principalTable: "PaymentMethodMaster",
                        principalColumn: "PaymentMethodId",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateTable(
                name: "PaymentLineItem",
                columns: table => new
                {
                    PaymentLineItemId = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    PaymentHeaderId = table.Column<int>(type: "int", nullable: false),
                    ModuleLineRefId = table.Column<int>(type: "int", nullable: false),
                    ItemDescription = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    ServiceType = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    OriginalAmount = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    LineDiscountType = table.Column<string>(type: "nvarchar(1)", maxLength: 1, nullable: true),
                    LineDiscountValue = table.Column<decimal>(type: "decimal(18,2)", nullable: true),
                    LineDiscountAmount = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    NetLineAmount = table.Column<decimal>(type: "decimal(18,2)", nullable: false),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    CreatedBy = table.Column<int>(type: "int", nullable: true),
                    IsActive = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PaymentLineItem", x => x.PaymentLineItemId);
                    table.ForeignKey(
                        name: "FK_PaymentLineItem_PaymentHeader_PaymentHeaderId",
                        column: x => x.PaymentHeaderId,
                        principalTable: "PaymentHeader",
                        principalColumn: "PaymentHeaderId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_PatientMaster_PatientCode",
                table: "PatientMaster",
                column: "PatientCode",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PatientMaster_PhoneNumber",
                table: "PatientMaster",
                column: "PhoneNumber");

            migrationBuilder.CreateIndex(
                name: "IX_PatientOPDService_PatientId",
                table: "PatientOPDService",
                column: "PatientId");

            migrationBuilder.CreateIndex(
                name: "IX_PatientOPDServiceItem_OPDServiceId",
                table: "PatientOPDServiceItem",
                column: "OPDServiceId");

            migrationBuilder.CreateIndex(
                name: "IX_PaymentDetail_PaymentHeaderId",
                table: "PaymentDetail",
                column: "PaymentHeaderId");

            migrationBuilder.CreateIndex(
                name: "IX_PaymentDetail_PaymentMethodId",
                table: "PaymentDetail",
                column: "PaymentMethodId");

            migrationBuilder.CreateIndex(
                name: "IX_PaymentHeader_ModuleCode_ModuleRefId",
                table: "PaymentHeader",
                columns: new[] { "ModuleCode", "ModuleRefId" });

            migrationBuilder.CreateIndex(
                name: "IX_PaymentHeader_OPDServiceId",
                table: "PaymentHeader",
                column: "OPDServiceId");

            migrationBuilder.CreateIndex(
                name: "IX_PaymentLineItem_PaymentHeaderId",
                table: "PaymentLineItem",
                column: "PaymentHeaderId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "IdentificationTypeMaster");

            migrationBuilder.DropTable(
                name: "MaritalStatusMaster");

            migrationBuilder.DropTable(
                name: "OccupationMaster");

            migrationBuilder.DropTable(
                name: "PatientOPDServiceItem");

            migrationBuilder.DropTable(
                name: "PaymentDetail");

            migrationBuilder.DropTable(
                name: "PaymentLineItem");

            migrationBuilder.DropTable(
                name: "RelationMaster");

            migrationBuilder.DropTable(
                name: "ReligionMaster");

            migrationBuilder.DropTable(
                name: "PaymentMethodMaster");

            migrationBuilder.DropTable(
                name: "PaymentHeader");

            migrationBuilder.DropTable(
                name: "PatientOPDService");

            migrationBuilder.DropTable(
                name: "PatientMaster");

            migrationBuilder.DropColumn(
                name: "ProfilePicturePath",
                table: "Users");

            migrationBuilder.DropColumn(
                name: "EmployeeCode",
                table: "UserBranches");

            migrationBuilder.DropColumn(
                name: "OpdRegistrationValidityDays",
                table: "HospitalSettings");

            migrationBuilder.AddColumn<bool>(
                name: "ByPassActualDayRate",
                table: "HospitalSettings",
                type: "bit",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<decimal>(
                name: "CancellationRefundApprovalThreshold",
                table: "HospitalSettings",
                type: "decimal(18,2)",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "DiscountApprovalRequired",
                table: "HospitalSettings",
                type: "bit",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<decimal>(
                name: "MinimumBookingAmount",
                table: "HospitalSettings",
                type: "decimal(18,2)",
                nullable: false,
                defaultValue: 0m);

            migrationBuilder.AddColumn<bool>(
                name: "MinimumBookingAmountRequired",
                table: "HospitalSettings",
                type: "bit",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<int>(
                name: "NoShowGraceHours",
                table: "HospitalSettings",
                type: "int",
                nullable: false,
                defaultValue: 0);
        }
    }
}
