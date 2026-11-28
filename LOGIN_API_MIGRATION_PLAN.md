# Moving sign-in, lockout, password, branch / role selection and the menu to EMR.Api (plan)

Status: plan only, nothing built yet (28 Nov 2026).

## Goal
EMR.Api becomes the only place that checks a password, locks an account, issues a session, lets the user choose a branch /
role and decides which menu items they see. EMR.Web, the mobile apps and any later client all use the same endpoints and
the same rules. EMR.Web no longer reads `dbo.Users`, `UserRoles`, `UserBranches` or the permission tables for sign-in.

## 1. Where things are today

| Part | EMR.Web (`AccountController`, 1 044 lines) | EMR.Api (`AuthController`) |
|---|---|---|
| Password check, lockout | own code + `ILoginSecurity` (EMR.Shared.Security) | `login`, same `ILoginSecurity` |
| Sign-in by e-mail (several accounts on one e-mail) | yes | no (username only) |
| Wrong-password WhatsApp alert (2383) | `LoginAlertNotifier` | no |
| Company Valid From / To (2472) | yes | no |
| "No active role" refusal | yes | partly (roles at `context`) |
| Super Admin sign-in code (2579) | `SuperAdminOtpService`, `LoginOtp` page | no |
| Must change password | forced change page | refused ("change it in the web application") |
| Branch / role choice, switch | `SelectBranch`, `SwitchBranch`, `SelectRole`, `SwitchRole` | `login` ticket -> `context`, `switch-branch` (no switch-role) |
| Session | cookie with claims, `KeepAlive`, idle timeout (`IdleSessionPolicy`) | access + refresh tokens, `refresh`, `logout` (revokes the family) |
| Password change / forgot | `ChangePassword`, `ForgotPassword` (e-mail link, `PasswordResetService`) | `password/change`, `first-change`, `forgot` / `verify` / `reset` (WhatsApp code) |
| Menu | `DatabaseNavViewComponent` reads `IPermissionDataSource` directly | `permissions` (ETag), no menu tree |
| Calls from web to API | `EmrApiTokenHandler` gets a token from `api/auth/web-token` after the web's own sign-in | — |
| Other sign-ins | franchise (`FranchiseLoginService`), patient portal (`PatientPortalLoginService`) | patient app (`PatientAuthController`) |

So about two thirds of the API side exists; the work is mostly **parity** (the web rules the API does not have yet) and
**switching the web over**.

## 2. Target design (recommended: the web as a "backend for frontend")

```
Browser --(cookie, antiforgery)--> EMR.Web --(Bearer access token)--> EMR.Api --> SQL
                                     |  keeps the user's refresh token server-side (session / protected cookie)
```

* The browser never sees an API token: EMR.Web keeps its HttpOnly cookie and antiforgery, as today.
* EMR.Web posts the credentials to `api/auth/login`, stores the returned access + refresh token for that browser session,
  and builds its cookie claims from `api/auth/me` (user, branch, role, company, IsSuperAdmin).
* `EmrApiTokenHandler` uses the stored access token and refreshes it with `api/auth/refresh`; `api/auth/web-token`
  (the web vouching for its own users) is removed at the end.
* Not recommended: the browser calling the API directly with tokens in JavaScript (XSS exposure, CORS, every page changes).

## 3. API work (parity first)

