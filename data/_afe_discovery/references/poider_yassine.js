const fs = require("fs");


async function main() {

    const data = await fetch("https://admin.vifaakenya.org/api/prices/byProductsAndDates", {
        "headers": {
          "accept": "application/json, text/plain, */*",
          "accept-language": "en-GB,en-US;q=0.9,en;q=0.8,fr;q=0.7",
          "cache-control": "no-cache",
          "content-type": "application/json",
          "pragma": "no-cache",
          "sec-ch-ua": "\"Chromium\";v=\"116\", \"Not)A;Brand\";v=\"24\", \"Google Chrome\";v=\"116\"",
          "sec-ch-ua-mobile": "?0",
          "sec-ch-ua-platform": "\"macOS\"",
          "sec-fetch-dest": "empty",
          "sec-fetch-mode": "cors",
          "sec-fetch-site": "cross-site",
          "Referer": "https://viz.africafertilizer.org/",
          "Referrer-Policy": "strict-origin-when-cross-origin"
        },
        "body": "{\"unit\":\"MZN_50_KG\",\"dates\":[\"2023-06-01\",\"2023-06-30\"],\"zoneSelected\":false,\"treePlantation\":false,\"zoomLevel\":6,\"years\":[2023],\"yearSelected\":2023,\"townsSelected\":[738669,737070,712598,729323,728796,740167,749492,712596,751110,721228,713003,713909,712582,717415,712594,737763,733647,725086,724967,712589,717413,716317,740936,734717,734385,751128,751017,728501,739985,760656,760575,760609,740240,760571,727705,760573,760661,716801,760751,727387,760812],\"currencyCode\":\"MZN\",\"compoundProductSelected\":\"281\",\"countryIso\":\"MZ\",\"lang\":\"en\"}",
        "method": "POST"
      }).then(res => res.json()).then(res => res)

    await fs.writeFileSync("MonthlyInternationalPrice.json", JSON.stringify(data, null, 2));
}

main();