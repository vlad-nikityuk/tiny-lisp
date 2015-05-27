chai = require("chai")
lisp = require("../src/lisp-lang")
chai.should()

describe "toy lisp", ->
  env = 0
  beforeEach ->
    env = lisp.topLevel()

  describe "parsing", ->
    xit "should be able to eval (()", ->
      lisp.evaluate "(()", env

    it "should handle single-line comments", ->
      lisp.evaluate(";here's comment\n(- 1 1)\n", env).should.equal 0

    it "should be able to evaluate statements with new lines and tabs", ->
      lisp.evaluate("(begin (print 1)\t\n (print 3) \n 1)", env).should.equal 1

  describe "evaluation", ->
    it "should make (eq? nil (cdr (list 3)))) to be true", ->
      r = lisp.evaluate("(eq? nil (cdr (list 3))))", env)
      r.should.equal true

    it "should pass for (cons 1 (cons 2 nil))", ->
      lisp.evaluate "(cons 1 (cons 2 nil))", env

    it "should pass 0 as 0 but not undefined", ->
      lisp.evaluate("((lambda (x) x) 0)", env).should.equal 0

    it "should pass all parameters", ->
        lisp.evaluate("(- 1 1)", env).should.equal 0

    it "should not evaluate defined symbols to undefined", ->
        res = lisp.evaluate("cons", env)
        res.should.not.equal undefined
    describe "scoping", ->
      # nested scopes
