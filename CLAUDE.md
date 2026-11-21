# EMR_Dev — standing rules (apply to every change, even when the request does not mention them)

## Encrypted query strings (EMR.Web) — mandatory
Never put a plain query string in a page URL. Every parameter goes in one encrypted `?q=` token, as in the lab masters.
Full standard and examples: [QUERY_STRING_ENCRYPTION_ARCHITECTURE.md](QUERY_STRING_ENCRYPTION_ARCHITECTURE.md).

- Razor `<a>` / `<form>`: `asp-encrypted-id` / `asp-encrypted-route-x` / `asp-encrypted-all-route-data` — never `asp-route-*`.
- C#: `Url.ActionEncrypted(...)` and `this.RedirectToActionEncrypted(...)` (`using EMR.Web.Extensions;`) — never
  `Url.Action` / `RedirectToAction` with route values, never `Redirect("...?x=")`.
- JavaScript cannot encrypt: page URLs come from the server (rendered `Url.ActionEncrypted`, or a `q` token in the JSON
  row). Scripts read the page's own parameters from `window.emrQuery`, not `location.search`.
- When you touch a file that still has a plain query string, convert it.
