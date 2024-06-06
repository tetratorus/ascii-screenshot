var express = require('express')
var app = express()
// public folder for static files
app.use(express.static('public'))
app.listen(3333)
