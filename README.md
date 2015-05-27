Toy lisp interpreter
===

Created *just for fun*.

~100 lines of coffeescript code.

Based on original article [norvig.com/lispy.html](http://norvig.com/lispy.html).

Prerequisites:

	$ npm install coffee-script -g
	$ npm install

Run:

	$ coffee src/lisp.coffee

Some tests:
	
	$ mocha --compilers coffee:coffee-script/register spec/specs.coffee
	$ coffee lisp.coffee -f test.lisp
