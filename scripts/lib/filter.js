#!/usr/bin/env node
const fs = require('fs')

function exitError(msg) {
  console.error("\n\nERROR:\n\n" + msg)
  process.exit(1)
}

function help() {
  console.log("Takes data from stdin or a file, assumes it to be JSON data, and can use javascript functions to filter/map it.")
  console.log("");
  console.log("ARGS:");
  console.log("");
  console.log("\t-l, --per-line   -   Assume it to be a JSON object per line.");
  console.log("");
  console.log("EXAMPLES:");
  console.log("");
  console.log("cat foo.json | ./f.js '.items.filter(o.name == \"Jim\")");
  console.log("// This will output all items in teh top level json object with the name Jim");
}

function getFilters(cur) {
  cur = cur.trim()
  if (!cur) return []
  // cur.split('.').map(j => j.trim()).filter(j => !!j)
  let cursor = 0
  if (cur[0] === '.') {
    cursor++
  }

  let part = ''
  let paramLevel = 0
  let inString = false
  for (; cursor < cur.length; cursor++) {
    const next = cur[cursor]
    if (next === '.' && !inString && paramLevel === 0) {
        break
    }

    switch (next) {
      case '(':
        if (!inString) {
          paramLevel++
        }
        break
      case ')':
        if (!inString) {
          paramLevel--
        }
        break
      case "'":
      case '"':
      case '`':
        if (!inString) {
          inString = next
        } else if (inString === next) {
          inString = false
        }

        break
    }
    part += next
  }

  if (!part) exitError("Invalid syntax for filter")
  if (paramLevel > 0) exitError("Invalid param syntax for filter")

  const nextParen = part.indexOf('(')
  let func = null
  if (nextParen > -1) {
    func = o => eval('o.' + part)
  } else {
    func = o => {
      if (Array.isArray(o)) {
        return o.map(i => {
          if (!i[part]) {
            exitError(`Filter ${part} is undefined on:\n\n${JSON.stringify(i, null, 2)}`)
          }
          return i[part]
        })
      } else {
        if (!o[part]) {
          exitError(`Filter ${part} is undefined\n\n${JSON.stringify(o, null, 2)}`)
        } 
        return o[part]
      }
    }
  }

  return [func].concat(getFilters(cur.substr(cursor)))
}

let perLine = false
let filters = null
let file = 0
for (let i = 2; i < process.argv.length; i++) {
  const cur = process.argv[i]
  switch (cur) {
    case '-l':
    case '--per-line':
      perLine = true
      break
    case '-h':
    case '--help':
      help()
      process.exit(0)
    default:
      if (!filters) {
        filters = getFilters(cur.trim())
      } else {
        file = cur
      }
      break
  }
}

if (!filters) exitError("Must provide filter arg")

const data = fs.readFileSync(file, 'utf-8')

if (!data) exitError("No data to process")

let objects
if (perLine) {
  objects = data.split('\n').map(j => j.trim()).filter(j => !!j).map(JSON.parse)
} else {
  objects = JSON.parse(data)
}

filters.forEach(f => {
  objects = f(objects)
})

console.log(JSON.stringify(objects, null, 2))

