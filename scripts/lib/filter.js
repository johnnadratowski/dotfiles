#!/usr/bin/env node
const fs = require('fs')
const readline = require('readline')

function exitError(msg) {
  console.error("\n\nERROR:\n\n" + msg)
  process.exit(1)
}

function help() {
  console.log("Takes data from stdin or a file, assumes it to be JSON data, and can use javascript functions to filter/map it.")
  console.log("")
  console.log("ARGS:")
  console.log("")
  console.log("\t-l, --per-line              -   Assume it to be a JSON object per line.")
  console.log("\t-s, --string                -   Assume it to be a (non-json) string.")
  console.log("\t-v, --val  x=(x) -> x > 3   -   Add a variable that will be ")
  console.log("                                  available in the filter.")
  console.log("")
  console.log("EXAMPLES:")
  console.log("")
  console.log("cat foo.json | f '.items.filter(o.name == \"Jim\")")
  console.log("// This will output all items in teh top level json object with the name Jim")
}

let __outputPerLine = false
let __perLine = false
let __string = false
let __filter
let __file = 0
for (let i = 2; i < process.argv.length; i++) {
  const cur = process.argv[i]
  switch (cur) {
    case '-l':
    case '--per-line':
      __perLine = true
      break
    case '-s':
    case '--string':
      __string = true
      break
    case '-o':
    case '--output-per-line':
      __outputPerLine = true
      break
    case '-v':
    case '--val':
      break
    case '-h':
    case '--help':
      help()
      process.exit(0)
    default:
      const prev = i >= 2 ? process.argv[i-1] : null;
      if ( prev == "-v" || prev == "--val" ) {
        [key, ...rest] = cur.split("=")
        eval(`${key} = ${rest.join('=')}`)
      } else if (!__filter) {
        __filter = cur.trim()
      } else {
        __file = cur.trim()
      }
      break
  }
}

if (!__filter) exitError("Must provide filter arg")

function run(data) {
  let $ = __string ? data : JSON.parse(data)
  eval(`$ = ${__filter.startsWith('.') ? '$' : ''}${__filter}`)
  return $
}

function output(data) {
  console.log(JSON.stringify(data, null, 2))
}

if (__perLine) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
  })

  const all = []
  rl.on('line', function(data){
      if (__outputPerLine) {
        output(run(data))
      } else {
        all.push(run(data))
      }
  })
  rl.on('close', function() {
    if (!__outputPerLine) output(all)
  })

} else {
  const data = fs.readFileSync(__file, 'utf-8')

  if (!data) exitError("No data to process")

  const $ = run(data)
  if (__outputPerLine && Array.isArray($)) {
    $.forEach(o => output(o))
  } else {
    output($)
  }
}

