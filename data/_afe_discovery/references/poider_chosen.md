


imports:
1	- Fertilizers Total Import Volumes by Country Over Time (17 countries)
2	- Fertilizers Annual Import Volumes by Product  (13 products 17 countries)

exports:
3	- Fertilizers Total Export Volumes by Country Over Time  (12 country)
4	- Fertilizers Annual Export Volumes by Product (up until 2022 / 12 countries 5 products )

volumes:
5	-Total Fertilizer Production Volumes by Country Over Time  (9 countries)
	
prices:
6	- Fertilizers Historical International Price Trends  (for 16 products)


Country-wise Fertilizer Data:
7 -  Apparent Fertilizer Consumption by Country
8 -  National Average Fertilizer Consumption



headers for the next requests will be:
"
"headers": {
    "accept": "application/json",
    "accept-language": "en-US,en;q=0.9",
    "content-type": "application/json",
    "sec-ch-ua": "\"Chromium\";v=\"116\", \"Not)A;Brand\";v=\"24\", \"Google Chrome\";v=\"116\"",
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": "\"Windows\"",
    "sec-fetch-dest": "empty",
    "sec-fetch-mode": "cors",
    "sec-fetch-site": "cross-site",
    "Referer": "https://africafertilizer.org/",
    "Referrer-Policy": "strict-origin-when-cross-origin"
  },

"





1)
const link = 'https://admin.vifaakenya.org/api/imports/regional/totalImportVolumesByCountry'
const body = {
  "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014],
  "countriesSelected": [800519, 978660, 2, 805187, 683945, 3, 804180, 670465, 804873, 710067, 708364, 1, 777170, 804482, 690942, 778657, 805560],
  "lang": "en"
}

2)
const year = 2023;
  const link = 'https://admin.vifaakenya.org/api/imports/regional/byCountry'
  const body = {
    yearSelected: year,
    countriesSelected: [800519, 978660, 2, 805187, 683945, 3, 804180, 670465, 804873, 710067, 708364, 1, 777170, 804482, 690942, 778657, 805560],
    productsSelected: [17, 287, 13, 285, 11, 281, 7, 278, 21, 52, 276, 274, 0],
    lang: "en"
  }

3)
const link = "https://admin.vifaakenya.org/api/exports/regional/totalExportVolumesByCountry"
const body  = {
  "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014],
  "countriesSelected": [2, 805187, 683945, 3, 804180, 670465, 804873, 708364, 777170, 804482, 690942, 805560],
  "lang": "en"
}

4) 
	const year = 2022;
  const link = 'https://admin.vifaakenya.org/api/imports/regional/byCountry'
  const body = {
  "yearSelected": year,
  "countriesSelected": [2, 805187, 683945, 3, 804180, 670465, 804873, 708364, 777170, 804482, 690942, 805560],
  "productsSelected": [13, 281, 21, 52, 0],
  "lang": "en"
}

5)

const link = "https://admin.vifaakenya.org/api/production/regional/totalProductionVolumesByCountry"
const body = {
  "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013, 2012, 2011, 2010],
  "countriesSelected": [2, 3, 670465, 683945, 777170, 804180, 804482, 805187, 805560],
  "productsSelected": [13, 17, 281, 287, 52, 0],
  "lang": "en"
}

6) 
const link = "https://admin.vifaakenya.org/api/fob/historicalSeriesByProducts"
const body = {
  "productOriginsSelected": [2041604, 22030, 22033, 22035, 82621, 22047, 22049, 22051, 22031, 22055, 22039, 22038, 22041, 22037, 22043, 22045],
  "dates": [],
  "unit": "USD_MT",
  "currencyCode": "USD",
  "lang": "en"
}



7)
const link = "https://admin.vifaakenya.org/api/consumption/ApparentConsumption"

const year = 2022
const body = {
  "yearSelected": year,
  "countriesSelected": [800519, 978660, 2, 805187, 683945, 3, 804180, 670465, 804873, 708364, 710067, 777170, 1, 804482, 690942],
  "productsSelected": [0, 7, 11, 13, 17, 21, 52, 274, 276, 278, 281, 285, 287],
  "lang": "en"
}



8) For this there's a request for each country (there's two types of responses for these countries):

> National Average Fertilizer Consumption - by Product Ton (straight forward)
example in : https://viz.africafertilizer.org/#/nigeria/use
> National Average Fertilizer Consumption (needs translating x to years and y to value per ton)
example in: https://viz.africafertilizer.org/#/kenya/use


Kenya : 

{
  const link = "https://admin.vifaakenya.org/api/consumption/consumptionByNutrient"

  const body = {
  "nutrients": [2768212, 2768213, 2768211],
  "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013, 2012],
  "landArea": 125895,
  "zoneSelected": false,
  "treePlantation": false,
  "countryIso": "KE",
  "lang": "en"
}

}


Nigeria :

{
 const link = "https://admin.vifaakenya.org/api/consumption/consumptionByCropland"

 const body = {
  "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013],
  "dataSources": [125897, 125898],
  "zoneSelected": false,
  "treePlantation": false,
  "countryIso": "NG",
  "lang": "en"
}

}

Ghana:

{
  Const link = "https://admin.vifaakenya.org/api/consumption/consumptionByCropland"


  const body = {
  "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013],
  "dataSources": [125897, 125898],
  "zoneSelected": false,
  "treePlantation": false,
  "countryIso": "GH",
  "lang": "en"
  }
}

Senegal:

{
  const link = "https://admin.vifaakenya.org/api/consumption/consumptionByNutrient"

  const body =  {
  "nutrients": [2768212, 2768213, 2768211],
  "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016],
  "landArea": 125895,
  "zoneSelected": false,
  "treePlantation": false,
  "countryIso": "SN",
  "lang": "en"
}

}


Zambia:
{
  const link = "https://admin.vifaakenya.org/api/consumption/consumptionByNutrient"

  const body = {
  "nutrients": [2768212, 2768213, 2768211],
  "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014],
  "landArea": 125895,
  "zoneSelected": false,
  "treePlantation": false,
  "countryIso": "ZM",
  "lang": "en"
  }

}


Malawi:
{
  const link = "https://admin.vifaakenya.org/api/consumption/consumptionByNutrient"

  const body = {
  "nutrients": [2768212, 2768213, 2768211],
  "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016],
  "landArea": 125895,
  "zoneSelected": false,
  "treePlantation": false,
  "countryIso": "MW",
  "lang": "en"
}

}

Ethiopia:
{
  const link = "https://admin.vifaakenya.org/api/consumption/consumptionByNutrient"

  const body = {
  "nutrients": [2768212, 2768213, 2768211],
  "years": [2022, 2021, 2020, 2018, 2017, 2016, 2015, 2014, 2013, 2012, 2011],
  "landArea": 125895,
  "zoneSelected": false,
  "treePlantation": false,
  "countryIso": "ET",
  "lang": "en"
}

}
