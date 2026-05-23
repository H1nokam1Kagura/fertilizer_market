import ApiUtils from '../utils/apiUtils';
import {MODULE_NAMES} from "./moduleConstants";

export const endpointMapping = {
  [MODULE_NAMES.IMPORTS_BY_PRODUCT]: {
    defaultFilters: '/api/filtersDefaults/imports/byproducts',
    filters: {
      years: '/api/imports/yearsList',
      products: '/api/imports/productslist',
      dates: '/api/imports/dateslist',
    },
    chartData: {
      months: '/api/imports/byproducts',
      periods: '/api/imports/consecutive',
      years: '/api/imports/byProductsYearly'
    },
    settings: '/api/configuration/importByProductsChart'
  },
  [MODULE_NAMES.IMPORTS_BY_COUNTRY_AND_PRODUCT]: {
    defaultFilters: '/api/filtersDefaults/imports/byOriginCountryAndProduct',
    filters: {
      countries: '/api/imports/countriesList',
      years: '/api/imports/yearsExcludeUnknown',
      products: '/api/imports/productsGrouped',
    },
    settings: '/api/configuration/importsByCountryOfOriginAndProduct',
    chartData: {
      map: '/api/imports/byOriginCountryAndProduct'
    }
  },
  [MODULE_NAMES.IMPORTS_BY_COUNTRY_AND_YEAR]:{
    defaultFilters: '/api/filtersDefaults/imports/importsByCountryOfOriginAndYearChart',
    filters: {
      years: '/api/imports/yearsExcludeUnknown',
      countries: '/api/imports/countriesList',
      topCountries: '/api/imports/topCountries',
    },
    settings: '/api/configuration/importsByCountryOfOriginAndYearChart',
    chartData: {
      chart: '/api/imports/byOriginCountryAndYear'
    }
  },
  [MODULE_NAMES.IMPORTS_BY_YEAR]: {
    defaultFilters: '/api/filtersDefaults/imports/importsByYear',
    filters: {
      years: '/api/imports/yearsList',
    },
    settings: '/api/configuration/importByYearChart',
    chartData: {
      chart: '/api/imports/importsByYear'
    }
  },
  [MODULE_NAMES.IMPORTS_BY_PRODUCT_TYPE]: {
    defaultFilters: '/api/filtersDefaults/products/ProductDiversity',
    filters: {
      years: '/api/imports/yearsList',
      products: '/api/imports/productslist',
      dates: '/api/imports/dateslist',
    },
    chartData: {
      months: '/api/products/ProductDiversity',
      periods: '/api/products/consecutive',
      years: '/api/products/byTypeYearly'
    },
    settings: '/api/configuration/importByProductsTypeChart'
  },
  [MODULE_NAMES.UREA_EXPORTS]:{
    defaultFilters: '/api/filtersDefaults/exports/ureaExportByDestinationChart',
    filters: {
      years: '/api/exports/yearsList',
      countries: '/api/exports/countriesList',
    },
    settings: '/api/configuration/ureaExportByDestinationChart',
    chartData: {
      chart: '/api/exports/sankey'
    }
  },
  [MODULE_NAMES.PLANT_DIRECTORY]:{
    defaultFilters: '/api/filtersDefaults/plants',
    filters: {
      plantTypes: '/api/plants/categories',
      countries: '/api/plants/countries',
      locations: '/api/plants/admins',
      companies: '/api/plants/companies',
      defaults: '/api/filtersDefaults/plants'
    },
    chartData: {
      map: '/api/plants'
    },
    settings: '/api/configuration/fertilizerPlantsMap'
  },
  [MODULE_NAMES.GOVERNMENT_CONTRIBUTION]: {
    defaultFilters: '/api/filtersDefaults/subsidized/subsidyPriceByProduct',
    filters: {
      years: '/api/subsidized/subsidizedYears',
      products: '/api/subsidized/groupedProducts',
    },
    chartData: {
      chart: '/api/subsidized/subsidyPriceByProduct'
    },
    settings: '/api/configuration/annualGovSubsidyContributionChart'
  },
  [MODULE_NAMES.ANNUAL_SUBSIDIZED_IMPORTS]: {
    defaultFilters: '/api/filtersDefaults/subsidized/pieChart',
    filters: {
      products: '/api/subsidized/productsList',
      years: '/api/subsidized/years'
    },
    chartData: {
      chart: '/api/subsidized/pieChart'
    },
    settings: '/api/configuration/annualSubsidizedImports'
  },
  [MODULE_NAMES.ANNUAL_SUBSIDY_COVERAGE]: {
    defaultFilters: '/api/filtersDefaults/subsidized/coverage',
    filters: {
      products: '/api/subsidized/productsList',
      years: '/api/subsidized/years',
    },
    chartData: {
      chart: '/api/subsidized/coverage'
    },
    settings: '/api/configuration/annualSubsidyCoverageChart'
  },
  [MODULE_NAMES.EVOLUTION_OF_SUBSIDY_POLICIES]: {
    filters: {
      methodologiesPDFs: '/api/fertilizerMethodology/list/ke',
    },
    chartData: {
      chart: '/api/subsidized/subsidyPoliciesEvolution'
    },
    settings: '/api/configuration/evolutionFertilizerSubsidyChart'
  },
  [MODULE_NAMES.FOB_PRICES]: {
    defaultFilters: '/api/filtersDefaults/fob/seriesByProducts?chartView=true',
    filters: {
      dates: '/api/fob/datesList'
    },
    chartData: {
      chart: '/api/fob/seriesByProducts'
    },
    settings: '/api/configuration/internationalPriceChart'
  },
  [MODULE_NAMES.INTERNATIONAL_VS_RETAIL_PRICES]: {
    defaultFilters: '/api/filtersDefaults/internationalVsRetailPriceChart',
    filters: {
      products: '/api/fob/fobProductsRetailVsPrices',
      years: '/api/fob/fobYearsRetailVsPrices'
    },
    chartData: {
      chart: '/api/fob/fobRetailVsPrices'
    },
    settings: '/api/configuration/internationalVsRetailPriceChart'
  },
  [MODULE_NAMES.PRICE_COMPARISON]: {
    defaultFilters: '/api/filtersDefaults/prices/comparisonYearly',
    filters: {
      years: '/api/prices/yearsList',
      products: '/api/prices/productsList',
      dates: '/api/prices/datesList'
    },
    chartData: {
      yearly: '/api/prices/comparisonYearly',
      monthly: '/api/prices/comparisonMonthly'
    },
    settings: '/api/configuration/commercialVsRetailChart'
  },
  [MODULE_NAMES.THREE_MONTHS_PRICE_COMPARISON]: {
    defaultFilters: '/api/filtersDefaults/prices/threeMonthsComparisonConsecutivePeriods',
    filters: {
      years: '/api/prices/yearsList',
      products: '/api/prices/productsList',
      dates: '/api/prices/datesList'
    },
    chartData: {
      yearly: '/api/prices/comparisonYearly',
      monthly: '/api/prices/threeMonthsComparisonConsecutivePeriods'
    },
    settings: '/api/configuration/threeMonthsCompCommercialChart'
  },
  [MODULE_NAMES.PRICE_COMPARISON_OVER_TIME]: {
    defaultFilters: '/api/filtersDefaults/prices/comparisonSeries',
    filters: {
      years: '/api/prices/yearsList',
      products: '/api/prices/subsidizedProductsList',
    },
    chartData: {
      chart: '/api/prices/comparisonSeries'
    },
    settings: '/api/configuration/commercialVsSubsidizedOverTimeChart'
  },
  [MODULE_NAMES.RETAIL_PRICES]: {
    defaultFilters: '/api/filtersDefaults/prices/byProducts',
    filters: {
      products: '/api/prices/compoundProductsList',
      years: '/api/prices/yearsList',
      dates: '/api/prices/datesList',
      locations: '/api/prices/locations'
    },
    chartData: {
      yearly: '/api/prices/byProducts',
      monthly: '/api/prices/byProductsAndDates'
    },
    settings: '/api/configuration/retailPriceChart'
  },
  [MODULE_NAMES.RETAIL_PRICES_OVER_TIME]: {
    defaultFilters: '/api/filtersDefaults/prices/seriesByProducts',
    filters: {
      products: '/api/prices/compoundProductsList',
      dates: '/api/prices/datesList',
      locations: '/api/prices/locations',
    },
    chartData: {
      chart: '/api/prices/seriesByProducts'
    },
    settings: '/api/configuration/retailPriceEvolutionChart'
  },
  [MODULE_NAMES.COST_BUILD_UP]: {
    defaultFilters: '/api/filtersDefaults/cost/cbu',
    filters: {
      categories: '/api/cost/categories',
      years: '/api/cost/years',
      fobDates: '/api/cost/fobDatesList',
      transportTowns: '/api/cost/transportTowns',
    },
    chartData: {
      chart: '/api/cost/cbu'
    },
    settings: '/api/configuration/cbuChart'
  },
  [MODULE_NAMES.APPARENT_CONSUMPTION]: {
    defaultFilters: '/api/filtersDefaults/consumption/ApparentConsumption',
    filters: {
      products: '/api/consumption/products',
      years: '/api/consumption/years',
    },
    chartData: {
      chart: '/api/consumption/ApparentConsumption'
    },
    settings: '/api/configuration/apparentConsumptionChart'
  },
  [MODULE_NAMES.AVERAGE_CONSUMPTION]:{
    defaultFilters: '/api/filtersDefaults/consumption/consumptionByNutrient',
    filters: {
      years: '/api/consumption/yearsWithArea',
      nutrients: '/api/consumption/nutrients',
      landAreas: '/api/consumption/landAreas',
    },
    chartData: {
      nutrientTon: '/api/consumption/consumptionByNutrient',
      productTon: '/api/consumption/consumptionByProduct'
    },
    settings: '/api/configuration/consumptionByNutrientChart'
  },
  [MODULE_NAMES.CROPLAND_UNDER_PRODUCTION]: {
    defaultFilters: '/api/filtersDefaults/crops/nationalCropsUnderProductionChart',
    filters: {
      locations: '/api/crops/locationsList',
      crops: '/api/crops/cropsList',
      years: '/api/crops/yearList',
    },
    chartData: {
      chart: '/api/crops/nationalCropsUnderProductionChart',
      map: '/api/crops/nationalCropsUnderProductionMap'
    },
    settings: '/api/configuration/nationalCroplandUnderProductionChart'
  },
  [MODULE_NAMES.USE_BY_CROP]: {
    defaultFilters: '/api/filtersDefaults/fubc/fertilizerUseByCropChart',
    filters: {
      crops: '/api/crops/cropsList',
      years: '/api/fubc/years',
    },
    chartData: {
      chart: '/api/fubc/fubcseries',
      map: '/api/fubc/data',
    },
    settings: '/api/configuration/fertilizerUseByCropChart'
  },
  [MODULE_NAMES.NUTRIENT_USE_BY_CROP]: {
    defaultFilters: '/api/filtersDefaults/nubc/nutrientUseByCropChart',
    filters: {
      crops: '/api/crops/cropsList',
      years: '/api/fubc/years',
      nutrients: '/api/consumption/nutrients',
    },
    chartData: {
      map: '/api/nubc/nutrientUseByCropData',
    },
    settings: '/api/configuration/nutrientUseByCropChart'
  },
  [MODULE_NAMES.TOP_FERTILIZER_CONSUMING_CROPS]: {
    defaultFilters: '/api/filtersDefaults/fubc/topConsumingCrops',
    filters: {
      years: '/api/fubc/years',
    },
    chartData: {
      chart: '/api/fubc/topConsumingCrops'
    },
    settings: '/api/configuration/topConsumingCropsChart'
  },
  [MODULE_NAMES.CONSUMPTION_BY_NUTRIENT]: {
    defaultFilters: '/api/filtersDefaults/consumption/consumptionByNutrient',
    filters: {
      years: '/api/consumption/croplandYears',
      nutrients: '/api/consumption/nutrients',
      dataSources: '/api/consumption/dataSources',
    },
    chartData: {
      chart: '/api/consumption/consumptionByNutrient'
    },
    settings: '/api/configuration/consumptionByNutrientChart'
  },
  [MODULE_NAMES.CONSUMPTION_BY_PRODUCT]:{
    defaultFilters: '/api/filtersDefaults/consumption/consumptionByProduct',
    filters: {
      years: '/api/consumption/croplandYears',
      dataSources: '/api/consumption/dataSources',
    },
    chartData: {
      chart: '/api/consumption/consumptionByCropland'
    },
    settings: '/api/configuration/fertilizerConsumptionByProductChart'
  },
  [MODULE_NAMES.UREA_CONSUMPTION]:{
    defaultFilters: '/api/filtersDefaults/consumption/domesticUreaConsumptionChart',
    filters: {
      components: '/api/consumption/consumptionComponents',
      years: '/api/consumption/ureaConsumptionYears',
    },
    chartData: {
      chart: '/api/consumption/ureaOverTime'
    },
    settings: '/api/configuration/domesticUreaConsumptionChart'
  },
  [MODULE_NAMES.Q_CROPLAND_UNDER_PRODUCTION]: {
    defaultFilters: '/api/filtersDefaults/cropLand/nationalCroplandUnderProductionIndicatorChart',
    filters: {

    },
    chartData: {
      chart: '/api/cropLand/cropLandMap',
      tree:'/api/treePlantation/plantationMap',
    },
    settings: '/api/configuration/nationalCroplandUnderProductionIndicatorChart'
  },
  [MODULE_NAMES.TRANSIT_BY_COUNTRY_AND_YEAR]:{
    defaultFilters: '/api/filtersDefaults/transit/transitByYearAndCountry',
    filters: {
      years: '/api/transit/years',
      countries: '/api/transit/destinationCountries',
    },
    settings: '/api/configuration/transitByCountryAndYearChart',
    chartData: {
      chart: '/api/transit/byYearAndCountry'
    }
  },
  [MODULE_NAMES.TRANSIT_BY_YEAR]:{
    defaultFilters: '/api/filtersDefaults/transit/annualTransitByYear',
    filters: {
      years: '/api/transit/years'
    },
    settings: '/api/configuration/annualFertilizerTransitByYearChart',
    chartData: {
      chart: '/api/transit/annualTransitByYear'
    }
  },
  [MODULE_NAMES.EXPORTS_BY_YEAR]: {
    defaultFilters: '/api/filtersDefaults/exports/exportsByYear',
    filters: {
      products: '/api/exports/exportByYearProductsList',
      years: '/api/exports/yearsList',
    },
    chartData: {
      chart: '/api/exports/exportsByYear'
    },
    settings: '/api/configuration/fertilizerExportByYearChart'
  },
  [MODULE_NAMES.EXPORTS_BY_COUNTRY]: {
    defaultFilters: '/api/filtersDefaults/exports/exportsByCountry',
    filters: {
      products: '/api/exports/exportByCountryProductsList',
      years: '/api/exports/yearsList',
    },
    chartData: {
      chart: '/api/exports/exportsByCountry'
    },
    settings: '/api/configuration/totalFertilizerExportsByCountry'
  },
  [MODULE_NAMES.RAW_PRODUCTION_BY_YEAR_AND_ZONE]: {
    defaultFilters: '/api/filtersDefaults/npkProduction/byYearAndZone',
    filters: {
      zones: '/api/npkProduction/zoneList',
      products: '/api/npkProduction/productList',
      years: '/api/npkProduction/yearList',
    },
    chartData: {
      chart: '/api/npkProduction/dataByYearAndZone'
    },
    settings: '/api/configuration/rawNpkProductionByZoneChart'
  },
  [MODULE_NAMES.RAW_PRODUCTION_BY_STATE_AND_ZONE]: {
    defaultFilters: '/api/filtersDefaults/npkProduction/byStateAndZone',
    filters: {
      years: '/api/npkProduction/yearList',
    },
    chartData: {
      chart: '/api/npkProduction/dataByStateAndZone'
    },
    settings: '/api/configuration/rawNpkProductionByStateChart'
  },
  [MODULE_NAMES.RAW_PRODUCTION_BY_YEAR]: {
    defaultFilters: '/api/filtersDefaults/npkProduction/byYear',
    filters: {
      years: '/api/npkProduction/yearList',
      products: '/api/npkProduction/productList',
    },
    chartData: {
      chart: '/api/npkProduction/dataByYear'
    },
    settings: '/api/configuration/rawNpkProductionByYearChart'
  }
}

