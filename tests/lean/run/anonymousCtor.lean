#lang lean4

inductive S
| mk : List S → String → S

def f (s : String) : S :=
⟨[], s⟩
