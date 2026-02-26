# EMR System - Implementation Reference

## Architecture
- Framework: ASP.NET Core MVC (.NET 9)
- Data Access: Entity Framework Core with SQL Server
- Authentication: Cookie-based authentication with BCrypt password verification
- Design Pattern: MVC with clear separation of entities, controllers, and view models

## Scope Implemented
1. Login page and secure authentication
2. Branch selection page after login (for users mapped to multiple branches)
3. Dashboard page (branch-aware)
4. User Master module (CRUD + branch and role mapping)
5. Branch Master module (CRUD)
6. Branch-wise role mapping module for users
7. SQL scripts for schema and seed data
8. Audit log module (user actions with branch, IP, timestamp)
9. EF Core migrations support

## Important Business Rules
- User `admin` is treated as super admin and bypasses role restrictions.
- Access still remains branch-wise; branch must be selected after login.
- One user can be mapped with multiple branches.
- One user can be mapped with multiple roles.
- Roles can be branch-specific via `roles.BranchID`.

## Project Structure
- `EMR.Web` : Main MVC project
- `SQLScripts/01_schema.sql` : Full database schema
- `SQLScripts/02_seed_data.sql` : Seed data aligned to reference rows
- `EMR.Web/Migrations` : EF Core migration files

## Database Configuration
Connection string is configured in:
- `EMR.Web/appsettings.json`

Configured values:
- Server: `198.38.81.123`
- Database: `Dev_EMR`
- User: `sa`

## Current Flow
1. User logs in from `/Account/Login`
2. If user has multiple branches, user lands on `/Account/SelectBranch`
3. Branch selection enriches claims with branch and role context
4. User lands on `/Dashboard/Index`
5. Admin/Super Admin manages users, branches, and role mappings

## Security Notes
- Passwords are verified using BCrypt hash.
- Forms are protected with anti-forgery tokens.
- Access to modules is protected via role checks (`Administrator`/`SuperAdmin`).
- For production, move DB connection string to secure secret store.

## Run Instructions
```bash
cd EMR.Web
dotnet restore
dotnet run
```

Then open the app URL printed in terminal.

## EF Migration Commands
```bash
cd EMR.Web
dotnet ef migrations add InitialCreateWithAudit
dotnet ef database update
```

Note: if `database update` fails with SQL authentication error, verify SQL Server login and firewall access from your machine.

## Next Recommended Enhancements
- Add audit trails and activity logs for all master changes
- Add pagination and search for masters
- Add role-based menu rendering per selected branch
- Add MFA workflow if `RequiresMFA = 1`
