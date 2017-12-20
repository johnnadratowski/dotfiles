global.lodash = lodash = require('./lodash')
global.alasql = alasql = require('alasql')

extensions =
  array: [
    "compact"
    "difference"
    "drop"
    "findIndex"
    "first"
    "flatten"
    "head"
    "indexOf"
    "initial"
    "intersection"
    "last"
    "lastIndexOf"
    "range"
    "rest"
    "sortedIndex"
    "tail"
    "take"
    "union"
    "uniq"
    "unzip"
    "without"
    "zip"
    "zipObject"
  ]
  collection: [
    "at"
    "countBy"
    "each"
    "every"
    "filter"
    "find"
    "forEach"
    "groupBy"
    "invoke"
    "map"
    "max"
    "min"
    "reduce"
    "reduceRight"
    "reject"
    "shuffle"
    "size"
    "some"
    "sortBy"
    "toArray"
  ]
  function: [
    "after"
    "bind"
    "bindAll"
    "bindKey"
    "debounce"
    "defer"
    "delay"
    "memoize"
    "once"
    "partial"
    "partialRight"
    "throttle"
    "wrap"
  ]
  object: [
    "assign"
    "clone"
    "cloneDeep"
    "defaults"
    "extend"
    "findKey"
    "forIn"
    "forOwn"
    "functions"
    "has"
    "invert"
    "isArguments"
    "isArray"
    "isBoolean"
    "isDate"
    "isElement"
    "isEmpty"
    "isEqual"
    "isFinite"
    "isFunction"
    "isNaN"
    "isNull"
    "isNumber"
    "isObject"
    "isPlainObject"
    "isRegExp"
    "isString"
    "isUndefined"
    "keys"
    "merge"
    "omit"
    "pick"
    "transform"
    "values"
    "identity"
    "result"
  ]
  string: [
    "escape"
    "parseInt"
    "template"
    "unescape"
    "uniqueId"
  ]
  number: [
    "times"
  ]

mapping =
  array: [Array]
  collection: [Array, Object, String]
  function: [Function]
  object: [Object]
  string: [String]
  number: [Number]

ld = (name) ->
  f = lodash[name]
  if not f
    console.log("UNDEFINED", name)

  ->
    args = new Array (arguments.length)
    args = (v for v in arguments)
    f(this, ...args)


for type, fnNames of extensions
  for ctor in mapping[type]
    ext = {}
    for fnName in fnNames
      if not ctor::[fnName]
        ext[fnName] = ld(fnName)
      else if not ctor::["_#{fnName}"]
        ext["_#{fnName}"] = ld(fnName)
      else console.log type, fnName
    lodash.extend(ctor::, ext)
