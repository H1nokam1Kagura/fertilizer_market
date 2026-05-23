import { createApp } from 'vue'
import App from './App.vue'
import './index.css'

createApp(App).mount('#app')

// fetch(
//   'https://admin.vifaakenya.org/api/cost/cbu',
//   {
//     method: 'post',
//     body: JSON.stringify({"productOriginSelected":"318-22055","townSelected":186301,"yearSelected":2020,"categoriesSelected":[],"years":[2020],"unit":"USD_MT","currencyCode":"USD","countryIso":"KE"}),
//     headers: { 'Accept': 'application/json', 'Content-Type': 'application/json' },
//   }
// )
//   .then(response => 
//     response.json()
//       .then(json => console.log(json))
//       .catch(error => console.log(error))
//   )
//   .catch(error => console.log(error))
