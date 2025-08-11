import fs from 'fs'
import { resolve } from 'path'
import colors from 'colors/safe'
import minimist from 'minimist'
import { topLevel, evaluate } from './lisp_lang.js'

const argv = minimist(process.argv.slice(2))

// @ts-ignore
global['colors'] = colors
const env = topLevel()

const loadFile = function(path: string) {
    const data = fs.readFileSync(path)
    return evaluate('(begin ' + data.toString() + ')', env)
};

function formatOutput(result: any): string {
    if (Array.isArray(result)) {
        return "(" + result.map(formatOutput).join(" ") + ")";
    } else if (typeof result === "function") {
        return "<function>"
    }
    return String(result);
}

async function repl() {
    const readline = await import('readline')
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout
    })
    rl.setPrompt('#> ');
    rl.on('line', function (line) {
        const program = line.trim()
        try {
            if (program !== '') {
                const result = evaluate(program, env)
                return console.log(colors.green(formatOutput(result)))
            }
        } catch (e) {
            return console.log(colors.red(e.stack))
        } finally {
            rl.prompt()
        }
    })

    rl.on('close', () => process.exit(0))
    return rl.prompt()
}

try {
    if (argv['debug'] != null) {
        evaluate('(define *DEBUG* #t)', env)
        console.log(colors.yellow('Debug mode enabled'))
    }

    loadFile(resolve('src/stdlib.lisp'))

    if (argv['f'] != null) loadFile(resolve(argv['f']))
    else await repl()

} catch (error: any) {
    console.error(colors.red(error.stack))
    process.exit(1)
}
