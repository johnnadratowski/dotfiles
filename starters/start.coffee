#!/usr/bin/env coffee
require('../lib/js/ld.coffee')
fs = require 'fs'
path = require 'path'

templateFile = (input, output, conf) ->
  fs.openSync(output, 'wx').write(
    fs.readFileSync(input, 'utf8').split('\n').map((line) ->
      line = line.replace("%#{item}%", val) for item, val of conf
      line
    ).join('\n'))

walk = (inDir, outDir, conf) ->
  fs.mkdirSync(outDir)
  for node in fs.readdirSync(inDir)
    node = path.join(inDir, node)
    newNode = path.join(outDir, node)
    stat = fs.statSync(inDir)
    if stat.isDirectory()
      walk node newNode conf
    else if stat.isFile()
      templateFile node newNode conf
    else
      fs.copyFileSync node newNode

if process.argv.length < 3
  throw new Error "NOT ENOUGH ARGS"

walk path.join(process.cwd, process.argv[2]) process.argv[3]