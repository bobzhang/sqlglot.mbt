# Review 02: dialect infrastructure (Codex gpt-6-astra, high)

## Disposition
- P1 super() chains: dialect agents capture the parent dialect's implementation at configure time (rules in the dialect agent brief); never use g.dialect.parent at runtime.
- P1 dual slots: rule — methods with typed hooks are overridden only via hooks.
- P1 JSONPath tokenizer: ported by hand per dialect in configure_tokenizer (TODO: generate).
- P1 registry: fixed in 4d06a0f (fresh instances, settings/version validation, SUPPORTED_SETTINGS).
- P2 finalize recompute / deep copies: deferred (only affects user-defined dialects).
- P2 registration: fixed in 4d06a0f (each dialect package registers itself in fn init).

## Review

The model can emulate fixed single-inheritance chains, but copying tables alone does **not** preserve Python inheritance semantics. The main risks are below, in priority order.

1. **P1 — `super()` needs a defining-class reference, not the runtime dialect’s parent.**  
   [Dialect::subclass](../src/core/dialect.mbt:110) copies effective functions but records no method owner. An inherited Spark2 method running on Databricks must still resolve ordinary `super()` through Hive. Looking up `g.dialect.parent` could re-enter Spark/Spark2; calling the base `Generator` directly skips Hive. Python also deliberately skips Hive with `super(HiveGenerator, self)` in [Spark2’s cast implementation](https://github.com/tobymao/sqlglot/blob/main/sqlglot/generators/spark2.py:221).

   Capture the resolved parent **function** when installing each override, or export explicitly named implementation functions. Always pass the current parser/generator receiver so nested virtual calls retain child behavior. Support explicit ancestor calls separately. The generator header’s “base implementation … call it as `super()`” convention is unsafe for these chains. Currently Hive/Spark2/Spark/Databricks override files are stubs, so their configuration chain does not demonstrate behavioral inheritance.

2. **P1 — Generator overrides have two competing sources of truth.**  
   Transform-before-method precedence correctly matches Python `_build_dispatch`. However, [sql/call_method](../src/core/generator_core.mbt:513) prioritize `methods`, while [cast_sql_v](../src/core/generator_exprs.mbt:1013) prioritizes the typed hook. A parent `methods[Cast]` plus child `hooks.cast_sql` makes ordinary SQL dispatch select the parent while direct virtual calls select the child; reversing the registrations creates the opposite problem.

   Give each overridable method one canonical slot, with adapters for default arguments. Add a three-level inheritance test covering transforms, direct virtual calls, typed arguments, and parent calls.

3. **P1 — Generated configuration misses actual JSONPath dialect differences.**  
   [gen_settings.py](../tools/gen_settings.py:446) diffs only `tokenizer_class`, although `Dialect` separately carries `jsonpath_tokenizer` and `jsonpath_var_tokens`. Python introspection confirms omitted differences: BigQuery/Hive `VAR_TOKENS`, Databricks `IDENTIFIERS`, and Snowflake `SINGLE_TOKENS`. Their tokenizer configuration hooks are currently empty.

   Generate JSONPath configuration too. More generally, [data_attrs](../tools/gen_settings.py:341) scans only base-class uppercase attributes and silently skips unsupported types. Emit a coverage manifest identifying generated, manually implemented, and unsupported attributes—including dialect-only additions—and fail regeneration on newly unclassified behavior.

4. **P1 — Registry lookups expose mutable instances; settings parsing diverges.**  
   [get_or_raise](../src/core/dialect.mbt:223) returns the cached dialect directly when no settings suffix exists. Mutating its version, normalization strategy, or settings contaminates subsequent callers. Python string lookup constructs a fresh instance.

   Always instantiate from a registered definition. Preserve typed boolean settings, validate per-dialect supported settings, and reject invalid version components: the port silently turns `version=bad` into zero and accepts unknown keys, whereas Python rejects both. Skipping `SUPPORTED_SETTINGS` in generation prevents faithful validation. Keep instance initialization separate from class finalization, which currently resets normalization strategy.

5. **P2 — Metaclass results are captured, but their dependency rules are not.**  
   Generated values come from initialized Python classes, so many `_Dialect.__new__` effects—delimiter fields, inverse mappings, escape mappings—are already captured for built-ins. Tokenizer finalization also reconstructs most derived tables correctly.

   But [Dialect::finalize](../src/core/dialect.mbt:62) rebuilds tries without recomputing inverse mappings, quote/identifier fields, escape capabilities, or interval-unit expansion. A custom subclass changing tokenizer quotes can therefore tokenize with one delimiter and generate another. Recompute dependent fields from declared inputs, preserving explicit overrides. In this Python checkout, Parser/Generator do not define `__init_subclass__`; Generator builds dispatch lazily, while Tokenizer uses `__init_subclass__`.

6. **P2 — Shallow copying does not isolate nested data or closure captures.**  
   [Generated copy logic](../tools/gen_settings.py:399) leaves nested arrays shared; [GeneratorFns::copy](../src/core/generator_core.mbt:125) shares arrays inside `type_param_settings`. Closures retain captured objects.

   SQLite illustrates a subtler inheritance limitation: [its parser hook](../src/dialects/sqlite/parser.mbt:109) captures an arithmetic-token set, whereas Python reads `self.ARITHMETIC_TOKENS`. Its private concat helper is also statically called. SQLite’s direct-base calls are appropriate today, but this template loses child overrides. Freeze completed definitions, deep-copy mutable nested values where customization is supported, and route overridable data/helpers through the receiver.

7. **P2 — Facade initialization does not register standalone dialect imports.**  
   Registration exists only in [src/registry.mbt](../src/registry.mbt:4). Importing SQLite alone does not import that facade: `@sqlite.dialect()` works, but core name lookup cannot discover SQLite. Generate package-local registration in [the scaffold](../tools/gen_dialect_pkgs.py:54), or expose an explicit registration API and document that contract. Test a consumer importing only one dialect.

Review used source inspection and Python introspection; MoonBit execution was not validated in the read-only environment.
