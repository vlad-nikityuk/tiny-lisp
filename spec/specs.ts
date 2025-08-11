import {test, describe, beforeEach} from 'node:test'
import assert from 'node:assert'
import {topLevel, evaluate} from "../src/lisp_lang.js"

describe("toy lisp", () => {
    let env: any
    beforeEach(() => env = topLevel())

    describe("parsing", () => {
        test("should NOT be able to eval (()", () =>
            assert.throws(() => evaluate("(()", env)))

        test("should NOT be able to eval ())", () =>
            assert.throws(() => evaluate("())", env)))

        test("should handle single-line comments", () => {
            assert.strictEqual(evaluate(";;here's comment\n(- 1 1)\n", env), 0)
        })

        test("should be able to evaluate statements with new lines and tabs", () =>
            assert.strictEqual(evaluate("(begin (len '())\t\n (len '(1)) \n 1)", env), 1))

        test("should support quotes", () =>
            assert.deepStrictEqual(evaluate("'(1)", env), [1]))

        test("should support - in quotations", () => {
            assert.strictEqual(evaluate("'hello-world", env), "hello-world")
            assert.deepStrictEqual(evaluate("'(hello-world)", env), ["hello-world"])
            assert.deepStrictEqual(evaluate("'(hello-world 1)", env), ["hello-world", 1])
        })
    })

    describe("evaluation", () => {
        test("should make (eq? nil '()) to be true", () =>
            assert.strictEqual(evaluate("(eq? nil '())", env), true))

        test("should pass for (cons 1 (cons 2 nil))", () =>
            evaluate("(cons 1 (cons 2 nil))", env))

        test("should pass 0 as 0 but not undefined", () =>
            assert.strictEqual(evaluate("((lambda (x) x) 0)", env), 0))

        test("should pass all parameters", () =>
            assert.strictEqual(evaluate("(- 1 1)", env), 0))

        test("should support strings", () =>
            assert.strictEqual(evaluate('(+ "foo " "bar")', env), "foo bar"))

        test("should not evaluate defined symbols to undefined", () => {
            assert.notStrictEqual(evaluate("cons", env), undefined)
        })
    })
})
