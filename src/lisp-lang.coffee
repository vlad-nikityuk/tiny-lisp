isEmpty = (arr) -> Array.isArray(arr) and arr.length == 0
tokenize = (program) ->
  program
    .replace(/\'([\-\w\d\.\*\:\?\!]+|\([\-\s\w\d\.\*\:\?\!]*\))/g, "(quote $1)")
    .replace(/;.*\n/g, "").replace(/[\n\t]/g, " ")
    .replace(/\(/g, " ( ").replace(/\)/g, " ) ")
    .split(" ").filter (x) -> !!x
parse = (tokens) ->
  return if isEmpty tokens
  atom = (val) ->
    num = parseFloat(val)
    (if isNaN(num) then val else num)
  first = tokens.shift()
  result_list = []
  throw new Error("Syntax error, closing parenthesis at the beginning of the expression") if first is ")"
  if first is "("
    result_list.push parse(tokens) while tokens[0] isnt ")" and tokens.length != 0
    tokens.shift()
    result_list
  else
    atom first
createScope = (parent, init) ->
  locals = init or {}
  _sc = (name, val) ->
    if not name? then locals
    else if name? and not val?
      if name of locals then locals[name]
      else if parent? then parent(name)
    else if name? and val?
      locals[name] = val
  _sc.root = -> if parent? then parent.root() else _sc
  _sc.find = (name) -> if locals[name]? then _sc else if parent? then parent.find(name)
  _sc
inMacro = false
_eval = (ast, scope) ->
  str = -> scope node
  sym = -> node
  quote = -> node[1]
  _if = ->
    [_, test, conseq, alt] = node
    (if _eval(test, scope) then _eval(conseq, scope) else _eval(alt, scope))
  define = ->
    [_, name, expr] = node
    scope(name, _eval(expr, scope))
  set = ->
    [_, name, expr] = node
    scope.find(name)?(name, _eval(expr, scope))
  lambda = ->
    [_, params, body] = node
    ((args...) ->
      subScope = createScope scope
      args.forEach (arg, i) ->
        subScope params[i], arg
      _eval body, subScope)
  begin = ->
    (lastValue = _eval(exp, scope) for exp in node[1..])
    lastValue
  fn = ->
    proc = _eval(node[0], scope)
    args = node[1..].map((arg) -> _eval(arg, scope))
    throw new Error('Function ' + node[0] + ' is not defined') if not proc?
    proc.apply null, args
  node = ast
  rootScope = scope.root()
  unless inMacro
    (inMacro=true;node=(rootScope(m)(node) or node);inMacro=false) \
     for m in Object.keys(rootScope()) when m.indexOf("macro/") is 0
  if (typeof node is "string") then str()
  else if not Array.isArray(node) then sym()
  else
    switch node[0]
      when 'quote' then quote()
      when 'if' then _if()
      when 'define' then define()
      when 'set!' then set()
      when 'lambda' then lambda()
      when 'begin' then begin()
      else fn()
@exports = @exports or {}
exports.evaluate = (program, scope) -> _eval parse(tokenize(program)), scope
exports.topLevel = ->
  initial =
    "nil": null, "#t": true, "#f": false
    "eq?": (els...) -> els.map((el) -> if isEmpty el then null else el).reduce ((acc,el,i,a) -> (el is a[0]) && acc), true
    "car": (lst) -> (lst or [])[0]
    "cdr": (lst) -> (lst or [])[1..]
    "len": (lst) -> (lst or []).length
    "cons": (v, lst) -> [v].concat(lst or [])
    "list": (els...) -> els
    "error": (msg) -> throw Error(msg)
    "try": (fn, fail) -> try return fn() catch e then return fail(e)
    "js/eval": (prg) -> @eval(prg)
    "bind": (f, args...) -> args = Function::bind.apply(f, args)
    "trampoline": (f) -> f = f.apply(f.context, f.args) while f? instanceof Function; f
  (initial[op] = new Function("return Array.prototype.slice.call(arguments,1).reduce(function(x,a){return x "+op+" a;},arguments[0]);")\
   for op in ['+','-','/','>','<','>=','<=','&&','||'])
  createScope null, initial
