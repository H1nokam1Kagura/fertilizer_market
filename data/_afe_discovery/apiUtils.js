import Axios from 'axios';
import Qs from 'qs';
export const API_ROOT_URL = process.env.REACT_APP_ADMIN_URL ? process.env.REACT_APP_ADMIN_URL: 'http://localhost:8090';
export const WP_ROOT_URL = process.env.REACT_APP_UTIL_API ? process.env.REACT_APP_UTIL_API: 'https://wp.africafertilizer.org';
export const WATCH_URL = process.env.REACT_APP_WATCH_API ? process.env.REACT_APP_WATCH_API: 'https://api.marketwatch.dgstg.org';

export default class ApiUtils {

  static getData = (endpoint, params = {}, headers = {}, url) => {
    return new Promise(
      function (resolve, reject) {
        Axios.get(`${url || API_ROOT_URL}${endpoint}`, {
            responseType: 'json',
            params: params,
            paramsSerializer: function (params) {
                return Qs.stringify(params, {arrayFormat: 'repeat'})
            },
            headers: headers
          })
          .then(function (response) {
            if (response.status === 200 && response.data) {
              resolve(response.data);
            } else {
              reject(`failed to load ${url || API_ROOT_URL}${endpoint}`);
            }
          })
          .catch(function (response) {
            reject(response);
          });
      });
  }

  static postData = (endpoint, data = {}, headers = {}, url) => {
    const finalUrl = `${url || API_ROOT_URL}${endpoint}`;
    return new Promise(
      function (resolve, reject) {
        Axios.post(finalUrl, data, {headers: headers})
          .then(function (response) {
            if (response.status === 200 && response.data) {
              resolve(response.data);
            } else {
              reject(`failed to load ${finalUrl}`);
            }
          })
          .catch(function (response) {
            reject(response);
          });
      });
  }
}