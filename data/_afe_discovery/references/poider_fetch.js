const axios = require('axios');
const fs = require('fs');
const path = require('path');
const {
  _1,
  _2,
  _3,
  _4,
  _5,
  _6,
  _7,
  _8_1,
  _8_2,
  _8_3,
  _8_4,
  _8_5,
  _8_6,
  _8_7,
  _8_X,
} = require ('./requestsComponents.js');
const { get } = require('http');

const fetchDataWithRetry = async (link, body, multipleRequestsReason) => {
  const maxRetries = 100; 
  let retries = 0;

  while (retries < maxRetries) {
    try {
      const response = await axios.post(link, body, {
        headers: {
          Accept: 'application/json, text/plain, */*',
          'Accept-Language': 'en-US,en;q=0.9',
          'Content-Type': 'application/json',
          'sec-ch-ua': '"Chromium";v="116", "Not)A;Brand";v="24", "Google Chrome";v="116"',
          'sec-ch-ua-mobile': '?0',
          'sec-ch-ua-platform': '"Windows"',
          'sec-fetch-dest': 'empty',
          'sec-fetch-mode': 'cors',
          'sec-fetch-site': 'cross-site',
          Referer: 'https://viz.africafertilizer.org/',
          'Referrer-Policy': 'strict-origin-when-cross-origin'
        },
        timeout: 60000,
      });
      if(multipleRequestsReason)
        console.log('retries:', retries, "sending multiple requests for each" , multipleRequestsReason)
      else
        console.log('retries:', retries)
        // console.log(response.data);
      return response.data;
      break;
    } catch (error) {
      retries++;
      if (error.code === 'ETIMEDOUT') {
        console.log('Timeout occurred. Retrying...');
        
      } else {

        console.log('OTHER ERROR')
        break;
      }
    }

    await new Promise(resolve => setTimeout(resolve, 1000));
  }

  if (retries === maxRetries) {
    console.error('Max retries reached. Request could not be completed.');
    throw new Error('Max retries reached. Request could not be completed.');
  }
};

function simplifyDate(dateString) {
      const date = new Date(dateString)
			const year = date.getFullYear();
			const month = String(date.getMonth() + 1).padStart(2, '0'); // Add 1 to month since it's 0-based
			const day = String(date.getDate()).padStart(2, '0');
			const formattedDate = `${year}-${month}-${day}`;
      return formattedDate
}

function multipleYearsParser(data) {
  const simplifiedData = [];

  data.forEach((item) => {
    const year = item.year;
    const countriesData = item.countryVolume;
    if (!countriesData)
      throw new Error('No countryVolume data found');
    countriesData.forEach((countryData) => {
      const simplifiedItem = {
        "year": year,
        "country": countryData.country.name,
        "country code": countryData.country.isoCode,
        "region": countryData.country.regions[0].name,
        ...Object.keys(countryData)
          .filter(key => key !== "country")
          .reduce((obj, key) => {
            obj[key] = countryData[key];
            return obj;
          }, {})
      };

      simplifiedData.push(simplifiedItem);
    });
  });

  return simplifiedData;
}

function selectedYearByProductsParser(data, inputYear = undefined) {
	const simplifiedData = [];

	data.forEach((item) => {
		const country = item.country;
		const products = item.products
		const year = item.year;
		const ftwgValidated = item.ftwgValidated;
		const total = item.total;
		products.forEach((product) => {
			const simplifiedItem = {
				
				"country": country.name,
				"country code": country.isoCode,
				"year": year? year : inputYear,
				"ftwgValidated": ftwgValidated,
				"total": total,
				"region": country.regions[0].name ? country.regions[0].name : null,
				...Object.keys(product)
					.filter(key => key !== "category" && key != "additionalData" && key != "code" )
					.reduce((obj, key) => {
						obj[key] = product[key];
						return obj;
					}, {})
			};

			simplifiedData.push(simplifiedItem);
		});

	});
	return simplifiedData
}


function series_X_Y_Parser(data, y = "price") {
	const simplifiedData = [];

	data.forEach((item) => {
		const productId = item.id;
		const priceSeries = item.data
		priceSeries.forEach((price) => {
			const date = simplifyDate(price.sortingDate)
       
			const simplifiedItem = {
				"productId": productId,
				"year": price.year,
				"date": date,
			};
			simplifiedItem[y] = price.y ? price.y : null;
			simplifiedData.push(simplifiedItem);
		});
	});
		return simplifiedData
}


function getKeys(obj) {
  const keys = [];
  for (const key in obj) {
    keys.push(key);
  }
  return keys;
}

// Are we using this?
function consumptionByNutrientParser(data, country = undefined) {
  
   const key = getKeys(data)[0]
    const simplifiedData = [];
    const countryData = data[key];
    countryData.forEach((item) => {
      const year = item.year;
      const ftwgValidated = item.ftwgValidated;
      const nutrients = item.nutrients; // test this if we use this func
      nutrients.forEach((nutrient) => {
        if(nutrient.value === null)
          return;
        const simplifiedItem = {
          "year": year,
          "ftwgValidated": ftwgValidated,
          "nutrient": nutrient.name,
          "value": nutrient.value,
          "country": country
        };
        simplifiedData.push(simplifiedItem);
      });

    });
    return simplifiedData
}

