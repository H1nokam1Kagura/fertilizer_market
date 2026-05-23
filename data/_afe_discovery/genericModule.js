import {MODULE_ACTIONS} from "./moduleConstants";
import * as apiConnector from "./apiConnector";
import {isNumber, isObject} from "@turf/turf";
import {cloneData} from "../utils/dataUtils";
import {getText} from "../utils/translationsUtil";

export const getActions = (actions, country, page, moduleName) => {
  Object.assign(actions, {
    loadLocalFilterData: (filter, data) => {
      return (dispatch, getState) => {
        dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_SUCCESS}`, data, filter});
      }
    },
    loadDefaultFilters: () => {
      return (dispatch, getState) => {
        if (!getState().getIn([`${country}_${page}_${moduleName}`, 'defaultFilters'])) {
          dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DEFAULT_FILTERS_REQUEST}`});
          const selectedLanguage = getState().getIn(['main', 'selectedLanguage']);
          const translationData = getState().getIn(['main', 'translationData']).toJS().data;
          apiConnector.getDefaultFilters(moduleName, country, selectedLanguage).then(filters => {
            Object.entries(filters).forEach(([filter, value]) => {
              let vclone = cloneData(value);
              dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_FILTER_VALUE}`, filter, value: vclone});
              if (filter === 'unit') { //if unit changes, it force to change the currency value
                dispatch({
                  'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_FILTER_VALUE}`,
                  filter: 'currencyCode',
                  value: vclone.split('_')[0]
                });
              }
            });
            dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DEFAULT_FILTERS_SUCCESS}`, filters});
          }).catch(function (err) {
            console.log(err);
            dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DEFAULT_FILTERS_FAILURE}`,
              err: getText('general:errorLoadingDefaultFilters', {selectedLanguage, translationData})});
          })
        }
      }
    },
    loadFilterData: (filter, usePost) => {
      if (usePost) {
        return (dispatch, getState) => {
          const selectedLanguage = getState().getIn(['main', 'selectedLanguage']);
          const translationData = getState().getIn(['main', 'translationData']).toJS().data;
          dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_REQUEST}`, filter});
          const params = getState().getIn([`${country}_${page}_${moduleName}`, 'filtersSelections']).toJS();
          apiConnector.postFilterList(moduleName, country, filter, params, selectedLanguage).then(data => {
            dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_SUCCESS}`, data, filter});
          }).catch(function (err) {
            console.log(err);
            dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_FAILURE}`, filter,
              err: `${getText('general:errorLoadingFilterList', {selectedLanguage, translationData})} (${filter})`});
          })
        }
      } else {
        return (dispatch, getState) => {
          const selectedLanguage = getState().getIn(['main', 'selectedLanguage']);
          const translationData = getState().getIn(['main', 'translationData']).toJS().data;
          dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_REQUEST}`, filter});
          apiConnector.getFilterList(moduleName, country, filter, selectedLanguage).then(data => {
            dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_SUCCESS}`, data, filter});
          }).catch(function (err) {
            console.log(err);
            dispatch({'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_FAILURE}`, filter,
              err: `${getText('general:errorLoadingFilterList', {selectedLanguage, translationData})} (${filter})`});
          })
        }
      }
    },
    loadChartData: (state) => {
      return (dispatch, getState) => {
        state = state || getState();
        const selectedLanguage = getState().getIn(['main', 'selectedLanguage']);
        const translationData = getState().getIn(['main', 'translationData']).toJS().data;
        Object.entries(apiConnector.endpointMapping[moduleName].chartData).forEach(([chart, url]) => {
          dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DATA_REQUEST}`, chart });
          const params = actions.customizeParams(state.getIn([`${country}_${page}_${moduleName}`, 'filtersSelections']).toJS(), chart);
          apiConnector.getChartData(url, country, params, selectedLanguage).then(data => {
            const convertedData = actions.convertData(data, chart, getState().get(`${country}_${page}_${moduleName}`), selectedLanguage);
            dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DATA_SUCCESS}`, chart, data, convertedData });
          }).catch(function(err) {
            console.log(err);
            dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DATA_FAILURE}`, chart,
              err: getText('general:errorLoadingChartData', {selectedLanguage, translationData})});
          })
        })
      }
    },
    loadDefaultSettings: () => {
      return (dispatch, getState) => {
        const selectedLanguage = getState() .getIn(['main', 'selectedLanguage']);
        const translationData = getState().getIn(['main', 'translationData']).toJS().data;
        dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_SETTINGS_REQUEST}` });
        apiConnector.getDefaultSettings(moduleName, country).then(data => {
          dispatch(actions.setDefaultSettings(data, getState()));
          dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_SETTINGS_SUCCESS}`, data});
          if(data.defaultPresentationType) {
            dispatch(actions.changeView(data.defaultPresentationType.code));
          }
        }).catch(function(err) {
          console.log(err);
          dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_SETTINGS_FAILURE}`,
            err: getText('general:errorLoadingChartConfiguration', {selectedLanguage, translationData})});
        })
      }
    },
    changeFilterValue: (filter, value, reload) => {
      return (dispatch, getState) => {
        dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_FILTER_VALUE}`, filter, value });
        if (reload) {
          dispatch(actions.loadChartData(getState()));
        }
      }
    },
    changeTimePeriod: (timePeriod) => {
      return (dispatch, getState) => {
        dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_TIME_PERIOD}`, timePeriod });
      }
    },
    changeView: (view) => {
      return (dispatch, getState) => {
        dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_VIEW}`, view });
      }
    },
    setDefaultSettings: (settings) => {
      return (dispatch, getState) => {
      }
    },
    getFiltersForPrint: (settings) => {
      return (dispatch, getState) => {
        return [];
      }
    },
    createExportData: (settings) => {
      return (dispatch, getState) => {
      }
    },
    convertData: (data, chart, state) => {
      return data
    },
    customizeParams: (params, chart) => {
      return params
    },
    resetFilters: () => {
      return (dispatch, getState) => {
        const filters = getState().getIn([`${country}_${page}_${moduleName}`, 'defaultFilters']);
        Object.entries(filters).forEach(([filter, value]) => {
          dispatch({ 'type': `${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_FILTER_VALUE}`, filter, value: cloneData(value)});
        });
        const settings = getState().getIn([`${country}_${page}_${moduleName}`, 'defaultSettings', 'data']);
        dispatch(actions.setDefaultSettings(settings));
        dispatch(actions.loadChartData(getState()));
      }
    }
  });
}

export const  getActionHandlers = (country, page, moduleName) => {
  return {
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DEFAULT_FILTERS_REQUEST}`]: (state, action) => {
      return state.setIn(['defaultFilters', 'loading'], true);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DEFAULT_FILTERS_SUCCESS}`]: (state, action) => {
      const {filters} = action;
      state = state.setIn(['defaultFilters'], filters);
      return state
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DEFAULT_FILTERS_FAILURE}`]: (state, action) => {
      const {err} = action;
      return state.setIn(['defaultFilters', 'loading'], false).setIn(['loadingError'], err);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_SUCCESS}`]: (state, action) => {
      const {data, filter} = action;
      data.forEach(d => {
        if (isObject(d) && !d.name) {
          d.name = d.label;
        }
      })
      state = state.setIn(['filtersData', filter, 'loaded'], true).setIn(['filtersData', filter, 'data'], data);
      return state
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_FILTER_FAILURE}`]: (state, action) => {
      const {err} = action;
      return state.setIn(['loadingError'], err);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DATA_REQUEST}`]: (state, action) => {
      const {chart} = action;
      return state.setIn(['chartData', chart, 'loading'], true);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DATA_SUCCESS}`]: (state, action) => {
      const {data, chart, convertedData} = action;
      return state.setIn(['chartData', chart, 'data'], data)
        .setIn(['chartData', chart, 'convertedData'], convertedData)
        .setIn(['chartData', chart, 'loading'], false).setIn(['chartData', chart, 'loaded'], true);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_DATA_FAILURE}`]: (state, action) => {
      const {err, chart} = action;
      return state.setIn(['chartData', chart, 'loading'], false).setIn(['loadingError'], err);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_SETTINGS_REQUEST}`]: (state, action) => {
      return state.setIn(['defaultSettings', 'loading'], true);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_SETTINGS_SUCCESS}`]: (state, action) => {
      const {data} = action;
      return state.setIn(['defaultSettings', 'loaded'], true).setIn(['defaultSettings', 'data'], data);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.LOAD_SETTINGS_FAILURE}`]: (state, action) => {
      const {err} = action;
      return state.setIn(['defaultSettings', 'loading'], false).setIn(['loadingError'], err);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_FILTER_VALUE}`]: (state, action) => {
      const {filter, value} = action;
      if (filter === 'unit' && typeof value === 'string' && value.indexOf('_') !== -1) { //if unit changes, force to change the currency value
        state = state.setIn(['filtersSelections', 'currencyCode'], value.split('_')[0]);
      }
      return state.setIn(['filtersSelections', filter], value);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_TIME_PERIOD}`]: (state, action) => {
      const {timePeriod} = action;
      return state.setIn(['timePeriod'], timePeriod);
    },
    [`${country}_${page}_${moduleName}_${MODULE_ACTIONS.CHANGE_VIEW}`]: (state, action) => {
      const {view} = action;
      return state.setIn(['view'], view);
    }
  }
}