| # | Endpoint / change | Notes |
|---|---|---|
| A1 | `login` accepts username **or e-mail**; several accounts on one e-mail behave as on the web | port the candidate loop from `AccountController.Login` |
| A2 | Company validity (2472), "no active role", inactive / unverified answers with the web's messages | codes: `COMPANY_EXPIRED`, `NO_ROLE`, ... |
| A3 | Wrong-password WhatsApp alert and "tries left" message | move `LoginAlertNotifier` to the API (needs the client IP, see 6) |
| A4 | Super Admin code: `login` answers `OTP_REQUIRED` + ticket; new `otp/verify`, `otp/resend` | move `SuperAdminOtpService` and `dbo.UserLoginOtp` use to the API |
| A5 | Must change password: `login` answers `PASSWORD_CHANGE_REQUIRED` + ticket, `password/first-change` takes the ticket | instead of refusing |
| A6 | `switch-role`; `branches` / `roles` for a ticket or a signed-in user | the web's role summary |
| A7 | Forgot password by **e-mail link** as well as the WhatsApp code | link token encrypted (`?q=`), see QUERY_STRING_ENCRYPTION_ARCHITECTURE.md |
| A8 | `api/menu`: the menu tree for user + branch + role, with ETag | logic of `DatabaseNavViewComponent` moved to the API; web caches by ETag |
| A9 | Day-closing check at sign-in, audit log lines (`AuthSuccess` / `AuthFailure`) as the web writes them | same audit table |
| A10 | Unlock user / reset lockout (User Master) | admin endpoint, permission-checked |
| A11 | Session rules: idle timeout and absolute lifetime from Hospital Settings, refresh rotation already there | `IdleSessionPolicy` moved to the API |

## 4. Web work

1. `IAuthApiClient` (EMR.Web/ApiClients) for every endpoint above.
2. `AccountController` actions call the API and only render pages / set the cookie: Login, LoginOtp, SelectBranch,
   SwitchBranch, SelectRole, SwitchRole, ChangePassword, ForgotPassword, ResetPassword, Logout, KeepAlive.
3. Token store per browser session (server-side, keyed by the session; refresh token never in a readable cookie).
4. `EmrApiTokenHandler`: stored token -> refresh on 401 -> back to sign-in when refresh fails.
5. `DatabaseNavViewComponent` -> `api/menu`; page permission checks (`asp-permission`, filters) read the permissions
   from `api/auth/permissions` (cached by ETag) instead of the database.
6. Franchise and patient-portal sign-ins: second phase, same pattern (the patient app already uses `PatientAuthController`).
7. Remove the web's direct reads of `Users` / `UserRoles` / `UserBranches` / permission tables, then `api/auth/web-token`.

Switch: `Auth:Mode` = `Local` (today) / `Api` in EMR.Web appsettings, so a client can be moved over and back.

## 5. Order of work and effort

| Phase | Content | Effort |
|---|---|---|
| 1 | API parity A1-A5, A9 + tests | 3-4 days |
| 2 | Web sign-in / OTP / branch / role / logout through the API behind `Auth:Mode` | 3 days |
| 3 | Password change / first change / forgot (A7) on the web through the API | 1-2 days |
| 4 | Menu and permissions from the API (A8, web step 5) | 2-3 days |
| 5 | Session rules (A11), unlock (A10), remove the old web code and `web-token` | 2 days |
| 6 | Franchise / patient portal sign-in | 2 days |
| | Testing on SIT (all roles, branches, lockout, OTP, expiry, idle timeout, mobile apps unchanged) | 2-3 days |

About 3 weeks in all; phases 1-2 alone give one sign-in for web and mobile.

## 6. Points to settle

* **Client address**: when EMR.Web calls the API, the API sees the web server's address. Rate limits, lockout alerts and
  audit lines need the user's address: the web sends it in a header the API trusts only from EMR.Web (shared secret /
  service token).
* **API down = no sign-in.** Today most pages already need the API; this makes the sign-in page need it too. Health check
  on the sign-in page with a clear message.
* **Deploy both apps together** for every client (the web's `Auth:Mode = Api` needs the matching API).
* **Speed**: one extra hop per sign-in and per menu load; the menu and permissions are cached by ETag.
* **Mobile apps** keep working: the endpoints only gain codes (`OTP_REQUIRED`, `PASSWORD_CHANGE_REQUIRED`); the apps need
  an update to handle them (until then they show the message).
* SQL scripts: none for the move itself except what A4 / A10 need beyond 2579.
