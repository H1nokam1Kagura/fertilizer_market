# Sample data in the provided format
data = {
   "Kenya": 
		{
			"Fertilizer Price Data": [	"Fertilizer Cost Build-up by Year",
										"Fertilizer Retail Price",
										"Evolution of Retail Price Over Time",
										"Monthly International Price",
										"Quarterly International and Kenya Retail Price Trends"],

			"Fertilizer use" : [	"Apparent Fertilizer Consumption",
									"National Cropland under Production",
									"Top Fertilizer-Consuming Crops",
									"Fertilizer Use by Crop",
									"National Average Fertilizer Consumption"],

			"Fertilizer Availability": [	"Fertilizer Imports by Product",
											"Monthly Fertilizer Imports by Product type",
											"Total Fertilizer Imports by Year",
											"Imports by Country of Origin and Year",
											"Imports by Country of Origin and Product"],

			"Fertilizer Policy": [	"Evolution of Fertilizer Subsidy",
									"Historical Annual Subsidized Fertilizer Imports",
									"Annual Subsidy Coverage"],

		},
"Nigeria": 
		{
			"Fertilizer Price Data": [	"Fertilizer cost build-up by year",
										"Fertilizer Retail Price",
										"Evolution of Retail Price Over Time",
										"Monthly International Price",
										"Quarterly International and Retail Price Trends"],

			"Fertilizer use" : [	"Apparent Fertilizer Consumption",
									"Domestic Urea Consumption Over Time",
									"National Cropland Under Production",
									"National Average Apparent Fertilizer Consumption - by Nutrient Ton",
									"National Average Fertilizer Consumption - by Product Ton"],

			"Fertilizer Availability": [	"Fertilizer Imports by Product",
											"Total Fertilizer Imports by Year",
											"Urea Export by Destination Country",
											"Imports by Country of Origin and Year",
											"Import by Country of Origin and Product"],

			"Plant Directory": ["Fertilizer Plant Directory"],

		},
"Ghana": 
		{
			"Fertilizer Price Data": [	"Fertilizer Retail Price Map",
										"Fertilizer Retail Price",
										"Evolution of Commercial Price Vs Subsidized Price Over Time",
										"Comparison of Commercial and Subsidized Prices at the Retail Level",
										"Monthly International Price",
										"Quarterly International and Retail Price Trends"],

			"Fertilizer use" : [	"Apparent Fertilizer Consumption",
									"National Cropland under Production",
									"National Average Apparent Fertilizer Consumption - by Nutrient Ton",
									"National Average Fertilizer Consumption - by Product Ton"],

			"Fertilizer Availability": [	"Fertilizer Imports by Product",
											"Total Fertilizer Imports by Year",
											"Imports by Country of Origin and Year",
											"Import by Country of Origin and Product"],

			"Fertilizer Policy": ["Fertilizer Plant Directory"],

			"Fertilizer Policy": ["Annual Government Contribution to Subsidy Price by Product"]

		},
"Senegal": 
		{
			"Fertilizer Price Data": ["Fertilizer Retail Price",
									  "Evolution of Retail Price Over Time",
									  "3-Months Comparison of Commercial and Subsidized Prices",
									  " Monthly International Price",
									  "Quarterly International and Retail Price Trends"],

			"Fertilizer use" : 	["Apparent Fertilizer Consumption",
								"National Average Fertilizer Consumption - by Nutrient Ton"],

			"Fertilizer Availability": [ "Annual Fertilizer Imports by Product",
										 "Imports by Country of Origin and Year.",
										 "Import by Country of Origin and Product"],

			"Plant Directory": ["Fertilizer Plant Directory"],

		},
"Zambia": 
		{
			"Fertilizer Price Data": [  "Fertilizer Retail Price",
										"Evolution of Retail Price Over Time",
										"Monthly International Price",
										"Quarterly International and Retail Price Trends"],

			"Fertilizer use" : ["Apparent Fertilizer Consumption",
								"National Average Fertilizer Consumption"],

			"Fertilizer Availability": ["Annual Fertilizer Imports by Product",
										"Total Fertilizer Imports by Year",
										"Imports by Country of Origin and Year.",
										"Imports by Country of Origin and Product"],

			"Plant Directory": ["Fertilizer Plant Directory"],

		},
"Malawi": 
		{
			"Fertilizer Price Data": [	"Fertilizer Retail Price",
										"Evolution of Retail Price Over Time",
										"Monthly International Price",
										"Quarterly International and Retail Price Trends"],

			"Fertilizer use" : ["Apparent Fertilizer Consumption",
								"National Average Fertilizer Consumption"],

			"Fertilizer Availability": ["Monthly Fertilizer Imports by Product",
										"Total Fertilizer Imports by Year",
										"Imports by Country of Origin and Year",
										"Imports by Country of Origin and Product"],

			"Plant Directory": ["Fertilizer Plant Directory"],

		},
"Mozambique": 
		{
			"Fertilizer Price Data": [	"Fertilizer Retail Price",
										"Evolution of Retail Price Over Time",
										"Monthly International Price",
										"Quarterly International and Retail Price Trends"],

			"Fertilizer use" : ["Apparent Fertilizer Consumption"],

			"Fertilizer Availability": [	"Fertilizer Imports by Product",
											"Total Fertilizer Imports by Year",
											"Imports by Source Country and Year",
											"Imports by Source Country"],

			"Plant Directory": ["Fertilizer Plant Directory"],

		},
"Ethiopia": 
		{
			"Fertilizer Price Data": [	"Fertilizer Retail Price",
										"Evolution of Retail Price Over Time",
										"Monthly International Price",
										"Quarterly International and Retail Price Trends"],

			"Fertilizer use" : ["Apparent Fertilizer Consumption",
								"National Average Fertilizer Consumption"],

			"Fertilizer Availability": ["Fertilizer Imports by Product",
										"Total Fertilizer Imports by Year",
										"Imports by Country of Origin and Year",
										"Imports by Country of Origin and Product"],

			"Plant Directory": ["Fertilizer Plant Directory"],

		}

}

unique_data = set()


for country_data in data.values():
    for category_data in country_data.values():
        unique_data.update(category_data)

unique_data_list = list(unique_data)

print(unique_data_list)
