# 256-Bit AES Query String Encryption Architecture

## Overview
This document specifies the common architecture implemented for encrypting and decrypting query strings across the application using a **256-bit AES mechanism**.

---

## Architectural Components

### 1. Encryption Engine (`IQueryStringEncryptionService` / `QueryStringEncryptionService`)
- **Key Derivation**: Computes a 256-bit key (SHA-256) from configured secret in `appsettings.json`.
- **Cipher**: Uses **AES-256-CBC** with a dynamically generated 128-bit Initialization Vector (IV).
- **Encoding**: Produces Base64Url-encoded cipher text for safe transmission in URLs without encoding conflicts.

**Implementations**:
- `EMR.Web/Services/QueryStringEncryptionService.cs`
- `EMR.Api/Services/QueryStringEncryptionService.cs`

---

### 2. Transparent Decryption Middleware (`QueryStringDecryptionMiddleware`)
- **Pipeline Interception**: Intercepts requests containing `q` parameter (e.g. `?q=ENC_DATA`).
- **Decryption & Binding**: Decrypts the cipher text into key-value parameter dictionaries and populates `HttpContext.Request.Query`.
- **Seamless Model Binding**: MVC Controllers and Action methods receive parameters naturally (e.g. `[FromQuery] int id`) without code modifications.

**Implementations**:
- `EMR.Web/Middleware/QueryStringDecryptionMiddleware.cs`
- `EMR.Api/Middleware/QueryStringDecryptionMiddleware.cs`

---

### 3. Link Generation Helpers (`EncryptedQueryStringTagHelper` & Extensions)
- **Razor Tag Helper**: `asp-encrypted-qs` and `asp-encrypted-id` automatically encrypt query strings on `<a>` links and `<form>` action attributes.
- **Example Usage**:
```html
<a asp-action="Edit" asp-encrypted-id="@item.Category_ID" class="btn btn-outline-primary">
    <i class="bi bi-pencil"></i> Edit
</a>
```

---

## Running Applications
- **EMR API**: Running on `https://localhost:5125` / `http://localhost:5201`
- **EMR Web**: Running on `https://localhost:7124` / `http://localhost:5124`
