#!/usr/bin/env node
const fs = require('fs')
const rl = require('readline')

function exitError(msg) {
  console.error("\n\nERROR:\n\n" + msg)
  process.exit(1)
}

function help() {
  console.log("Takes data from stdin or a file, assumes it to be JSON data, and can use javascript functions to filter/map it.")
  console.log("")
  console.log("ARGS:")
  console.log("")
  console.log("\t-l, --per-line   -   Assume it to be a JSON object per line.")
  console.log("\t-s, --string     -   Assume it to be a (non-json) string.")
  console.log("")
  console.log("EXAMPLES:")
  console.log("")
  console.log("cat foo.json | ./f.js '.items.filter(o.name == \"Jim\")")
  console.log("// This will output all items in teh top level json object with the name Jim")
}

let outputPerLine = false
let perLine = false
let string = false
let filter
let file = 0
for (let i = 2; i < process.argv.length; i++) {
  const cur = process.argv[i]
  switch (cur) {
    case '-l':
    case '--per-line':
      perLine = true
      break
    case '-s':
    case '--string':
      string = true
      break
    case '-o':
    case '--output-per-line':
      outputPerLine = true
      break
    case '-h':
    case '--help':
      help()
      process.exit(0)
    default:
      if (!filter) {
        filter = cur.trim()
      } else {
        file = cur.trim()
      }
      break
  }
}

if (!filter) exitError("Must provide filter arg")

function run(data) {
  let $ = string ? data : JSON.parse(data)
  eval(`$ = ${filter.startsWith('.') ? '$' : ''}${filter}`)
  return $
}

function output(data) {
  console.log(JSON.stringify(data, null, 2))
}

if (perLine) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
  })

  const all = []
  rl.on('line', function(data){
      eval(filter)
      if (outputPerLine) {
        output(run(data))
      } else {
        all.push(run(data))
      }
  })
  rl.on('close', function() {
    if (!outputPerLine) output(all)
  })

} else {
  const data = fs.readFileSync(file, 'utf-8')

  if (!data) exitError("No data to process")

  const $ = run(data)
  if (outputPerLine && Array.isArray($)) {
    $.forEach(o => output(o))
  } else {
    output($)
  }
}

