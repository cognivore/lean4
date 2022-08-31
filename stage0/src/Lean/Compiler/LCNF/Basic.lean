/-
Copyright (c) 2022 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
import Lean.Expr

namespace Lean.Compiler.LCNF

/-!
# Lean Compiler Normal Form (LCNF)

It is based on the [A-normal form](https://en.wikipedia.org/wiki/A-normal_form),
and the approach described in the paper
[Compiling  without continuations](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/11/compiling-without-continuations.pdf).

-/

structure Param where
  fvarId     : FVarId
  binderName : Name
  type       : Expr
  deriving Inhabited

def Param.toExpr (p : Param) : Expr :=
  .fvar p.fvarId

inductive AltCore (Code : Type) where
  | alt (ctorName : Name) (params : Array Param) (code : Code)
  | default (code : Code)
  deriving Inhabited

structure LetDecl where
  fvarId : FVarId
  binderName : Name
  type : Expr
  value : Expr
  pure : Bool
  deriving Inhabited

structure FunDeclCore (Code : Type) where
  fvarId : FVarId
  binderName : Name
  params : Array Param
  type : Expr
  value : Code
  deriving Inhabited

def FunDeclCore.getArity (decl : FunDeclCore Code) : Nat :=
  decl.params.size

structure CasesCore (Code : Type) where
  typeName : Name
  resultType : Expr
  discr : FVarId
  alts : Array (AltCore Code)
  deriving Inhabited

inductive Code where
  | let (decl : LetDecl) (k : Code)
  | fun (decl : FunDeclCore Code) (k : Code)
  | jp (decl : FunDeclCore Code) (k : Code)
  | jmp (fvarId : FVarId) (args : Array Expr)
  | cases (cases : CasesCore Code)
  | return (fvarId : FVarId)
  | unreach (type : Expr)
  deriving Inhabited

abbrev Alt := AltCore Code
abbrev FunDecl := FunDeclCore Code
abbrev Cases := CasesCore Code

def AltCore.getCode : Alt → Code
  | .default k => k
  | .alt _ _ k => k

private unsafe def updateAltCodeImp (alt : Alt) (k' : Code) : Alt :=
  match alt with
  | .default k => if ptrEq k k' then alt else .default k'
  | .alt ctorName ps k => if ptrEq k k' then alt else .alt ctorName ps k'

@[implementedBy updateAltCodeImp] opaque AltCore.updateCode (alt : Alt) (c : Code) : Alt

private unsafe def updateAltImp (alt : Alt) (ps' : Array Param) (k' : Code) : Alt :=
  match alt with
  | .alt ctorName ps k => if ptrEq k k' && ptrEq ps ps' then alt else .alt ctorName ps' k'
  | _ => unreachable!

@[implementedBy updateAltImp] opaque AltCore.updateAlt! (alt : Alt) (ps' : Array Param) (k' : Code) : Alt

@[inline] private unsafe def updateAltsImp (c : Code) (alts : Array Alt) : Code :=
  match c with
  | .cases cs => if ptrEq cs.alts alts then c else .cases { cs with alts }
  | _ => unreachable!

@[implementedBy updateAltsImp] opaque Code.updateAlts! (c : Code) (alts : Array Alt) : Code

@[inline] private unsafe def updateCasesImp (c : Code) (resultType : Expr) (discr : FVarId) (alts : Array Alt) : Code :=
  match c with
  | .cases cs => if ptrEq cs.alts alts && ptrEq cs.resultType resultType && cs.discr == discr then c else .cases { cs with discr, resultType, alts }
  | _ => unreachable!

@[implementedBy updateCasesImp] opaque Code.updateCases! (c : Code) (resultType : Expr) (discr : FVarId) (alts : Array Alt) : Code

@[inline] private unsafe def updateLetImp (c : Code) (decl' : LetDecl) (k' : Code) : Code :=
  match c with
  | .let decl k => if ptrEq k k' && ptrEq decl decl' then c else .let decl' k'
  | _ => unreachable!

@[implementedBy updateLetImp] opaque Code.updateLet! (c : Code) (decl' : LetDecl) (k' : Code) : Code

@[inline] private unsafe def updateContImp (c : Code) (k' : Code) : Code :=
  match c with
  | .let decl k => if ptrEq k k' then c else .let decl k'
  | .fun decl k => if ptrEq k k' then c else .fun decl k'
  | .jp decl k => if ptrEq k k' then c else .jp decl k'
  | _ => unreachable!

@[implementedBy updateContImp] opaque Code.updateCont! (c : Code) (k' : Code) : Code

@[inline] private unsafe def updateFunImp (c : Code) (decl' : FunDecl) (k' : Code) : Code :=
  match c with
  | .fun decl k => if ptrEq k k' && ptrEq decl decl' then c else .fun decl' k'
  | .jp decl k => if ptrEq k k' && ptrEq decl decl' then c else .jp decl' k'
  | _ => unreachable!

@[implementedBy updateFunImp] opaque Code.updateFun! (c : Code) (decl' : FunDecl) (k' : Code) : Code

@[inline] private unsafe def updateReturnImp (c : Code) (fvarId' : FVarId) : Code :=
  match c with
  | .return fvarId => if fvarId == fvarId' then c else .return fvarId'
  | _ => unreachable!

@[implementedBy updateReturnImp] opaque Code.updateReturn! (c : Code) (fvarId' : FVarId) : Code

@[inline] private unsafe def updateJmpImp (c : Code) (fvarId' : FVarId) (args' : Array Expr) : Code :=
  match c with
  | .jmp fvarId args => if fvarId == fvarId' && ptrEq args args' then c else .jmp fvarId' args'
  | _ => unreachable!

@[implementedBy updateJmpImp] opaque Code.updateJmp! (c : Code) (fvarId' : FVarId) (args' : Array Expr) : Code

@[inline] private unsafe def updateUnreachImp (c : Code) (type' : Expr) : Code :=
  match c with
  | .unreach type => if ptrEq type type' then c else .unreach type'
  | _ => unreachable!

@[implementedBy updateUnreachImp] opaque Code.updateUnreach! (c : Code) (type' : Expr) : Code

private unsafe def updateParamCoreImp (p : Param) (type : Expr) : Param :=
  if ptrEq type p.type then
    p
  else
    { p with type }

/--
Low-level update `Param` function. It does not update the local context.
Consider using `Param.update : Param → Expr → CompilerM Param` if you want the local context
to be updated.
-/
@[implementedBy updateParamCoreImp] opaque Param.updateCore (p : Param) (type : Expr) : Param

private unsafe def updateLetDeclCoreImp (decl : LetDecl) (type : Expr) (value : Expr) : LetDecl :=
  if ptrEq type decl.type && ptrEq value decl.value then
    decl
  else
    { decl with type, value }

/--
Low-level update `LetDecl` function. It does not update the local context.
Consider using `LetDecl.update : LetDecl → Expr → Expr → CompilerM LetDecl` if you want the local context
to be updated.
-/
@[implementedBy updateLetDeclCoreImp] opaque LetDecl.updateCore (decl : LetDecl) (type : Expr) (value : Expr) : LetDecl

private unsafe def updateFunDeclCoreImp (decl: FunDecl) (type : Expr) (params : Array Param) (value : Code) : FunDecl :=
  if ptrEq type decl.type && ptrEq params decl.params && ptrEq value decl.value then
    decl
  else
    { decl with type, params, value }

/--
Low-level update `FunDecl` function. It does not update the local context.
Consider using `FunDecl.update : LetDecl → Expr → Array Param → Code → CompilerM FunDecl` if you want the local context
to be updated.
-/
@[implementedBy updateFunDeclCoreImp] opaque FunDeclCore.updateCore (decl: FunDecl) (type : Expr) (params : Array Param) (value : Code) : FunDecl

def Code.isDecl : Code → Bool
  | .let .. | .fun .. | .jp .. => true
  | _ => false

def Code.isReturnOf : Code → FVarId → Bool
  | .return fvarId, fvarId' => fvarId == fvarId'
  | _, _ => false

partial def Code.size (c : Code) : Nat :=
  go c 0
where
  go (c : Code) (n : Nat) : Nat :=
    match c with
    | .let _ k => go k (n+1)
    | .jp decl k | .fun decl k => go k <| go decl.value n
    | .cases c => c.alts.foldl (init := n+1) fun n alt => go alt.getCode (n+1)
    | .jmp .. => n+1
    | .return .. | unreach .. => n -- `return` & `unreach` have weight zero

/-- Return true iff `c.size ≤ n` -/
partial def Code.sizeLe (c : Code) (n : Nat) : Bool :=
  match go c |>.run 0 with
  | .ok .. => true
  | .error .. => false
where
  inc : EStateM Unit Nat Unit := do
    modify (·+1)
    unless (← get) <= n do throw ()

  go (c : Code) : EStateM Unit Nat Unit := do
    match c with
    | .let _ k => inc; go k
    | .jp decl k | .fun decl k => inc; go decl.value; go k
    | .cases c => inc; c.alts.forM fun alt => go alt.getCode
    | .jmp .. => inc
    | .return .. | unreach .. => return ()

/--
Declaration being processed by the Lean to Lean compiler passes.
-/
structure Decl where
  /--
  The name of the declaration from the `Environment` it came from
  -/
  name  : Name
  /--
  Universe level parameter names.
  -/
  levelParams : List Name
  /--
  The type of the declaration. Note that this is an erased LCNF type
  instead of the fully dependent one that might have been the original
  type of the declaration in the `Environment`.
  -/
  type  : Expr
  /--
  Parameters.
  -/
  params : Array Param
  /--
  The body of the declaration, usually changes as it progresses
  through compiler passes.
  -/
  value : Code

def Decl.size (decl : Decl) : Nat :=
  decl.value.size

def Decl.getArity (decl : Decl) : Nat :=
  decl.params.size

def Decl.instantiateTypeLevelParams (decl : Decl) (us : List Level) : Expr :=
  decl.type.instantiateLevelParams decl.levelParams us

def Decl.instantiateParamsLevelParams (decl : Decl) (us : List Level) : Array Param :=
  decl.params.mapMono fun param => param.updateCore (param.type.instantiateLevelParams decl.levelParams us)

partial def Decl.instantiateValueLevelParams (decl : Decl) (us : List Level) : Code :=
  instCode decl.value
where
  instExpr (e : Expr) :=
    e.instantiateLevelParams decl.levelParams us

  instParams (ps : Array Param) :=
    ps.mapMono fun p => p.updateCore (instExpr p.type)

  instAlt (alt : Alt) :=
    match alt with
    | .default k => alt.updateCode (instCode k)
    | .alt _ ps k => alt.updateAlt! (instParams ps) (instCode k)

  instLetDecl (decl : LetDecl) :=
    decl.updateCore (instExpr decl.type) (instExpr decl.value)

  instFunDecl (decl : FunDecl) :=
    decl.updateCore (instExpr decl.type) (instParams decl.params) (instCode decl.value)

  instCode (code : Code) :=
    match code with
    | .let decl k => code.updateLet! (instLetDecl decl) (instCode k)
    | .jp decl k | .fun decl k => code.updateFun! (instFunDecl decl) (instCode k)
    | .cases c => code.updateCases! (instExpr c.resultType) c.discr (c.alts.mapMono instAlt)
    | .jmp fvarId args => code.updateJmp! fvarId (args.mapMono instExpr)
    | .return .. => code
    | .unreach type => code.updateUnreach! (instExpr type)

end Lean.Compiler.LCNF