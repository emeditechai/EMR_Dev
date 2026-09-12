using System;
using System.Net.Http;
using System.Threading.Tasks;

var client = new HttpClient();
var response = await client.GetAsync("https://localhost:5125/api/dashboard"); // just to see if API works
Console.WriteLine(response.StatusCode);
