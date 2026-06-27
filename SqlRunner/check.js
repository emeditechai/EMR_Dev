const fs = require('fs');
const acorn = require('acorn');
const content = fs.readFileSync('../EMR.Web/Views/DoctorRoster/Index.cshtml', 'utf8');

// Extract all <script> blocks
const regex = /<script.*?>([\s\S]*?)<\/script>/g;
let match;
while ((match = regex.exec(content)) !== null) {
    let scriptContent = match[1];
    // Remove razor syntax like @Url.Action
    scriptContent = scriptContent.replace(/@Url\.Action\("[^"]+", "[^"]+"\)/g, '"/mock/url"');
    scriptContent = scriptContent.replace(/@Html\.Raw\([^)]+\)/g, '"{}"');
    try {
        acorn.parse(scriptContent, { ecmaVersion: 2022 });
    } catch (e) {
        console.error("Syntax error found:", e);
    }
}
console.log("Syntax check complete.");
