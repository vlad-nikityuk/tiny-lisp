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
function _evalRec(node, scope, cont) {
    const rootScope = scope.root()
    if (!inMacro)
        for (let m of Array.from(Object.keys(rootScope())))
            if (m.indexOf("macro/") === 0) {
                inMacro = true;
                node = (rootScope(m)(node) || node);
                inMacro = false
            }

    if ((typeof node === "string") && (node[0] !== '"')) {
        return cont(scope(node))
    }
    else if (!Array.isArray(node)) {
        return cont(typeof node === "string" ? node.slice(1, -1) : node)
    }
    else switch (node[0]) {
        case 'quote': {
            return cont(node[1])
        }
        case 'if': {
            return _evalRec(node[1], scope, cond => cond
                    ? _evalRec(node[2], scope, cont)
                    : _evalRec(node[3], scope, cont)
            )
        }
        case 'define': {
            return _evalRec(node[2], scope, x => {
                scope(node[1], x)
                return cont()
            })
        }
        case 'set!': {
            return _evalRec(node[2], scope, x => {
                scope.find(node[1])?.(node[1], x)
                return cont()
            })
        }
        case 'lambda': {
            return cont((...args) => {
                const subScope = createScope(scope)
                args.forEach((arg, i) => subScope(node[1][i], arg))
                var r = _evalRec(node[2], subScope, x => x)
                return r
            })
        }
        case 'begin': {
            var ops = Array.from(node.slice(1));
            if (ops.length > 0) {
                var funcs = ops.map((v, i, _) => () => _evalRec(v, scope, funcs[i+1]));
                funcs[funcs.length - 1] = () => _evalRec(ops[funcs.length - 1], scope, x => {
                    return cont(x)
                })
                return funcs[0]()
            }
            return cont()
        }
        default: {
            return _evalRec(node[0], scope, proc => {
                if ((proc == null)) throw new Error('ToyLisp: Function ' + node[0] + ' is not defined')
                var argsExprs = node.slice(1)
                if (argsExprs.length > 0) {
                    var args = argsExprs.map(_ => null)
                    var funcs = argsExprs.map((v, i, _) => () => _evalRec(v, scope, r => {
                        args[i] = r
                        return funcs[i+1]();
                    }));
                    funcs[funcs.length - 1] = () => _evalRec(argsExprs[argsExprs.length - 1], scope, r => {
                        args[argsExprs.length - 1] = r
                        var res = proc.apply(null, args);
                        return cont(res);
                    });
                    return funcs[0]()
                }

                return cont(proc.apply(null, []));
            })
        }
    }
}
export function evaluate(program, scope) {
    let toks = tokenize(program)
    let ast = parse(toks)

    return _evalRec(ast, scope, x => x)
}
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
        "trampoline": (f) => (...args) => {
            let result = f.bind(null, ...args)
            while (typeof result === 'function') {
                result = result()
            }
            return result
        }
    }
    for (let op of ['+', '-', '/', '>', '<', '>=', '<=', '&&', '||']) {
        initial[op] = new Function("return Array.prototype.slice.call(arguments,1).reduce(function(x,a){return x " + op + " a;},arguments[0]);")
    }
    return createScope(null, initial)
}
