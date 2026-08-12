/-
Lean-core only: no Mathlib, no Lake dependency. If this compiles, the toolchain was
resolved for the execution platform, downloaded, verified and executed.
-/
theorem smoke_add_comm (a b : Nat) : a + b = b + a := Nat.add_comm a b

#eval "rules_lean toolchain smoke ok"
