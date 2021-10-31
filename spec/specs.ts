const {expect, should} = require("chai")
const {topLevel, evaluate} = require("../src/lisp_lang")

should()

describe("toy lisp", () => {
    let env = 0
    beforeEach(() => env = topLevel())

    describe("parsing", () => {
        it("should NOT be able to eval (()", () =>
            expect(() => evaluate("(()", env)).to.throw())

        it("should NOT be able to eval ())", () =>
            expect(() => evaluate("())", env)).to.throw())

        it("should handle single-line comments", () =>
            evaluate(";;here's comment\n(- 1 1)\n", env).should.equal(0))

        it("should be able to evaluate statements with new lines and tabs", () =>
            evaluate("(begin (len '())\t\n (len '(1)) \n 1)", env).should.equal(1))

        it("should support quotes", () =>
            evaluate("'(1)", env).should.eql([1]))

        it("should support - in quotations", () => {
            evaluate("'hello-world", env).should.equal("hello-world")
            evaluate("'(hello-world)", env).should.eql(["hello-world"])
            evaluate("'(hello-world 1)", env).should.eql(["hello-world", 1])
        })
    })

    describe("evaluation", () => {
        it("should make (eq? nil '()) to be true", () =>
            evaluate("(eq? nil '())", env).should.equal(true))

        it("should pass for (cons 1 (cons 2 nil))", () =>
            evaluate("(cons 1 (cons 2 nil))", env))

        it("should pass 0 as 0 but not undefined", () =>
            evaluate("((lambda (x) x) 0)", env).should.equal(0))

        it("should pass all parameters", () =>
            evaluate("(- 1 1)", env).should.equal(0))

        it("should support strings", () =>
            evaluate('(+ "foo " "bar")', env).should.equal("foo bar"))

        it("should not evaluate defined symbols to undefined", () => {
            const res = evaluate("cons", env)
            res.should.not.equal(undefined)
        })

        describe("scoping", function() {
            // TBD
        })
    })
})
