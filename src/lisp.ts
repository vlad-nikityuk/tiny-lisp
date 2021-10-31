const fs = require('fs')
const { resolve } = require('path')
const colors = require('colors/safe')
const argv = require('minimist')(process.argv.slice(2))
const { topLevel, evaluate } = require('./lisp_lang')

// @ts-ignore
global['colors'] = colors
const env = topLevel()

const loadFile = function(path) {
    const data = fs.readFileSync(path)
    return evaluate('(begin ' + data.toString() + ')', env)
};

function repl() {
    const rl = require('readline').createInterface({
        input: process.stdin,
        output: process.stdout
    })
    rl.setPrompt('#> ');
    rl.on('line', function (line) {
        const program = line.trim()
        try {
            if (program !== '') {
                const result = evaluate(program, env)
                return console.log(colors.green(result))
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
    if (argv['debug'] != null) evaluate('(define *DEBUG* #t)', env)

    loadFile(resolve('src/stdlib.lisp'))

    if (argv['f'] != null) loadFile(resolve(argv['f']))
    else repl()

} catch (error) {
    console.error(colors.red(error.stack))
    process.exit(1)
}
