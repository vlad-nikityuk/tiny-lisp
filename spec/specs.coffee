chai = require("chai")
lisp = require("../src/lisp-lang")
chai.should()

describe "toy lisp", ->
  env = 0
  beforeEach ->
    env = lisp.topLevel()

  describe "parsing", ->
    it "should NOT be able to eval (()", ->
      chai.expect(-> lisp.evaluate("(()", env)).to.throw()

    # it "should NOT be able to eval ())", ->
    #   chai.expect(-> lisp.evaluate("(define first-returns-head-of-list (lambda () (begin (eq? 4 4)))))", env)).to.throw()

    it "should handle single-line comments", ->
      lisp.evaluate(";here's comment\n(- 1 1)\n", env).should.equal 0

    it "should be able to evaluate statements with new lines and tabs", ->
      lisp.evaluate("(begin (len '())\t\n (len '(1)) \n 1)", env).should.equal 1

    it "should support quotes", ->
      lisp.evaluate("'(1)", env).should.eql [1]

    it "should support - in quotations", ->
      lisp.evaluate("'hello-world", env).should.equal "hello-world"
      lisp.evaluate("'(hello-world)", env).should.eql ["hello-world"]
      lisp.evaluate("'(hello-world 1)", env).should.eql ["hello-world", 1]

  describe "evaluation", ->
    it "should make (eq? nil '()) to be true", ->
      r = lisp.evaluate("(eq? nil '())", env)
      r.should.equal true

    it "should pass for (cons 1 (cons 2 nil))", ->
      lisp.evaluate "(cons 1 (cons 2 nil))", env

    it "should pass 0 as 0 but not undefined", ->
      lisp.evaluate("((lambda (x) x) 0)", env).should.equal 0

    it "should pass all parameters", ->
        lisp.evaluate("(- 1 1)", env).should.equal 0

    it "should support strings", ->
      lisp.evaluate('(+ "foo " "bar")', env).should.equal "foo bar"

    it "should not evaluate defined symbols to undefined", ->
        res = lisp.evaluate("cons", env)
        res.should.not.equal undefined
    describe "scoping", ->
      # nested scopes