export const getDefaultFilters = (chart, country, selectedLanguage) => {
  return new Promise((resolve, reject) => {
    ApiUtils.getData(endpointMapping[chart].defaultFilters, {countryIso: country, selectedLanguage})
      .then(
        function(data) {
          resolve(data);
        }
      )
      .catch(function(err) {
        reject(err);
      });
  })
}

export const getFilterList = (chart, country, filter, selectedLanguage) => {
  return new Promise((resolve, reject) => {
    ApiUtils.getData(endpointMapping[chart].filters[filter], {countryIso: country, selectedLanguage})
      .then(
        function(data) {
          resolve(data);
        }
      )
      .catch(function(err) {
        reject(err);
      });
  })
}

export const postFilterList = (chart, country, filter, params, selectedLanguage) => {
  return new Promise((resolve, reject) => {
    Object.assign(params, {'countryIso': country, selectedLanguage})
    ApiUtils.postData(endpointMapping[chart].filters[filter], params)
      .then(
        function(data) {
          resolve(data);
        }
      )
      .catch(function(err) {
        reject(err);
      });
  })
}

export const getChartData = (url, country, params, languageSelected) => {
  return new Promise((resolve, reject) => {
    Object.assign(params, {'countryIso': country, 'lang': languageSelected})
    ApiUtils.postData(url, params)
      .then(
        function(data) {
          resolve(data);
        }
      )
      .catch(function(err) {
        reject(err);
      });
  })
}

export const getDefaultSettings = (chart, country) => {
  return new Promise((resolve, reject) => {
    ApiUtils.getData(endpointMapping[chart].settings, {countryIso: country})
      .then(
        function(data) {
          resolve(data);
        }
      )
      .catch((err) => {
        reject(err);
      });
  })
}


