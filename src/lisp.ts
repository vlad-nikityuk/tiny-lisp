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
    if (tokens[0] === ")") { tokens.shift(); throw new Error("ToyLisp: Syntax error, closing parenthesis at the beginning of the expression") }
    if (tokens[0] !== "(") return atom(tokens.shift()!)
    tokens.shift(); const stack: any[][] = []; let current: any[] = []
    while (tokens.length > 0 && !(stack.length === 0 && tokens[0] === ")")) {
        const t = tokens.shift()!
        if (t === "(") { stack.push(current); current = [] }
        else if (t === ")") { const done = current; current = stack.pop()!; current.push(done) }
        else current.push(atom(t))
    }
    tokens.shift(); return current
}
function createScope(parent: any, init?: any): any {
    const locals = init || {}
    const _sc = (name: any, val?: any) => (name == null) ? locals : (val == null) ? name in locals ? locals[name] : parent != null ? parent(name) : null : (locals[name] = val)
    _sc.root = () => parent != null ? parent.root() : _sc
    _sc.find = (name: any) => locals[name] != null ? _sc : parent != null ? parent.find(name) : null
    return _sc
}
let inMacro = false
class Thunk { constructor(readonly run: () => any) {} }
const thunk = (f: () => any) => new Thunk(f)
function _evalStep(node: any, scope: any, cont: any): any {
    const rootScope = scope.root()
    if (!inMacro)
        Object.keys(rootScope()).filter(k => k.indexOf("macro/") === 0).forEach(m => {
            inMacro = true; node = (rootScope(m)(node) || node); inMacro = false
        })
    if ((typeof node === "string") && (node[0] !== '"')) return cont(scope(node))
    if (!Array.isArray(node)) return cont(typeof node === "string" ? node.slice(1, -1) : node)
    switch (node[0]) {
        case 'quote': return cont(node[1])
        case 'if': return thunk(() => _evalStep(node[1], scope, cond => cond ? thunk(() => _evalStep(node[2], scope, cont)) : thunk(() => _evalStep(node[3], scope, cont))))
        case 'define': return thunk(() => _evalStep(node[2], scope, x => { scope(node[1], x); return cont(x) }))
        case 'set!': return thunk(() => _evalStep(node[2], scope, x => { scope.find(node[1])?.(node[1], x); return cont(x) }))
        case 'lambda': return cont((...args) => { const s = createScope(scope); args.forEach((a, i) => s(node[1][i], a)); return _evalRec(node[2], s, x => x) })
        case 'begin': { const ops = node.slice(1); if (ops.length == 0) return cont(); const ev = (i: number): any => i < ops.length - 1 ? thunk(() => _evalStep(ops[i], scope, _ => ev(i + 1))) : thunk(() => _evalStep(ops[i], scope, cont)); return ev(0) }
        default:
            return thunk(() => _evalStep(node[0], scope, proc => {
                if (proc == null) throw new Error('ToyLisp: Function ' + node[0] + ' is not defined')
                const argsExprs = node.slice(1)
                if (argsExprs.length == 0) return cont(proc.apply(null, []))
                const args = new Array(argsExprs.length)
                const evalArgs = (i: number): any => thunk(() => _evalStep(argsExprs[i], scope, r => { args[i] = r; return i < argsExprs.length - 1 ? evalArgs(i + 1) : cont(proc.apply(null, args)) }))
                return evalArgs(0)
            }))
    }
}
function _evalRec(node: any, scope: any, cont: any): any { let r: any = _evalStep(node, scope, cont); while (r instanceof Thunk) r = r.run(); return r }
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
