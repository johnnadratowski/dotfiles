require('./all.coffee')
# alasql = require('alasql')
a = alasql
      .promise('SELECT * FROM CSV("/Users/johnnadratowski/Downloads/john.csv")')
      .then((data) ->
            console.dir(data))
      .catch((err) -> console.log("ERROR", err))
