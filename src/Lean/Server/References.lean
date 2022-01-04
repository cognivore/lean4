import Init.System.IO
import Lean.Data.Json
import Lean.Data.Lsp

import Lean.Server.Utils
import Lean.Server.InfoUtils
import Lean.Server.Snapshots

/- Representing collected and deduplicated definitions and usages -/

namespace Lean.Server
open Lsp

structure Reference where
  ident : RefIdent
  range : Lsp.Range
  isDeclaration : Bool
  deriving BEq

end Lean.Server

namespace Lean.Lsp.RefInfo
open Server

def empty : RefInfo := ⟨ none, #[] ⟩

def addRef : RefInfo → Reference → RefInfo
  | i@{ definition := none, .. }, { range, isDeclaration := true, .. } =>
    { i with definition := range }
  | i@{ usages, .. }, { range, isDeclaration := false, .. } =>
    { i with usages := usages.push range }
  | i, _ => i

def contains (self : RefInfo) (pos : Lsp.Position) : Bool := Id.run do
  if let some range := self.definition then
    if contains range pos then
      return true
  for range in self.usages do
    if contains range pos then
      return true
  false
  where
    contains (range : Lsp.Range) (pos : Lsp.Position) : Bool :=
      range.start <= pos && pos < range.end

end Lean.Lsp.RefInfo

namespace Lean.Lsp.ModuleRefs
open Server

def addRef (self : ModuleRefs) (ref : Reference) : ModuleRefs :=
  let refInfo := self.findD ref.ident RefInfo.empty
  self.insert ref.ident (refInfo.addRef ref)

def findAt? (self : ModuleRefs) (pos : Lsp.Position) : Option RefIdent := Id.run do
  for (ident, info) in self.toList do
    if info.contains pos then
      return some ident
  none

end Lean.Lsp.ModuleRefs

namespace Lean.Server
open IO
open Std
open Lsp
open Elab

/-- Content of individual `.ilean` files -/
structure Ilean where
  version : Nat := 1
  module : Name
  references : ModuleRefs
  deriving FromJson, ToJson

namespace Ilean

def load (path : System.FilePath) : IO Ilean := do
  let content ← FS.readFile path
  match Json.parse content >>= fromJson? with
    | Except.ok ilean => pure ilean
    | Except.error msg => throwServerError s!"Failed to load ilean at {path}: {msg}"

end Ilean
/- Collecting and deduplicating definitions and usages -/

def identOf : Info → Option (RefIdent × Bool)
  | Info.ofTermInfo ti => match ti.expr with
    | Expr.const n .. => some (RefIdent.const n, ti.isBinder)
    | Expr.fvar id .. => some (RefIdent.fvar id, ti.isBinder)
    | _ => none
  | Info.ofFieldInfo fi => some (RefIdent.const fi.projName, false)
  | _ => none

def findReferences (text : FileMap) (trees : List InfoTree) : Array Reference := Id.run do
  let mut refs := #[]
  for tree in trees do
    refs := refs.appendList <| tree.deepestNodes fun _ info _ => Id.run do
      if let some (ident, isDeclaration) := identOf info then
        if let some range := info.range? then
          return some { ident, range := range.toLspRange text, isDeclaration }
      return none
  refs

/--
The `FVarId`s of a function parameter in the function's signature and body
differ. However, they have `TermInfo` nodes with `binder := true` in the exact
same position.

This function changes every such group to use a single `FVarId` and gets rid of
duplicate definitions.
-/
def combineFvars (refs : Array Reference) : Array Reference := Id.run do
  -- Deduplicate definitions based on their exact range
  let mut posMap : HashMap Lsp.Range FVarId := HashMap.empty
  -- Map all `FVarId`s of a group to the first definition's id
  let mut idMap : HashMap FVarId FVarId := HashMap.empty
  for ref in refs do
    if let { ident := RefIdent.fvar id, range, isDeclaration := true } := ref then
      if let some baseId := posMap.find? range then
        idMap := idMap.insert id baseId
      else
        posMap := posMap.insert range id
        idMap := idMap.insert id id

  refs.foldl (init := #[]) fun refs ref => match ref with
    | { ident := RefIdent.fvar id, range, isDeclaration := true } =>
      -- Since deduplication works via definitions, we know that this keeps (at
      -- least) one definition.
      if idMap.contains id then refs.push ref else refs
    | { ident := ident@(RefIdent.fvar _), range, isDeclaration := false } =>
      refs.push { ident := applyIdMap idMap ident, range, isDeclaration := false }
    | _ => refs.push ref
  where
    applyIdMap : HashMap FVarId FVarId → RefIdent → RefIdent
      | m, RefIdent.fvar id => RefIdent.fvar <| m.findD id id
      | _, ident => ident

def findModuleRefs (text : FileMap) (trees : List InfoTree) (localVars : Bool := true)
    : ModuleRefs := Id.run do
  let mut refs := combineFvars <| findReferences text trees
  if !localVars then
    refs := refs.filter fun
      | { ident := RefIdent.fvar _, .. } => false
      | _ => true
  refs.foldl (init := HashMap.empty) fun m ref => m.addRef ref

/- Collecting and maintaining reference info from different sources -/

structure References where
  /-- References loaded from ilean files -/
  ileans : HashMap Name (System.FilePath × ModuleRefs)
  /-- References from workers, overriding the corresponding ilean files -/
  workers : HashMap Name (Nat × ModuleRefs)

namespace References

def empty : References := { ileans := HashMap.empty, workers := HashMap.empty }

def addIlean (self : References) (path : System.FilePath) (ilean : Ilean) : References :=
  { self with ileans := self.ileans.insert ilean.module (path, ilean.references) }

def removeIlean (self : References) (path : System.FilePath) : References :=
  let namesToRemove := self.ileans.toList.filter (fun (_, p, _) => p == path)
    |>.map (fun (n, _, _) => n)
  namesToRemove.foldl (init := self) fun self name =>
    { self with ileans := self.ileans.erase name }

def addWorkerRefs (self : References) (name : Name) (version : Nat) (refs : ModuleRefs) : References := Id.run do
  if let some (currVersion, _) := self.workers.find? name then
    if version <= currVersion then
      return self
  return { self with workers := self.workers.insert name (version, refs) }

def removeWorkerRefs (self : References) (name : Name) : References :=
  { self with workers := self.workers.erase name }

def allRefs (self : References) : HashMap Name ModuleRefs :=
  let ileanRefs := self.ileans.toList.foldl (init := HashMap.empty) fun m (name, _, refs) => m.insert name refs
  self.workers.toList.foldl (init := ileanRefs) fun m (name, _, refs) => m.insert name refs

def findAt? (self : References) (module : Name) (pos : Lsp.Position) : Option RefIdent := Id.run do
  if let some refs := self.allRefs.find? module then
    return refs.findAt? pos
  none

def referingTo (self : References) (ident : RefIdent) (srcSearchPath : SearchPath)
    (includeDefinition : Bool := true) : IO (Array Location) := do
  let mut result := #[]
  for (module, refs) in self.allRefs.toList do
    if let some info := refs.find? ident then
      if let some path ← srcSearchPath.findWithExt "lean" module then
        -- Resolve symlinks (such as `src` in the build dir) so that files are
        -- opened in the right folder
        let uri := DocumentUri.ofPath <| ← IO.FS.realPath path
        if includeDefinition then
          if let some range := info.definition then
            result := result.push ⟨uri, range⟩
        for range in info.usages do
          result := result.push ⟨uri, range⟩
  result

end References

end Lean.Server