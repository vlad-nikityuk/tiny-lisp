"""The scalar autograd Value of micrograd / microgpt.py, as examples/autograd.lisp builds it.
Same graph, same children order, same topological walk. The one difference from the usual micrograd is __pow__ and the
local gradients: they use exp and log, like autograd.lisp (tinylisp has no pow primitive), so both print the same digits."""
import math


class Value:
    __slots__ = ('data', 'grad', '_children', '_local_grads')

    def __init__(self, data, children=(), local_grads=()):
        self.data = data
        self.grad = 0
        self._children = children
        self._local_grads = local_grads

    def __add__(self, other):
        other = other if isinstance(other, Value) else Value(other)
        return Value(self.data + other.data, (self, other), (1, 1))

    def __mul__(self, other):
        other = other if isinstance(other, Value) else Value(other)
        return Value(self.data * other.data, (self, other), (other.data, self.data))

    def __pow__(self, p):
        return Value(math.exp(p * math.log(self.data)), (self,), (p * math.exp((p - 1) * math.log(self.data)),))

    def log(self):
        return Value(math.log(self.data), (self,), (1 / self.data,))

    def exp(self):
        e = math.exp(self.data)
        return Value(e, (self,), (e,))

    def relu(self):
        return Value(self.data if self.data > 0 else 0, (self,), (1 if self.data > 0 else 0,))

    def __neg__(self): return self * -1
    def __radd__(self, other): return self + other
    def __sub__(self, other): return self + (-other)
    def __rsub__(self, other): return other + (-self)
    def __rmul__(self, other): return self * other
    def __truediv__(self, other): return self * (other ** -1 if isinstance(other, Value) else 1 / other)
    def __rtruediv__(self, other): return other * self ** -1

    def backward(self):
        topo = []
        visited = set()

        def build_topo(v):
            if v not in visited:
                visited.add(v)
                for child in v._children:
                    build_topo(child)
                topo.append(v)

        build_topo(self)
        self.grad = 1
        for v in reversed(topo):
            for child, local_grad in zip(v._children, v._local_grads):
                child.grad += local_grad * v.grad
