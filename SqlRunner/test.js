const fs = require('fs');
const content = fs.readFileSync('../EMR.Web/Views/DoctorRoster/Index.cshtml', 'utf8');
console.log(content.includes('removeAllEvents'));
