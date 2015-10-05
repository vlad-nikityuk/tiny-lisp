Toy lisp interpreter
===

[![Build Status](https://travis-ci.org/rk4n/toy-lisp.svg?branch=master)](https://travis-ci.org/rk4n/toy-lisp)

Created *just for fun*.

~100 lines of coffeescript code.

Based on original article [norvig.com/lispy.html](http://norvig.com/lispy.html).

Prerequisites:

	$ npm install coffee-script mocha -g
	$ npm install

Run:

	$ coffee src/lisp.coffee

Some tests:
	
	$ mocha --compilers coffee:coffee-script/register spec/specs.coffee
	$ coffee src/lisp.coffee -f spec/specs.lisp
