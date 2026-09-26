// Please see documentation at https://learn.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

function encryptQs(params) {
    return $.ajax({
        url: '/Home/EncryptQs',
        type: 'POST',
        contentType: 'application/json',
        data: JSON.stringify(params)
    }).then(function (res) { return res.q; });
}

function encryptedUrl(baseUrl, params) {
    return encryptQs(params).then(function (q) {
        return baseUrl + '?q=' + encodeURIComponent(q);
    });
}
