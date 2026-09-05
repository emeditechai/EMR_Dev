import re
import sys
import glob

migration_files = glob.glob('EMR.Web/Migrations/*_AddBarcodeGenerateAtBilling.cs')
if not migration_files:
    print("Migration file not found.")
    sys.exit(1)

file_path = migration_files[0]
with open(file_path, 'r') as f:
    content = f.read()

# Replace the Up method
up_content = """        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "BarcodeGenerateAtBilling",
                table: "HospitalSettings",
                type: "bit",
                nullable: false,
                defaultValue: false);
        }"""
content = re.sub(r'protected override void Up\(MigrationBuilder migrationBuilder\)\s*\{.*?\n        \}', up_content, content, flags=re.DOTALL)

# Replace the Down method
down_content = """        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "BarcodeGenerateAtBilling",
                table: "HospitalSettings");
        }"""
content = re.sub(r'protected override void Down\(MigrationBuilder migrationBuilder\)\s*\{.*?\n        \}', down_content, content, flags=re.DOTALL)

with open(file_path, 'w') as f:
    f.write(content)

print(f"Successfully simplified {file_path}")
