import fs from 'fs'
import { resolve } from 'path'
import { fileURLToPath } from 'url'
import colors from 'colors/safe'
import minimist from 'minimist'
const isEmpty = (arr: any[]): boolean => Array.isArray(arr) && (arr.length === 0)
const tokenize = (program: string): string[] => program
    .replace(/\'([\-\w\d\.\*\:\?\!]+|\([\-\s\w\d\.\*\:\?\!]*\))/g, "(quote $1)")
    .replace(/;;.*\n/g, "").replace(/[\n\t]/g, " ")
    .replace(/\(/g, " ( ").replace(/\)/g, " ) ")
    .match(/\".*?\"|[^\s]+/g)?.filter(x => !!x) || []
function parse(tokens: string[]): any {
    if (isEmpty(tokens)) return
    const atom = (v: string) => { const n = parseFloat(v); return isNaN(n) ? v : n }
    const first = tokens.shift(), list: any[] = []
    if (first === ")") throw new Error("ToyLisp: Syntax error, closing parenthesis at the beginning of the expression")
    if (first !== "(") return atom(first!)
    while ((tokens[0] !== ")") && (tokens.length !== 0)) list.push(parse(tokens))
    tokens.shift(); return list
}
function createScope(parent: any, init?: any): any {
    const locals = init || {}
    const _sc = (name: any, val?: any) => (name == null) ? locals : (val == null) ? name in locals ? locals[name] : parent != null ? parent(name) : null : (locals[name] = val)
    _sc.root = () => parent != null ? parent.root() : _sc
    _sc.find = (name: any) => locals[name] != null ? _sc : parent != null ? parent.find(name) : null
    return _sc
}
let inMacro = false
function _evalRec(node: any, scope: any, cont: any): any {
    const rootScope = scope.root()
    if (!inMacro)
        Object.keys(rootScope()).filter(k => k.indexOf("macro/") === 0).forEach(m => {
            inMacro = true; node = (rootScope(m)(node) || node); inMacro = false
        })
    if ((typeof node === "string") && (node[0] !== '"')) return cont(scope(node))
    if (!Array.isArray(node)) return cont(typeof node === "string" ? node.slice(1, -1) : node)
    switch (node[0]) {
        case 'quote': return cont(node[1])
        case 'if': return _evalRec(node[1], scope, cond => cond ? _evalRec(node[2], scope, cont): _evalRec(node[3], scope, cont))
        case 'define': return _evalRec(node[2], scope, x => { scope(node[1], x); return cont(x) })
        case 'set!': return _evalRec(node[2], scope, x => { scope.find(node[1])?.(node[1], x); return cont(x) })
        case 'lambda': return cont((...args) => {
                const subScope = createScope(scope)
                args.forEach((arg, i) => subScope(node[1][i], arg))
                return _evalRec(node[2], subScope, x => x)
            })
        case 'begin': {
            const ops = node.slice(1)
            if (ops.length == 0) return cont()
            const funcs = ops.map((v, i, _) => () => _evalRec(v, scope, funcs[i + 1]));
            funcs[funcs.length - 1] = () => _evalRec(ops[funcs.length - 1], scope, x => { return cont(x)})
            return funcs[0]()
        }
        default:
            return _evalRec(node[0], scope, proc => {
                if (proc == null) throw new Error('ToyLisp: Function ' + node[0] + ' is not defined')
                const argsExprs = node.slice(1)
                if (argsExprs.length == 0) return cont(proc.apply(null, []));
                const args = new Array(argsExprs.length);
                const funcs = argsExprs.map((v, i, _) => () => _evalRec(v, scope, r => { args[i] = r; return funcs[i+1](); }))
                funcs[funcs.length - 1] = () => _evalRec(argsExprs[argsExprs.length - 1], scope, r => { args[argsExprs.length - 1] = r; return cont(proc.apply(null, args));})
                return funcs[0]()
            })
    }
}
export const evaluate = (program: string, scope: any) => _evalRec(parse(tokenize(program)), scope, (x: any) => x)
export function topLevel(): any {
    const initial = {
        "nil": null, "#t": true, "#f": false,
        "eq?"(...els) { return els.map(el => isEmpty(el) ? null : el).reduce(((acc, el, i, a) => (el === a[0]) && acc), true) },
        car(lst) { return (lst || [])[0] }, cdr(lst) { return (lst || []).slice(1) },
        len(lst) { return (lst || []).length }, cons(v, lst) { return [v].concat(lst || []) }, list(...els) { return els },
        error(msg) { throw Error(msg) }, try(fn, fail) { try { return fn() } catch (e) { return fail(e) }},
        "js/eval"(prg) { return global.eval(prg) }, "js/bind"(f, args) { return Function.prototype.bind.apply(f, args) },
        trampoline: (f) => { let a = false; return (...args) => { if (a) return () => f(...args); a = true; try { let r = f(...args); while (typeof r === 'function') r = r(); return r } finally { a = false } } }
    }
    for (let op of ['+', '-', '*', '/', '>', '<', '>=', '<=', '&&', '||'])
        initial[op] = new Function("return Array.prototype.slice.call(arguments,1).reduce(function(x,a){return x " + op + " a;},arguments[0]);")
    return createScope(null, initial)
}
if (fileURLToPath(import.meta.url) === process.argv[1]) {
    // @ts-ignore
    global['colors'] = colors
    const argv = minimist(process.argv.slice(2))
    const env = topLevel()
    const loadFile = (path: string) => evaluate('(begin ' + fs.readFileSync(path) + ')', env)
    const fmt = (r: any): string => Array.isArray(r) ? "(" + r.map(fmt).join(" ") + ")" : typeof r === "function" ? "<function>" : String(r)
    const repl = async () => {
        const { createInterface } = await import('readline')
        const rl = createInterface({ input: process.stdin, output: process.stdout })
        rl.setPrompt('#> ')
        rl.on('line', line => { try { if (line.trim()) console.log(colors.green(fmt(evaluate(line.trim(), env)))) } catch(e) { console.log(colors.red(e.stack)) } finally { rl.prompt() } })
        rl.on('close', () => process.exit(0)); rl.prompt()
    }
    try { if (argv['debug'] != null) { evaluate('(define *DEBUG* #t)', env); console.log(colors.yellow('Debug mode enabled')) }
        loadFile(resolve('src/stdlib.lisp')); await (argv['f'] != null ? loadFile(resolve(argv['f'])) : repl())
    } catch (e: any) { console.error(colors.red(e.stack)); process.exit(1) }
}
