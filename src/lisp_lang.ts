const isEmpty = arr => Array.isArray(arr) && (arr.length === 0)
const tokenize = program => program
    .replace(/\'([\-\w\d\.\*\:\?\!]+|\([\-\s\w\d\.\*\:\?\!]*\))/g, "(quote $1)")
    .replace(/;;.*\n/g, "").replace(/[\n\t]/g, " ")
    .replace(/\(/g, " ( ").replace(/\)/g, " ) ")
    .match(/\".*?\"|[^\s]+/g).filter(x => !!x)
function parse(tokens) {
    if (isEmpty(tokens)) return
    function atom(val) {
        const num = parseFloat(val)
        return isNaN(num) ? val : num
    }
    const first = tokens.shift(), result_list = []
    if (first === ")") throw new Error("ToyLisp: Syntax error, closing parenthesis at the beginning of the expression")
    if (first === "(") {
        while ((tokens[0] !== ")") && (tokens.length !== 0)) {
            result_list.push(parse(tokens))
        }
        tokens.shift()
        return result_list
    } else return atom(first)
}
function createScope(parent, init?) {
    const locals = init || {}
    const _sc = (name, val) => (name == null) ? locals : (val == null) ? name in locals ? locals[name] : parent != null ? parent(name) : null : (locals[name] = val)
    _sc.root = () => parent != null ? parent.root() : _sc
    _sc.find = name => locals[name] != null ? _sc : parent != null ? parent.find(name) : null
    return _sc
}
let inMacro = false
function _eval(ast, scope) {
    let node
    const lit = () => typeof node === "string" ? node.slice(1, -1) : node
    const identifier = () => scope(node)
    const quote = () => node[1]
    const _if = () => _eval(node[1], scope) ? _eval(node[2], scope) : _eval(node[3], scope)
    const define = () => scope(node[1], _eval(node[2], scope))
    const set = () => scope.find(node[1])?.(node[1], _eval(node[2], scope))
    const lambda = () => (...args) => {
        const subScope = createScope(scope)
        args.forEach((arg, i) => subScope(node[1][i], arg))
        return _eval(node[2], subScope)
    }
    const begin = () => {
        let lastValue
        for (let exp of Array.from(node.slice(1))) lastValue = _eval(exp, scope)
        return lastValue
    }
    const fn = () => {
        const proc = _eval(node[0], scope), args = node.slice(1).map(arg => _eval(arg, scope))
        if ((proc == null)) throw new Error('ToyLisp: Function ' + node[0] + ' is not defined')
        return proc.apply(null, args)
    }
    node = ast
    const rootScope = scope.root()
    if (!inMacro) for (let m of Array.from(Object.keys(rootScope())))
        if (m.indexOf("macro/") === 0) { inMacro = true; node = (rootScope(m)(node) || node); inMacro = false }
    if ((typeof node === "string") && (node[0] !== '"')) return identifier()
    else if (!Array.isArray(node)) return lit()
    else switch (node[0]) {
        case 'quote': return quote()
        case 'if': return _if()
        case 'define': return define()
        case 'set!': return set()
        case 'lambda': return lambda()
        case 'begin': return begin()
        default: return fn()
    }
}
export function evaluate(program, scope) { return _eval(parse(tokenize(program)), scope)}
export function topLevel() {
    const initial = {
        "nil": null, "#t": true, "#f": false,
        "eq?"(...els) { return els.map(el => isEmpty(el) ? null : el).reduce(((acc, el, i, a) => (el === a[0]) && acc), true) },
        "car"(lst) { return (lst || [])[0] },
        "cdr"(lst) { return (lst || []).slice(1) },
        "len"(lst) { return (lst || []).length },
        "cons"(v, lst) { return [v].concat(lst || []) },
        "list"(...els) { return els },
        "error"(msg) { throw Error(msg) },
        "try"(fn, fail) { try { return fn() } catch (e) { return fail(e) }},
        "js/eval"(prg) { return global.eval(prg) },
        "js/bind"(f, args) { return Function.prototype.bind.apply(f, args) },
        "trampoline": f => (...args) => {
            let result = f.bind(null, ...args)
            while (typeof result === 'function') result = result()
            return result
        }
    }
    for (let op of ['+', '-', '/', '>', '<', '>=', '<=', '&&', '||']) {
        initial[op] = new Function("return Array.prototype.slice.call(arguments,1).reduce(function(x,a){return x " + op + " a;},arguments[0]);")
    }
    return createScope(null, initial)
}
