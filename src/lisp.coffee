fs = require 'fs'
colors = require 'colors/safe'
argv = require('minimist')(process.argv.slice(2));
domain = require 'domain'
lisp = require './lisp-lang'


global.colors = colors
env = lisp.topLevel()

locateFile = (name) ->
  process.cwd() + '/' + name

loadFile = (path, cont) ->
  data = fs.readFileSync path
  lisp.evaluate('(begin ' + data.toString() + ')', env)

repl = () ->
  rl = require('readline').createInterface(
    input: process.stdin
    output: process.stdout)

  rl.setPrompt '#> '

  rl.on 'line', (line) ->
    program = line.trim()
    try
      result = lisp.evaluate(program, env)
      console.log colors.green(result)
    catch e
      console.log colors.red(e.stack)
    finally
      rl.prompt()

  rl.on 'close', ->
    process.exit 0

  rl.prompt()

try
  if argv['debug']?
    lisp.evaluate('(define *DEBUG* #t)', env)

  loadFile locateFile('src/stdlib.lisp')

  if argv['f']?
    loadFile(locateFile(argv['f']))
  else
    repl()
catch e
  console.error(colors.red(e.stack))
  process.exit(1)
