lodash = require('./lodash')

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
    "object"
    "range"
    "rest"
    "sortedIndex"
    "tail"
    "take"
    "union"
    "uniq"
    "unique"
    "unzip"
    "without"
    "zip"
    "zipObject"
  ]
  collection: [
    "all"
    "any"
    "at"
    "collect"
    "contains"
    "countBy"
    "detect"
    "each"
    "every"
    "filter"
    "find"
    "findWhere"
    "foldl"
    "foldr"
    "forEach"
    "groupBy"
    "include"
    "inject"
    "invoke"
    "map"
    "max"
    "min"
    "pluck"
    "reduce"
    "reduceRight"
    "reject"
    "select"
    "shuffle"
    "size"
    "some"
    "sortBy"
    "toArray"
    "where"
  ]
  function: [
    "after"
    "bind"
    "bindAll"
    "bindKey"
    "compose"
    "createCallback"
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
    "methods"
    "omit"
    "pairs"
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

for type, fnNames of extensions
  for ctor in mapping[type]
    for fnName of fnNames
      if not ctor::[fnName]
        ctor::[fnName] = lodash[fnName]
