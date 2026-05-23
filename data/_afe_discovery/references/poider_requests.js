function _1() {
 const link = 'https://admin.vifaakenya.org/api/imports/regional/totalImportVolumesByCountry'
 const body = {
  "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014],
  "countriesSelected": [800519, 978660, 2, 805187, 683945, 3, 804180, 670465, 804873, 710067, 
 708364, 1, 777170, 804482, 690942, 778657, 805560],
  "lang": "en"
 }
return {link, body}
}

function _2(year = 2023) {

const link = 'https://admin.vifaakenya.org/api/imports/regional/byCountry'
const body = {
yearSelected: year,
countriesSelected: [800519, 978660, 2, 805187, 683945, 3, 804180, 670465, 804873, 710067, 
708364, 1, 777170, 804482, 690942, 778657, 805560],
productsSelected: [17, 287, 13, 285, 11, 281, 7, 278, 21, 52, 276, 274, 0],
lang: "en"
}
return {link, body}
}

function _3() {
 const link = "https://admin.vifaakenya.org/api/exports/regional/totalExportVolumesByCountry"
 const body = {
  "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014],
  "countriesSelected": [2, 805187, 683945, 3, 804180, 670465, 804873, 708364, 777170, 804482, 
 690942, 805560],
  "lang": "en"
 }
 
return {link, body}
}


function _4(year = 2022) {

   const link = "https://admin.vifaakenya.org/api/exports/regional/byCountry";
   const body = {
    "yearSelected": 2022,
    "countriesSelected": [800519, 2, 805187, 683945, 3, 804180, 670465, 804873, 708364, 777170, 
   804482, 690942, 805560],
    "productsSelected": [13, 281, 21, 52, 0],
    "lang": "en"
   };
return {link, body}
}


function _5() {
 const link = "https://admin.vifaakenya.org/api/production/regional/totalProductionVolumesByCountry"
 const body = {
  "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013, 2012, 2011, 2010],
  "countriesSelected": [2, 3, 670465, 683945, 777170, 804180, 804482, 805187, 805560],
  "productsSelected": [13, 17, 281, 287, 52, 0],
  "lang": "en"
 }
 
return {link, body}
}


function _6() {
 const link = "https://admin.vifaakenya.org/api/fob/historicalSeriesByProducts"
 const body = {
  "productOriginsSelected": [2041604, 22030, 22033, 22035, 82621, 22047, 22049, 22051, 22031, 
 22055, 22039, 22038, 22041, 22037, 22043, 22045],
  "dates": [],
  "unit": "USD_MT",
  "currencyCode": "USD",
  "lang": "en"
 }
return {link, body}
}


function _7(year = 2022) {
 const link = "https://admin.vifaakenya.org/api/consumption/ApparentConsumption"
 const body = {
  "yearSelected": year,
  "countriesSelected": [800519, 978660, 2, 805187, 683945, 3, 804180, 670465, 804873, 708364, 
 710067, 777170, 1, 804482, 690942],
  "productsSelected": [0, 7, 11, 13, 17, 21, 52, 274, 276, 278, 281, 285, 287],
  "lang": "en"
 }
return {link, body}

}




function _8_1() {
   const link = "https://admin.vifaakenya.org/api/consumption/consumptionByProduct";
   const body = {
     "nutrients": [2768212, 2768213, 2768211],
     "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013, 2012],
     "landArea": 125895,
     "zoneSelected": false,
     "treePlantation": false,
     "countryIso": "KE",
     "lang": "en"
   };
return {link, body}
}

function _8_2() {

   const link = "https://admin.vifaakenya.org/api/consumption/consumptionByCropland"
   const body = {
    "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013],
    "dataSources": [125897, 125898],
    "zoneSelected": false,
    "treePlantation": false,
    "countryIso": "NG",
    "lang": "en"
   }
   
return {link, body}
}

function _8_3() {
 const link = "https://admin.vifaakenya.org/api/consumption/consumptionByCropland"
 const body = {
 "years": [2023, 2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013],
 "dataSources": [125897, 125898],
 "zoneSelected": false,
 "treePlantation": false,
 "countryIso": "GH",
 "lang": "en"
 }
return {link, body}
}

function _8_4() {
   const link = "https://admin.vifaakenya.org/api/consumption/consumptionByProduct";
   const body = {
     "nutrients": [2768212, 2768213, 2768211],
     "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016],
     "landArea": 125895,
     "zoneSelected": false,
     "treePlantation": false,
     "countryIso": "SN",
     "lang": "en"
   }

return {link, body}
}

function _8_5() {
   const link = "https://admin.vifaakenya.org/api/consumption/consumptionByProduct";
   const body = {
     "nutrients": [2768212, 2768213, 2768211],
     "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014],
     "landArea": 125895,
     "zoneSelected": false,
     "treePlantation": false,
     "countryIso": "ZM",
     "lang": "en"
   };
return {link, body}
}

function _8_6() {
   const link = "https://admin.vifaakenya.org/api/consumption/consumptionByProduct";
   const body = {
     "nutrients": [2768212, 2768213, 2768211],
     "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016],
     "landArea": 125895,
     "zoneSelected": false,
     "treePlantation": false,
     "countryIso": "MW",
     "lang": "en"
   }
return {link, body}
}

function _8_7() {
   const link = "https://admin.vifaakenya.org/api/consumption/consumptionByProduct";
   const body = {
     "nutrients": [2768212, 2768213, 2768211],
     "years": [2022, 2021, 2020, 2018, 2017, 2016, 2015, 2014, 2013, 2012, 2011],
     "landArea": 125895,
     "zoneSelected": false,
     "treePlantation": false,
     "countryIso": "ET",
     "lang": "en"
   };
return {link, body}
}

function _8_X() {
//    const link = "https://admin.vifaakenya.org/api/consumption/consumptionByProduct";
// const body = {
//   "nutrients": [2768212, 2768213, 2768211],
//   "years": [2022, 2021, 2020, 2019, 2018, 2017, 2016, 2015, 2014, 2013, 2012],
//   "landArea": 125895,
//   "zoneSelected": false,
//   "treePlantation": false,
//   "countryIso": "KE",
//   "lang": "en"
// };

return {link, body}
}

module.exports = {
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
 _8_X
}