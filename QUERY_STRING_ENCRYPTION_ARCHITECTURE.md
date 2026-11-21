# Query String Encryption — mandatory standard (EMR.Web)

> **Rule:** no page of EMR.Web may put a plain query string in a URL the browser shows. Every parameter a link, form,
> redirect or script sends to a page goes inside one encrypted token, `?q=...`. This applies to **every new or changed
> view, controller and script**, whether or not the request mentions it. It is the mechanism the lab masters were built
> with (e.g. `LabTestCategories`, `LabInvestigations`) and since Nov 2026 it is applied across the whole web app.

---

## 1. How it works

| Part | File | What it does |
|---|---|---|
| Encryption engine | `EMR.Web/Services/QueryStringEncryptionService.cs` (`IQueryStringEncryptionService`) | AES-256-CBC, key = SHA-256 of `QueryStringEncryption:Key` (built-in default when not configured), random IV per token, Base64Url output. `EncryptParameters(dict)` makes one token from many parameters. |
| Decryption middleware | `EMR.Web/Middleware/QueryStringDecryptionMiddleware.cs` (registered after `UseRouting` in `Program.cs`) | Takes `?q=` (or `?enc=`), decrypts it and puts the parameters into `Request.Query` (and `id` into the route values). Controllers bind `int id`, `[FromQuery] ...` exactly as before. |
| Razor links / forms | `EMR.Web/TagHelpers/EncryptedQueryStringTagHelper.cs` | `asp-encrypted-*` attributes on `<a>` and `<form>`: the href / action gets `?q=token`. |
| C# helpers | `EMR.Web/Extensions/QueryStringEncryptionExtensions.cs` | `Url.ActionEncrypted(...)`, `this.RedirectToActionEncrypted(...)`, `Html.EncryptedUrl(...)`, `Html.EncryptId(...)`. |
| Page scripts | `EMR.Web/Views/Shared/_Layout.cshtml` | `window.emrQuery` — a `URLSearchParams` of the page's decrypted parameters (the address bar only has `q`). |

The same engine and middleware exist in EMR.Api (`EMR.Api/Services/QueryStringEncryptionService.cs`,
`EMR.Api/Middleware/QueryStringDecryptionMiddleware.cs`).

---

## 2. What to write (use these, never the plain forms)

### Razor: links and forms
| Do not write | Write |
|---|---|
| `<a asp-action="Edit" asp-route-id="@x.Id">` | `<a asp-action="Edit" asp-encrypted-id="@x.Id">` (or `asp-encrypted-route-id`) |
| `asp-route-labOrderId="@id" asp-route-tab="bill"` | `asp-encrypted-route-labOrderId="@id" asp-encrypted-route-tab="bill"` |
| `asp-all-route-data="@dict"` | `asp-encrypted-all-route-data="@dict"` |
| `href="/X/Print?id=@x.Id"` | `asp-controller="X" asp-action="Print" asp-encrypted-id="@x.Id"` |
| `href="@Url.Action("Edit", new { id })"` | `href="@Url.ActionEncrypted("Edit", new { id })"` |

`asp-encrypted-qs="a=1&b=2"` takes a raw query string. Paging, search and date filters are parameters too: they are
encrypted the same way (`asp-encrypted-route-page`, ...).

