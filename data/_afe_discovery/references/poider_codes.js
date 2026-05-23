const path = require('path')
const fs = require('fs')
const s = function () {
const data =  fs.readFileSync(path.join(__dirname,'CountriesCodes.json'))

let jsonData = JSON.parse(data)
jsonData = jsonData.map((item) => {
	return {
		id : item.id,
		name : item.name,
	}
})

fs.writeFileSync(path.join(__dirname, 'CountriesCodes.json'), JSON.stringify(jsonData,null,2))
}
// 'Carte interactive_Data _ LIFEMOZ _ OCPA.json'
s()