function consumptionByProduct_X_Y_Parser(data, country = undefined) {
  const simplifiedData = [];
  
  const yearlyData = getConsumptionData(data)
  
  yearlyData.forEach((item) => {
    if(item.y === null)
      return;
    const simplifiedItem = {
      "year": item.x,
      "value": item.y,
      "ftwgValidated": item.ftwgValidated,
      "date": simplifyDate(item.sortingDate),
      "Land Area (hectare)" : "Cropland (FAO)",
      "country": country,
    };
    simplifiedData.push(simplifiedItem);
  });

  return simplifiedData
}

function getConsumptionData(data) {
  if (Array.isArray(data)) {
    const croplandData = data.filter(item => item.id === "Cropland (FAO)")[0];
    const yearlyData = croplandData.data;
    return yearlyData;
  } else if (typeof data === 'object' && data !== null) {
   const keys = getKeys(data);
    const key = keys[0];
    const yearlyDataArray = data[key];
    const croplandData = yearlyDataArray.filter(item => item.id === "Cropland (FAO)")[0];
    return croplandData.data;
  } 
   else 
     throw new Error('Neither an object nor an array');

  
}




const consumptionInputs = [
  {input : _8_1, country : "Kenya"},
  {input : _8_2, country : "Nigeria"},
  {input : _8_3, country : "Ghana"},
  {input : _8_4, country : "Senegal"},
  {input : _8_5, country : "Zambia"},
  {input : _8_6, country : "Malawi"},
  {input : _8_7, country : "Ethiopia"},
]

const otherDataInputs = [
  {input : _1, indicator : "totalImportVolumesByCountryOverTime", byYear : false, parser: multipleYearsParser},
  {input : _2, indicator : "importsByCountryByYear", byYear : true, parser: selectedYearByProductsParser},
  {input : _3, indicator : "totalExportVolumesByCountryOverTime", byYear : false, parser: multipleYearsParser},
  {input : _4, indicator : "exportsByCountryByYear", byYear : true, parser: selectedYearByProductsParser},
  {input : _5, indicator : "totalProductionVolumesByCountryOverTime", byYear : false, parser: multipleYearsParser},
  {input : _6, indicator : "historicalSeriesByProducts", byYear : false, parser: series_X_Y_Parser},
  {input : _7, indicator : "apparentConsumptionByCountryByYear",  byYear : true, parser: selectedYearByProductsParser},
]
async function consumptionFetcher () {
  const consumptionData = [];
  for( consumptionInput of consumptionInputs){ 
    const {input, country} = consumptionInput;
    const {link, body} = input();
    const data = await fetchDataWithRetry(link , body, "country");
    const formattedData = consumptionByProduct_X_Y_Parser(data, country);
    consumptionData.push(...formattedData);
  }

  const filepath = path.join(__dirname,"outputs" ,"consumption.json");
  fs.writeFileSync(filepath, JSON.stringify(consumptionData, null, 2));
}

const fetchingFromInput  = async (otherDataInput) => {
    
  let formattedData;
  const {input, indicator, byYear, parser} = otherDataInput;
  console.log("----starting :" + indicator)
  if(byYear)
  {
 
    const currentYear = new Date().getFullYear();
    for(let year = 2016; year <= currentYear; year++)
    {
      const {link, body} = input(year);
      const data = await fetchDataWithRetry(link , body, "year");
      const parsedData = parser(data, year);

      if(!formattedData)
        formattedData = parsedData;
      else
        formattedData.push(...parsedData);
    }
  }
  else
  {
    const {link, body} = input();
    const data = await fetchDataWithRetry(link , body);
    formattedData = parser(data);
  }
 
  const filepath = path.join(__dirname,"outputs" ,`${indicator}.json`);
  fs.writeFileSync(filepath, JSON.stringify(formattedData, null, 2));
  console.log("----finished :" + indicator)
}
async function otherDataFetcher () {
  for(otherDataInput of otherDataInputs)
  {
    await fetchingFromInput(otherDataInput);
  }
}

(async function main() {


  await consumptionFetcher();
  await otherDataFetcher();
  // const {link, body} = _5();
  // const data = await fetchDataWithRetry(link , body);
  // const formattedData = multipleYearsParser(data);
  // console.log(JSON.stringify(formattedData, null, 2));
  // const {link, body} = _2(2016);
  // const data = await fetchDataWithRetry(link , body);
  // const formattedData = selectedYearByProductsParser(data, 2016);
  // console.log(JSON.stringify(formattedData, null, 2));
    // fs.writeFileSync("MonthlyInternationalPrice.json", JSON.stringify(data, null, 2));
})();