A `<form method="get">` is the one exception: the browser replaces the action's query string with the form's fields,
so a search form keeps posting its own fields (the page's *links* still use `asp-encrypted-*`).

### Controllers
| Do not write | Write |
|---|---|
| `RedirectToAction(nameof(Edit), new { id })` | `this.RedirectToActionEncrypted(nameof(Edit), new { id })` |
| `RedirectToAction("Index", "LabOrder", new { labOrderId })` | `this.RedirectToActionEncrypted("Index", "LabOrder", new { labOrderId })` |
| `Url.Action("Print", new { id })` (in a Json result, e-mail link ...) | `Url.ActionEncrypted("Print", new { id })` |
| `Redirect($"/X/Y?id={id}")` | `this.RedirectToActionEncrypted("Y", "X", new { id })` |

`RedirectToAction(nameof(Index))` with **no** route values stays as it is. Add `using EMR.Web.Extensions;`.

### JavaScript
The key never goes to the browser, so a script cannot encrypt. A URL built in a script gets its token from the server:

* **Rows rendered by the server** — render the finished URL: `data-url="@Url.ActionEncrypted("Print", new { id = r.Id })"`
  and use `el.dataset.url` in the script.
* **Rows loaded by AJAX (JSON)** — the controller adds the token to each row, as `LabRateListB2C` (`qToken`),
  `LabReportDispatch` / `LabUnapprove` (`encMap`) and `B2BInvoices` (`invEncId`) do:
  ```csharp
  // controller
  row.QToken = _qs.EncryptParameters(new Dictionary<string, string?> { ["id"] = row.Id.ToString() });
  ```
  ```js
  // view / script
  href = `${urls.print}?q=${encodeURIComponent(r.qToken)}`;
  ```
* **Reading the page's own parameters** — `window.emrQuery.get('tab')`, not `new URLSearchParams(location.search)`
  (write `(window.emrQuery || new URLSearchParams(location.search))` in pages that may run without `_Layout`).

AJAX calls that fetch data (`fetch('/X/GetRows?branchId=' + b)`) never reach the address bar; they may stay plain, but
a new one that carries a record id should take the token from the server in the same way.

---

## 3. Checklist for any new or changed page

1. No `asp-route-*` / `asp-all-route-data` on `<a>` or `<form>` — use `asp-encrypted-*`.
2. No `Url.Action(..., new { ... })` / `RedirectToAction(..., new { ... })` — use the `Encrypted` versions.
3. No `?name=` concatenated in Razor or JS for a page address — server-rendered URL or a server-provided `q` token.
4. Scripts read parameters through `window.emrQuery`.
5. Quick search before committing (should print nothing for your files):
   ```bash
   grep -rnE "asp-route-|asp-all-route-data|Url\.Action\([^)]*new *\{|[^d]RedirectToAction\([^;]*new *\{" EMR.Web/Views EMR.Web/Controllers
   ```

---

## 4. Notes

* Tokens are the same after a restart as long as `QueryStringEncryption:Key` is unchanged. Changing the key breaks
  every link already printed, mailed or bookmarked (QR codes, WhatsApp / SMS links).
* The middleware still accepts plain parameters, so old links, bookmarks and the scripts in section 5 keep working
  while they are converted. The encryption hides ids and filters from the address bar; access to a record must still
  be checked by the action itself (branch / company / permission).
* The decrypted parameters appear in the page (`window.emrQuery`) for the page's own scripts only.

---

## 5. Status (21 Nov 2026)

Converted across EMR.Web (234 files): every `asp-route-*` / `asp-all-route-data` on links and forms (563), every
`Url.Action` with route values (76) and every `RedirectToAction` with route values (131); the 7 scripts that read
`location.search` now read `window.emrQuery`.

Still plain — URLs built in JavaScript (about 80, phase 2; each needs a server-provided token as in section 2):
AccOpening/Index, Access/Assign, Analyzers/Index, DayClosing/Index & Verify, DoctorRoster/Index, FranchiseTopUp/Index,
LabExternalDocuments/Index, LabFranchiseBarcodes/Index, LabPhleboBarcodes/Index, LabImageReporting/Index & Entry,
LabOrderBooking/B2BRegistration & B2COrderList, LabReportDispatch/Index, MicrobiologyReporting/Index,
OPD/DoctorDashboard & ServiceBooking, PhReports/Report, PharmacyItems/Form, PharmacyPurchase/AutoReorder,
Quality/Equipment, EquipmentCard & IqcSetup, Reports/* (about 20 registers: the bill / print link in each row),
Vitals/Index, History & RecordVital; scripts ipd/*.js, lab/lab-estimate.js, pharmacy-pos.js,
reports/marketing-business.js, views/Quality/qc-stock-doc.js, emr-template-copyfrom.js.
Three anonymous print redirects in `PatientPortalController` (`Redirect($"/OPD/PrintBillAnonymous?id=...")`).
