# AI Development Guide: High-Performance Julia Library

This document serves as the ground-truth instruction set for any AI Agent operating within this repository. The primary goal is to scaffold, refine, and optimize a professional Julia package following strict ecosystem standards and idiomatic performance practices.

---

## 1. Core Workflow Strategy

### Phase 1: One-Shot Architectural Scaffolding
* **Objective:** Generate the entire package structure and core business logic in a single, macro-level iteratio.
* **Agent Instructions:**
  1. Read the provided `BLUEPRINT.md` or design specifications completely before writing code.
  2. Write the complete initial implementation across all required modules simultaneously to maintain architectural cohesion.

### Phase 2: Autonomous Quality & Refinement Loop
* **Objective:** Eliminate type instabilities, compiler overhead, and formatting issues without human intervention.
* **Agent Instructions:**
  1. Execute the test suite via the Julia REPL/Terminal using `Pkg.test()`.
  2. Parse the outputs of automated QA tools (`Aqua.jl` and `JET.jl`).
  3. Autonomously refiner/patch code based on the error logs until all checks pass with zero warnings.

---

## 2. Julia Performance & Idiomatic Rules (Anti-Python Guardrails)

Do **NOT** write Julia code as if it were Python or C++. Adhere strictly to the following language paradigms:

* **Type Stability is Mandatory:** Ensure that the return type of every function can be predicted solely by the types of its arguments. Avoid `Any` types, type-unstable loops, and dynamic type changes.
* **Leverage Multiple Dispatch:** Design APIs around abstract types and granular, specialized methods. Do not write monolithic functions with complex internal `if-else` type checking.
* **Zero Global State:** Never use non-constant global variables. If a global configuration is strictly necessary, wrap it in a `const` or use thread-safe parameters.
* **Type Parameterization:** When defining custom `struct` types, parameterize them properly (e.g., `struct Point{T <: Real} x::T; y::T; end`) to prevent the compiler from falling back to boxed types.
* **Avoid Unnecessary Allocations:** Prioritize in-place mutating functions (using the `!` convention, e.g., `sort!`) in performance-critical loops to minimize Garbage Collector pressure.

---

## 3. Automated QA Integration

Every iteration of the codebase must be validated against the following automated testing stack:

### A. Aqua.jl (Automated Quality Assurance)
The agent must ensure the package passes all Aqua defaults:
* No unbound type parameters.
* No undefined exports or exported piracy.
* Stated project compatibility (`Project.toml` bounds checked).

### B. JET.jl (Static Analysis & Type Inference)
The agent must run JET static analysis over the codebase to catch:
* `Runtime dispatch detected` errors (critical for performance).
* No-method errors and type-inference dead ends.
* General optimization blockers before runtime execution.

---

## 4. Token & Context Optimization Rules

To minimize latency, token consumption, and context dilution, the AI Agent must abide by these operational boundaries:

* **Strict Code Exclusions:** Never read, index, or parse the contents of the following directories:
  * `.git/`
  * `manifest.toml` (Read `Project.toml` only for dependencies).
  * Auto-generated documentation builds (`docs/build/`).
  * Temporary scratchpads or benchmark artifacts.
* **Compact Communications:** Use concise, instruction-dense prompts. Do not generate verbose explanations, markdown filler, or conversational pleasantries. Focus entirely on code execution, testing loops, and concrete diagnostics.