# Essa - instruction set

32 bit instruction set for essa language.


instructions are all 32 bits. but there are very different ways we seperate those arguments. 
all instruction have 6 bit at the beginning that is an instruction tag.

1. abc - 3 arguments (some instructions might just use a and b)
  - tag(6 bits)
  - a(8 bits) - register
  - b(8 bits) - register or constant
  - c(8 bits) - register or constat
  - bk(1 bit) - 1 if b is a constant; 0 if register
  - ck(1 bit) - 1 if b is a constant; 0 if register

2. ABx - 2 arguments - 1 register and 1 index
  - tag(6 bits)
  - A(8bits) - register
  - Bx(16bits) - index

3. AsBx
  - tag(6 bits)
  - A(8bits) - register
  - sBx(16 bits) - signed index


Notation: 
 - r(A) - register of index A
 - rk(A) - register or constant of index A
 - kproto(A) - closure prototype in constant of index A
 - tag(A) - tags a struct with an integer

```
MOVE A B             ; r(A) := r(B)
LOADK A Bx           ; r(A) := k(Bx)
JMP sBx              ; PC += sBx

; Math
ADD A B C            ; r(A) := rk(B) + rk(C) 
SUB A B C            ; r(A) := rk(B) - rk(C) 
MUL A B C            ; r(A) := rk(B) * rk(C) 
DIV A B C            ; r(A) := rk(B) / rk(C) 
MOD A B C            ; r(A) := rk(B) % rk(C)
UNM A B              ; r(A) := -r(B) 

; Logic
NOT A B              ; r(A) := not r(B)
EQ A B C             ; r(A) := rk(B) == rk(C)
LT A B C             ; r(A) := rk(B) < rk(C)
LE A B C             ; r(A) := rk(B) <= rk(C)
TEST A               ; if(r(A) == true) PC++
ISNIL A B            ; r(A) := r(B) == nil

; Functions
CLOSURE A Bx         ; r(A) := kproto(Bx)
CAPTURE A B C        ; r(A).upvalues[B] := r(C)
UPVALUE A Bx         ; r(A) := upvalues(Bx)
RETURN A             ; return r(A)
CALL A B             ; r(A) := r(A)(r(A + 1) ... r(A + B - 1))
TAILCALL A B         ; return r(A)(r(A + 1) ... r(A + B - 1))

; Objects
TUPLE A B C          ;  r(A) := tag(B){} (size C)
SETTUPLE A B C       ;  r(A)[B] := r(C)  
GETTUPLE A B C       ; r(A) := r(B)[C]
GETTAG A B           ; r(A) := r(B).tag

; Lists
LIST A B C           ; r(A) := {rk(A), rk(B)}
HEAD A B             ; r(A) := r(B)[0]
TAIL A B              ; r(A) := r(B)[1]
``` 


## Some design notes

- **CLosures**:
Closures are lua-like. When you run `CALL A B` then new frame stack is r[A]...r[A + n] where n is defined by closure A proto

- **Tuples**:

Struct be like
```
let haha = {a: 2, b: 2}
let bum = haha.a
```

will be emitted to

```
TUPLE 0 0 2
LOADK 1 0 ; fetch 2
SETTUPLE 0 0 1
SETTUPLE 0 1 1
GETTUPLE 1 0 0
```
