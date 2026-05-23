export const base = 'https://admin.vifaakenya.org/api'

export const endpoints = {
  cost: {
    years: '/cost/years?countryIso=KE',
    transportTowns: '/cost/transportTowns?countryIso=KE',
  },
  consumption: {
    years: '/consumption/years?countryIso=KE',
  },
  imports: {
    productsList: '/imports/productslist?countryIso=KE',
    datesList: '/imports/dateslist?countryIso=KE',
  },
  subsidized: {
    years: '/subsidized/years?countryIso=KE',
  },
  configuration: {
    cbuChart: '/configuration/cbuChart?countryIso=KE',
  },
  settings: {
    subsidyChart: '/settings/subsidyChart?countryIso=KE',
  },

}
