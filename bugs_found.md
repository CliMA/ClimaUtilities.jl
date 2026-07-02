# ClimaUtilities.jl — Typo, Bug & Performance Audit (`bugs_found.md`)

## Context

A **comprehensive deep dive** to find *all* typos and bugs across `src`, `docs`, `test`, and the `ext/` extension sources. "Typo" spans spelling/grammar/markdown; "bug" spans logic errors, copy-paste mistakes, dead code, and no-op tests; a **performance** lens targets avoidable allocations in *repeatedly-called* functions (setup/constructor allocations are explicitly out of scope). Seed examples that set the bar: a duplicated assignment (`push_preview = push_preview = ...`), a no-op `@test_logs` with no expression, and (user-supplied) the `NCFileReader` cache that never stored dated reads.

## Methodology

A multi-agent workflow fanned out **39 auditors** over `src`/`ext`/`docs`/`test` (per-file readers plus cross-file specialists: no-op tests, docstring-vs-code, copy-paste/sibling-asymmetry, docs-API validation, and two performance lenses). Every `bug`/`perf` candidate was checked by adversarial refuters (the correctness lens for bugs; a combined hot-path + real-allocation + does-it-matter lens for perf), and every prose finding by a strict batch verifier. Findings below are the **verified survivors**, aggregated by majority across all refuter opinions produced (many bugs received 2–3 independent refuter votes from earlier verification rounds).

> **Scope caveat (be aware):** the run was **stopped early at the user's request** for turnaround. Pass-1 audit + verification completed in full (all 39 items verified), but the planned **second-pass sweep** (novel-lens re-hunt per location) did **not** run, and **12 auditor candidates were not yet judged** (listed at the end). Verification of the incremental run used a single refuter per claim (per user request); most bugs also carry 2–3 votes from earlier rounds. No Julia was executed (per standing instruction) — all findings are static.

## Summary

| Location | bug | perf | doc-error | typo | grammar | style | total |
|---|---|---|---|---|---|---|---|
| SRC | 8 | 1 | 23 | 5 | 13 | 4 | **54** |
| EXT | 6 | 1 | 20 | 12 | 10 | 4 | **53** |
| DOCS | 6 | 0 | 24 | 15 | 33 | 0 | **78** |
| TEST | 5 | 0 | 3 | 2 | 2 | 11 | **23** |
| OTHER | 1 | 0 | 0 | 0 | 0 | 0 | **1** |
| **Total** | **26** | **2** | **70** | **34** | **58** | **19** | **209** |

> Labels: **bug** = logic/correctness; **perf** = avoidable work in a hot path; **doc-error** = wrong docstring/comment/markdown semantics; **typo** = misspelling/markdown; **grammar** = prose agreement/article/tense; **style** = dead/duplicated/unused code.

---

## ⭐ Highest-impact findings (bugs & performance — fix first)

- ⭐ **`ext/NCFileReaderExt.jl:132`** `[bug]` — Eager 3-arg get! evaluates its default unconditionally, so a new NCDataset is opened (and leaked unclosed) on every construction even when the file is already registered (the shared-dataset use case). **Fix:** Use the lazy do-block form: get!(OPEN_NCFILES, file_paths) do (NCDataset(...), Set([varname])) end.
- ⭐ **`ext/NCFileReaderExt.jl:249`** `[bug]` — Dated read(reader,date) cache-miss path computes the slice and returns it but never stores it in _cached_reads (only the DateTime(0) static path uses get!); the LRU cache is dead for time-varying data, so every timed read re-reads from disk and re-runs preprocess_func. **Fix:** Wrap the miss path in get!(reader._cached_reads, date) do ... end and return copy(...).
- ⭐ **`ext/NCFileReaderExt.jl:283`** `[bug]` — Static read returns the cached array by reference (no copy), contradicting the ownership convention at L232-235; a caller mutating the return value corrupts the reader private cache. **Fix:** return copy(get!(...) do ... end).
- ⭐ **`test/file_readers.jl:63`** `[bug]` — Two bare comparison expressions (L63-64) with no @test wrapper inside the multi-file aggregation testset: results computed and silently discarded, so that behavior is not actually asserted. **Fix:** Prefix both L63 and L64 with @test.
- **`.github/workflows/ci.yml:42`** `[bug]` — The logical AND is split across two separate ${{ }} template blocks. GitHub Actions substitutes each block independently and concatenates the results into a string like "true && false"; because any non-empty string is truthy in an if conditional, this condition is effectively ALWAYS TRUE. The codecov upload therefore runs on every matrix job (macOS, Windows, and Julia 1.12) instead of only ubuntu-latest + Julia 1.10 as intended. **Fix:** Combine into one expression: `if: ${{ matrix.version == '1.10' && matrix.os == 'ubuntu-latest' }}`
- **`docs/src/climaartifacts.md:73`** `[bug]` — `context` is never defined; the context variable created on line 71 is `my_mpi_context`. This example would throw UndefVarError. **Fix:** Change `context` to `my_mpi_context`
- **`docs/src/datahandling.md:146`** `[bug]` — `regridded_snaphsot` is a misspelling of `regridded_snapshot` (the actual function, src/DataHandling.jl:59). This code would throw UndefVarError. Same typo on line 147. **Fix:** Change `regridded_snaphsot` to `regridded_snapshot` on lines 146 and 147
- **`docs/src/datastructures.md:52`** `[bug]` — The 3-arg `get!(cache, key, default)` evaluates `default` eagerly, so `factorial(n - 1)` is always computed recursively regardless of the cache. The cache provides zero speedup, contradicting the comments on lines 54/56 ('The second time it will only compute the last element'). Verified: Base.get!(cache::LRUCache,key,default::V) in src/DataStructures.jl takes default by value (eager). **Fix:** Use the lazy do-block form: `return n * get!(cache, n - 1) do; factorial(n - 1) end`
- **`docs/src/filereaders.md:65`** `[bug]` — The comment on line 64 says 'Change units for v' and the variable is `v_var`, but the variable name argument is "u" (copy-pasted from line 63). It should read variable "v". **Fix:** Change the second argument from "u" to "v"
- **`docs/src/regridders.md:114`** `[bug]` — Regridding is done by `regrid`, not by re-calling the constructor. `InterpolationsRegridder(reg, data, dimensions)` matches no method (the constructor takes a target_space); the real API is `Regridders.regrid(regridder, data, dimensions)` (ext/InterpolationsRegridderExt.jl:152). Same error on line 115. **Fix:** Change both lines to `Regridders.regrid(reg, data, dimensions)` / `Regridders.regrid(reg, 2 .* data, dimensions)`
- **`docs/src/timemanager.md:69`** `[bug]` — `@show "time1"` echoes the string literal ('"time1" = "time1"') rather than displaying the `time1` value, which is almost certainly the intent given the surrounding accessor calls. **Fix:** Drop the quotes: `@show time1 counter(time1) period(time1) epoch(time1) date(time1)`.
- **`ext/NCFileReaderExt.jl:242`** `[bug]` — In read(file_reader, date), the DateTime(0) sentinel branch returns the value produced by get!(...) do ... directly, i.e. the exact array object stored in the LRU cache, with no copy. On the first read the caller receives an alias of the cached array, so mutating the returned array silently corrupts the file reader's private cache. This is the same missing-copy defect as the static read() at L283 but a distinct code path/method. **Fix:** Wrap the get! result in copy(...), matching the haskey branch at L237, e.g. return copy(get!(file_reader._cached_reads, date) do ... end).
- **`ext/TimeVaryingInputs0DExt.jl:76`** `[perf]` — Enclosing function TimeVaryingInputs.evaluate!(destination, itp::InterpolatingTimeVaryingInput0D, time, args...) is the per-timestep entry point for 0D time-varying inputs (called every simulation step to fill the destination field with the interpolated scalar). It allocates a fresh 1-element heap Vector `[zero(eltype(destination))]` on every call solely to receive the scalar result of the inner evaluate! and then fill!s destination with it. This is an avoidable per-call heap allocation (scalar-sized, so GC pressure only, not grid-sized). **Fix:** Preallocate a 1-element buffer (or a Ref/0-dim array) once in the InterpolatingTimeVaryingInput0D struct and reuse it here instead of allocating `[zero(eltype(destination))]` each call.
- **`ext/TimeVaryingInputsExt.jl:218`** `[bug]` — In the Flat extrapolation branch, `time <= date_init` is a bare boolean expression that is evaluated and discarded (dead no-op), and the enclosing `else` then unconditionally returns the `date_init` snapshot. As a result, for every `time < date_end` — including in-range times where date_init < time < date_end — the code returns the boundary value at date_init instead of interpolating. The Flat docstring (src/TimeVaryingInputs.jl:142) states the boundary value is used only when interpolating OUTSIDE the range, so in-range Flat evaluations are wrong. The orphaned `time <= date_init` is clearly the leftover of an original `elseif time <= date_init` condition whose interpolation `else` branch was dropped. **Fix:** Restore correct branching: change the `else` on line 217 to `elseif time <= date_init` (keeping the `regridded_snapshot!(dest, itp.data_handler, date_init)`), and add an inner `else` that forwards to `TimeVaryingInputs.evaluate!(dest, itp, time, itp.method)` so in-range times interpolate. (Equivalently, add `&& !(date_init <= time <= date_end)` to the Flat check on line 212.)
- **`ext/time_varying_inputs_linearperiodfilling.jl:348`** `[bug]` — In the 'date earlier than interpolable region' branch, date_pre is moved to the NEXT period (target_period + period). The comment (lines 344-345) says 'bring it to the previous period' and the example (line 342) expects Date(1986,2,17), the previous period. The symmetric first case uses target_period for the earlier bound. As written, date_pre lands after both time and date_post, so coeff=(time-date_pre)/(date_post-date_pre) is inverted/out of [0,1], producing wrong interpolation for dates before the interpolable region. **Fix:** Change `target_period + period` to `target_period - period`.
- **`src/ClimaArtifacts.jl:149`** `[bug]` — The constant-string branch is missing the MPI barrier that the variable-name branch has. In the else branch (lines 229-231) `push!(ACCESSED_ARTIFACTS,...)` is immediately followed by `isnothing(context) || Base.invokelatest(barrier, context)` before the second `_artifact_str` call. Here the barrier is absent, so in an MPI context non-root processes proceed to the second `_artifact_str` call without waiting for the root to finish downloading a (lazy) artifact referenced by a constant name. This is exactly the race condition the twice-call comment (lines 122-124) and docstring (lines 30-32: 'the other wait until the file is fully downloaded') claim to prevent. **Fix:** Insert between lines 149 and 150: `isnothing($(esc(context))) || Base.invokelatest(barrier, $(esc(context)))`, mirroring lines 230-231.
- **`src/OutputPathGenerator.jl:44`** `[bug]` — With attempt starting at 1 and the condition attempt < max_attempts, check_func runs only max_attempts-1 times (9 times for the default 10), contradicting the docstring's 'trying up to max_attempts times'. Off-by-one. **Fix:** Use 'while attempt <= max_attempts' (or start attempt = 0) so it tries max_attempts times, or adjust the docstring.
- **`src/OutputPathGenerator.jl:264`** `[bug]` — On the Windows/EPERM junction fallback, the target is computed as abspath("output_XXXX"), which resolves relative to the current working directory and drops the output_path prefix. The actual created folder is new_output_folder = joinpath(output_path, "output_XXXX") (line 243-244). So the NTFS junction points to <cwd>/output_XXXX instead of <cwd>/output_path/output_XXXX, producing a broken/incorrect output_active link whenever output_path != cwd. **Fix:** Use the real target folder: dest_active_link = abspath(new_output_folder)
- **`src/OutputPathGenerator.jl:353`** `[bug]` — possible_restart_files come from readdir(previous_folder) (line 350), which returns bare file names, not full paths. The default sort_func=sort_by_creation_time does stat(x).ctime (Utils.jl:412), so it stats the names relative to cwd; those paths don't exist there, stat returns ctime=0 for all, and the stable sort leaves readdir (alphabetical) order untouched. Result: when a directory holds multiple matching restart files, the 'most recent' selection is not actually by creation time as documented. The test's custom sort_func (test/output_path_generator.jl:239-242) explicitly joinpaths, confirming elements are bare names. **Fix:** Sort full paths, e.g. restart_file_name = last(sort_func(joinpath.(previous_folder, possible_restart_files))) and set restart_file = restart_file_name directly.
- **`src/SpaceVaryingInputs.jl:36`** `[bug]` — This `if` block that prints 'You might also need a regridder...' is placed INSIDE the `for (pkg, fns) in extension_fns` loop. Since extension_fns has two entries (:ClimaCore and :NCDatasets), the hint message is printed twice for any SpaceVaryingInput MethodError. Sibling files place this block OUTSIDE the loop so it prints once (DataHandling.jl lines 111-116, TimeVaryingInputs.jl lines 346-351). **Fix:** Move the `if Symbol(exc.f) == :SpaceVaryingInput ... end` block outside/after the `for (pkg, fns) in extension_fns` loop, matching the pattern in DataHandling.jl and TimeVaryingInputs.jl.
- **`src/TimeVaryingInputs.jl:338`** `[bug]` — The `TimeVaryingInputs` module calls `is_pkg_loaded` but never imports or defines it (only `Dates` is imported at lines 33-34). Every sibling module imports it: FileReaders.jl:13, DataHandling.jl:43, SpaceVaryingInputs.jl:18 all have `import ClimaUtilities.Utils: is_pkg_loaded`, and Regridders.jl:74 fully-qualifies it. This looks like a missed import from commit f606142 ('Move duplicate is_pkg_loaded to Utils'). When the registered MethodError hint fires (a MethodError on TimeVaryingInput/evaluate!), the closure will throw UndefVarError: is_pkg_loaded instead of printing the helpful hint. **Fix:** Add `import ClimaUtilities.Utils: is_pkg_loaded` near the top of the module (after line 34), matching sibling modules.
- **`src/Utils.jl:40`** `[perf]` — linear_interpolation is called per-timestep inside TimeVaryingInputs.evaluate! (ext/TimeVaryingInputs0DExt.jl:237). After the O(log N) searchsortedfirst on line 39 already yields `id`, `indep_value in indep_vars` performs a redundant O(N) linear scan of the entire (sorted) time axis on every evaluation. For 0D inputs with a long time axis (e.g., hourly data over years) this is significant avoidable repeated work on a hot path; the exact-match check is available in O(1) from `id`. **Fix:** Replace the O(N) membership scan with an O(1) index check using the already-computed `id`: `(id <= N && indep_vars[id] == indep_value) && return dep_vars[id]`.
- **`src/Utils.jl:188`** `[bug]` — For the `Week` period, beginningofperiod does not normalize the time-of-day: when `date` is a DateTime with a nonzero time, `date - Day(...)` keeps that time, so the result is e.g. 1993-11-15T13:30 instead of the start-of-week 00:00. Every other branch (Year/Month/Day) resets the time to 00:00, making Week the odd one out. **Fix:** Strip the time first: `return DateTime(Date(date) - Day(dayofweek(date) - 1))`.
- **`src/Utils.jl:236`** `[bug]` — endofperiod for a `Week` computes the Sunday's day-of-month via raw arithmetic on `day(date)`, which overflows the month near month-end. E.g. Date(1993,11,30) (Tuesday, dayofweek=2) gives DateTime(1993, 11, 30+7-2=35, ...) -> DateTime day out of range, an error. beginningofperiod's Week branch avoids this by using date subtraction. **Fix:** Compute via safe date arithmetic, e.g. `sunday = date + Day(7 - dayofweek(date)); return DateTime(Date(sunday)) + Day(1) - Second(1)` (Sunday 23:59:59) instead of feeding an out-of-range day into the DateTime constructor.
- **`test/file_readers.jl:37`** `[bug]` — This test is preceded by the comment "Read it a second time to check that the cache works" (line 36) but is a verbatim duplicate of the assertion at lines 30-31 (read(ncreader_u, DateTime(2021,01,01,01)) == nc["u10n"][:,:,2]). It re-reads from disk and compares to disk, so it passes identically whether or not caching occurs and cannot detect caching at all. Cross-checking ext/NCFileReaderExt.jl `read(file_reader, date)` (lines 231-262): for a non-sentinel date the function returns the freshly read slice WITHOUT ever writing to `_cached_reads` (only the static DateTime(0) branch uses get!). Thus the cache is never populated for time-varying reads and the top-of-function `haskey(_cached_reads, date)` branch is dead — a real src bug that this test silently masks while claiming to verify the cache. **Fix:** Make the test actually exercise caching, e.g. assert the value is present in the reader's cache after the first read (haskey(ncreader_u._cached_reads, DateTime(2021,01,01,01))) and/or that a second read returns a cached (copied) result; and fix ext/NCFileReaderExt.jl `read(file_reader, date)` to store the read array into `_cached_reads` on a cache miss.
- **`test/regridders.jl:610`** `[bug]` — err_x/err_y/err_z (lines 610-612) are computed WITHOUT abs.(), then checked with `@test maximum(err) < 1e-5` (lines 614-616). maximum() of a signed error array only bounds the largest positive error; a systematic positive bias (regridded > coordinate) would make all errors negative and pass trivially. Every other error check in this file (lines 252, 326-327, 348, 356) uses abs.(), so this one masks potential regressions. **Fix:** Wrap each error in abs.(): `err_x = abs.(reg_box.coordinates.x .- regridded_x)` (and likewise err_y, err_z), matching the abs.() pattern used elsewhere.
- **`test/time_varying_inputs.jl:293`** `[bug]` — `time` is not the loop variable (that is `times`); `time` resolves to `Base.time`, a Function, so `eltype(time)` is `Any` and `Any <: Number` is always false. This entire block (lines 294-305) never runs, silently disabling the only test that checks linear-interpolation VALUES against a manually computed `expected` (searchsortedfirst-based interp), leaving linear interpolation correctness unverified for all float-time cases. **Fix:** Change `eltype(time)` to `eltype(times)`.
- **`test/time_varying_inputs.jl:359`** `[bug]` — Same defect as line 293: `time` resolves to `Base.time` (a Function), so `eltype(time) <: Number` is always false and the `@test Array(parent(dest))[1] ≈ expected` is never executed. The 'In between t_end and t_init' periodic linear-interpolation assertion (using `expected` from lines 351-353) is silently skipped, so that interpolation path is never actually checked. **Fix:** Change `eltype(time)` to `eltype(times)`.

---

## SRC

### `src/ClimaArtifacts.jl`
- **L149** `[bug]` — The constant-string branch is missing the MPI barrier that the variable-name branch has. In the else branch (lines 229-231) `push!(ACCESSED_ARTIFACTS,...)` is immediately followed by `isnothing(context) || Base.invokelatest(barrier, context)` before the second `_artifact_str` call. Here the barrier is absent, so in an MPI context non-root processes proceed to the second `_artifact_str` call without waiting for the root to finish downloading a (lazy) artifact referenced by a constant name. This is exactly the race condition the twice-call comment (lines 122-124) and docstring (lines 30-32: 'the other wait until the file is fully downloaded') claim to prevent. **Fix:** Insert between lines 149 and 150: `isnothing($(esc(context))) || Base.invokelatest(barrier, $(esc(context)))`, mirroring lines 230-231.
- **L105** `[doc-error]` — This comment sits inside the `if isa(name, AbstractString)` TRUE branch, i.e. the case where `name` IS a constant string and the slash-lookup/meta/lazy checks are actually done at compile time (lines 86-104). The comment (identical copy at lines 173-174 in the else branch, where it is correct) contradicts the adjacent code, being copy-pasted from the variable branch. **Fix:** Remove the two-line comment at lines 105-106, or replace it with one describing the constant-name compile-time handling.
- **L32** `[grammar]` — Number disagreement: 'only one process downloads the file, while the other wait' — 'the other' (singular) with plural verb 'wait'. Should refer to the remaining processes.

### `src/DataHandling.jl`
- **L38** `[doc-error]` — The module docstring claims the LRU cache default max size is 128, but the actual DataHandler constructor uses `cache_max_size::Int = 2` (ext/DataHandlingExt.jl lines 133 and 207), and that file's own docstring (line 148) says 'the default size for the cache is only two fields'. The 128 figure is wrong. **Fix:** Change '(128 by default)' to '(2 by default)'.

### `src/DataStructures.jl`
- **L108** `[doc-error]` — Docstring signature declares cache1 as LRUCache{K1, V2}, reusing V2 (which belongs to cache2). The actual method (line 112-115) declares cache1::LRUCache{K1, V1}. The value type parameter of the first cache should be V1. **Fix:** Change the header to `==(cache1::LRUCache{K1, V1}, cache2::LRUCache{K2, V2})`.
- **L148** `[doc-error]` — Docstring signature names the first argument `default`, but the method (line 153) names it `f`, and the docstring body (line 151) refers to `f()`. The signature header does not match the actual argument name. **Fix:** Change the header to `Base.get(f::Callable, cache::LRUCache{K, V}, key::K)`.
- **L286** `[doc-error]` — Docstring claims items are removed (plural) 'until its size is less than or equal to max_size', implying a loop, but the implementation uses `if` (line 290) and removes at most one item per call. Only correct because callers add one key at a time. **Fix:** Either reword to state that a single least-recently-used item is removed, or change the `if` on line 290 to a `while` loop to match the stated behavior.
- **L200** `[grammar]` — Missing verb 'be': 'key_type is assumed to the key type' should read 'is assumed to be the key type'.
- **L252** `[style]` — Base.delete!(dict, key) returns the dictionary, not the removed value, so `value` holds the Dict, is misnamed, and is never used (the function returns `cache`). Dead/misleading assignment.
- **L267** `[style]` — The preceding error("Merge not implemented for LRUCache") always throws, making this `return nothing` unreachable dead code.

### `src/ITime.jl`
- **L44** `[doc-error]` — Docstring signature header shows `period` as a keyword with no default, but the actual method (lines 56-60) defines `period::Union{Dates.FixedPeriod, Nothing} = nothing`. The body of the docstring even says 'If period is not provided...', confirming it is optional, so the header is wrong. **Fix:** Change the header to `period::Union{Dates.FixedPeriod, Nothing} = nothing`.
- **L14** `[typo]` — Docstring says 'in the future in will be possible'; the second 'in' should be 'it'.
- **L209** `[typo]` — Comment reads 'obtained my multiplying'; 'my' should be 'by'.
- **L348** `[typo]` — The result of `mod` is the remainder; the local variable is misspelled `reminder` (used again on line 349). Harmless to execution but a clear identifier typo.
- **L138** `[grammar]` — Article disagreement: 'a `epoch`' should be 'an `epoch`' (epoch begins with a vowel sound).
- **L343** `[grammar]` — Ungrammatical 'after promote `x` and `y`'; should be 'after promoting'. Same phrasing repeated in the `%` docstring at line 355.
- **L217** `[style]` — The `counter(time) isa Integer` guard is always true: the struct is parameterized `ITime{INT <: Integer, ...}` and `counter::INT`, so any constructed ITime necessarily has an Integer counter. The condition is dead/redundant.

### `src/OnlineLogging.jl`
- **L11** `[doc-error]` — References a function named `update!` (twice), but no such function exists in the module; the incrementing/skipping logic lives in `_update!`. Other field docstrings (lines 20, 22) correctly reference `_update!`, so this is an inconsistent/stale name. **Fix:** Replace both `update!` occurrences here (and on line 12) with `_update!`.
- **L18** `[doc-error]` — Comment names `update_progress_reporter!`, a function that does not exist anywhere in the repo. The step-skipping described here is actually performed by `_update!` (see the `should_record_measurement` guard on lines 74-83). **Fix:** Replace `update_progress_reporter!` with `_update!`.
- **L36** `[doc-error]` — The `WallTimeInfo(...)` docstring signature has an unbalanced/extra closing paren: line 35 already closes the call (`typemin(Float64))`), making the lone `)` on line 36 a stray extra parenthesis. **Fix:** Remove the extra `)` on line 36 (or move the closing paren so the call is balanced once).
- **L59** `[doc-error]` — The docstring signature header omits the required second positional argument. The actual method (line 70) is `_update!(wt::WallTimeInfo, integrator)`; the body relies on `integrator.t`, `integrator.dt`, and `integrator.sol.prob.tspan`. **Fix:** Change header to `_update!(wt::WallTimeInfo, integrator)`.
- **L163** `[doc-error]` — The usage example imports `report_progress`, which does not exist in this module. The public function is `report_walltime` (confirmed by test/onlinelogging.jl, docs/src/onlinelogging.md, and the docstring header on line 107). Copy-pasting this example would fail with an import error. `report_progress` appears to be a stale pre-rename name (see NEWS.md). **Fix:** Change `report_progress` to `report_walltime`.
- **L174** `[doc-error]` — The docstring example (and its import on line 163: `WallTimeInfo, report_progress`) references `report_progress`, which does not exist in this module — the function is `report_walltime`. The example would error on import/use. **Fix:** Replace `report_progress` with `report_walltime` on both line 163 and line 174.
- **L224** `[doc-error]` — The docstring refers to the argument as `x`, but the parameter is named `seconds` (signature line 222 / method line 226). No `x` argument exists. **Fix:** Change "given a time `x` in Seconds" to "given a time `seconds` in seconds".
- **L12** `[grammar]` — 'intended to be call' is ungrammatical (also the referenced `update!` is actually `_update!`).
- **L20** `[grammar]` — Missing preposition; "Sum of elapsed walltime all the calls" is garbled.
- **L150** `[grammar]` — Subject-verb agreement error: "It also have to have" should be "It also has to have".

### `src/OutputPathGenerator.jl`
- **L44** `[bug]` — With attempt starting at 1 and the condition attempt < max_attempts, check_func runs only max_attempts-1 times (9 times for the default 10), contradicting the docstring's 'trying up to max_attempts times'. Off-by-one. **Fix:** Use 'while attempt <= max_attempts' (or start attempt = 0) so it tries max_attempts times, or adjust the docstring.
- **L264** `[bug]` — On the Windows/EPERM junction fallback, the target is computed as abspath("output_XXXX"), which resolves relative to the current working directory and drops the output_path prefix. The actual created folder is new_output_folder = joinpath(output_path, "output_XXXX") (line 243-244). So the NTFS junction points to <cwd>/output_XXXX instead of <cwd>/output_path/output_XXXX, producing a broken/incorrect output_active link whenever output_path != cwd. **Fix:** Use the real target folder: dest_active_link = abspath(new_output_folder)
- **L353** `[bug]` — possible_restart_files come from readdir(previous_folder) (line 350), which returns bare file names, not full paths. The default sort_func=sort_by_creation_time does stat(x).ctime (Utils.jl:412), so it stats the names relative to cwd; those paths don't exist there, stat returns ctime=0 for all, and the stable sort leaves readdir (alphabetical) order untouched. Result: when a directory holds multiple matching restart files, the 'most recent' selection is not actually by creation time as documented. The test's custom sort_func (test/output_path_generator.jl:239-242) explicitly joinpaths, confirming elements are bare names. **Fix:** Sort full paths, e.g. restart_file_name = last(sort_func(joinpath.(previous_folder, possible_restart_files))) and set restart_file = restart_file_name directly.
- **L111** `[doc-error]` — The docstring signature for the top-level generate_output_path shows context = nothing, but the method (line 136) defaults context = ClimaComms.context(). It should also use a semicolon (keyword args), not a comma. **Fix:** Change to '; context = ClimaComms.context(),' to match the method definition.
- **L146** `[doc-error]` — The RemovePreexistingStyle method actually defaults context = ClimaComms.context() (line 153), not nothing; args are keyword (semicolon), not positional. **Fix:** Change to 'generate_output_path(::RemovePreexistingStyle, output_path; context = ClimaComms.context())'.
- **L316** `[doc-error]` — The Arguments section documents an argument named `output_dir_style`, but detect_restart_file has no such argument; the keyword is named `style` (line 328, and shown as `style` in the signature header at line 284). The real `style` kwarg is never documented. **Fix:** Rename `output_dir_style` to `style` in the Arguments list.
- **L28** `[typo]` — Docstring references `max_attempt`, but the actual keyword argument is `max_attempts` (line 40).
- **L89** `[grammar]` — 'a `output_active`' should be 'an `output_active`' since 'output' starts with a vowel sound; same error recurs on line 93 ('does not contain a `output_active`').
- **L130** `[grammar]` — Garbled/duplicated words: 'This is style is non-destructive.' contains a stray/duplicated 'is'.

### `src/Regridders.jl`
- **L4** `[grammar]` — Subject-verb agreement error: the singular subject 'module' takes 'implements', not 'implement'. Compare FileReaders.jl line 4 which correctly says 'module implements backends'.

### `src/SpaceVaryingInputs.jl`
- **L36** `[bug]` — This `if` block that prints 'You might also need a regridder...' is placed INSIDE the `for (pkg, fns) in extension_fns` loop. Since extension_fns has two entries (:ClimaCore and :NCDatasets), the hint message is printed twice for any SpaceVaryingInput MethodError. Sibling files place this block OUTSIDE the loop so it prints once (DataHandling.jl lines 111-116, TimeVaryingInputs.jl lines 346-351). **Fix:** Move the `if Symbol(exc.f) == :SpaceVaryingInput ... end` block outside/after the `for (pkg, fns) in extension_fns` loop, matching the pattern in DataHandling.jl and TimeVaryingInputs.jl.

### `src/TimeManager.jl`
- **L83** `[doc-error]` — The `trigger_callback` docstring signature header (lines 80-83) ends after `func::Function` and omits the fifth positional argument `func_args::Tuple` that the actual method (lines 99-105) requires. The '# Arguments' section does list `func_args`, so the header is inconsistent/incomplete. **Fix:** Add `func_args::Tuple` to the signature header, e.g. `func::Function,\n        func_args::Tuple,)`.
- **L68** `[style]` — Redundant double `string(string(...))` wrapping; `lpad` already returns a String. This line is the odd-one-out — the year (line 67) and day (line 69) lines use a single `string(lpad(...))`.

### `src/TimeVaryingInputs.jl`
- **L338** `[bug]` — The `TimeVaryingInputs` module calls `is_pkg_loaded` but never imports or defines it (only `Dates` is imported at lines 33-34). Every sibling module imports it: FileReaders.jl:13, DataHandling.jl:43, SpaceVaryingInputs.jl:18 all have `import ClimaUtilities.Utils: is_pkg_loaded`, and Regridders.jl:74 fully-qualifies it. This looks like a missed import from commit f606142 ('Move duplicate is_pkg_loaded to Utils'). When the registered MethodError hint fires (a MethodError on TimeVaryingInput/evaluate!), the closure will throw UndefVarError: is_pkg_loaded instead of printing the helpful hint. **Fix:** Add `import ClimaUtilities.Utils: is_pkg_loaded` near the top of the module (after line 34), matching sibling modules.
- **L93** `[doc-error]` — `!!! warn` is not a valid Documenter admonition category; the valid one is `warning`. It will render as a generic/default admonition rather than a warning box. **Fix:** Change `!!! warn` to `!!! warning`.
- **L166** `[doc-error]` — Orphaned setext-style divider: line 166 is a bare `=======` preceded by a blank line (165) with no title text above it, so it is not a valid section header. It renders as a stray paragraph of equals signs / malformed section break (the preceding sections at lines 156 and 161 have their titles directly above the underline). **Fix:** Add the intended section title on the line directly above (or remove the orphan `=======` line).
- **L175** `[doc-error]` — The example defines the function `CO2fromp` on line 174 but then constructs the input with a different, undefined name `CO2fromY`. Copy-paste mismatch; the example does not run as written. **Fix:** Change `CO2fromY` to `CO2fromp` (or rename the definition to match).
- **L240** `[doc-error]` — The docstring signature names the second positional argument `extrapolation_bc`, but the actual constructor (line 308-311) names it `bc`. The docstring also omits the defaults that the real method provides (`period = Year(1)`, `bc = Throw()`), so it does not reflect that the constructor can be called with no arguments. **Fix:** Match the docstring to the method: `LinearPeriodFillingInterpolation(period::Dates.DatePeriod = Year(1), bc::AbstractInterpolationBoundaryMethod = Throw())`.
- **L273** `[grammar]` — Garbled phrasing 'would interpolate use data' — verb 'interpolate' and 'use' are stacked without a connector.
- **L282** `[grammar]` — 'let get' is missing a subject/contraction.

### `src/Utils.jl`
- **L188** `[bug]` — For the `Week` period, beginningofperiod does not normalize the time-of-day: when `date` is a DateTime with a nonzero time, `date - Day(...)` keeps that time, so the result is e.g. 1993-11-15T13:30 instead of the start-of-week 00:00. Every other branch (Year/Month/Day) resets the time to 00:00, making Week the odd one out. **Fix:** Strip the time first: `return DateTime(Date(date) - Day(dayofweek(date) - 1))`.
- **L236** `[bug]` — endofperiod for a `Week` computes the Sunday's day-of-month via raw arithmetic on `day(date)`, which overflows the month near month-end. E.g. Date(1993,11,30) (Tuesday, dayofweek=2) gives DateTime(1993, 11, 30+7-2=35, ...) -> DateTime day out of range, an error. beginningofperiod's Week branch avoids this by using date subtraction. **Fix:** Compute via safe date arithmetic, e.g. `sunday = date + Day(7 - dayofweek(date)); return DateTime(Date(sunday)) + Day(1) - Second(1)` (Sunday 23:59:59) instead of feeding an out-of-range day into the DateTime constructor.
- **L40** `[perf]` — linear_interpolation is called per-timestep inside TimeVaryingInputs.evaluate! (ext/TimeVaryingInputs0DExt.jl:237). After the O(log N) searchsortedfirst on line 39 already yields `id`, `indep_value in indep_vars` performs a redundant O(N) linear scan of the entire (sorted) time axis on every evaluation. For 0D inputs with a long time axis (e.g., hourly data over years) this is significant avoidable repeated work on a hot path; the exact-match check is available in O(1) from `id`. **Fix:** Replace the O(N) membership scan with an O(1) index check using the already-computed `id`: `(id <= N && indep_vars[id] == indep_value) && return dep_vars[id]`.
- **L54** `[doc-error]` — Docstring signature header is malformed and does not match the method. It is missing the closing `)`, and the shown default `sqrt(eps(eltype(v)))` is wrong: the real default is `eltype(v) <: AbstractFloat ? sqrt(eps(eltype(v))) : eps()` (for integer vectors it is `eps()`, since `eps(Int)` does not exist). The Arguments section (lines 61-62) repeats the same wrong default. **Fix:** Change header to `isequispaced(v; tol = eltype(v) <: AbstractFloat ? sqrt(eps(eltype(v))) : eps())` and update the Arguments default description to match.
- **L122** `[doc-error]` — The wrap_time docstring introduces the examples with `extend_past_t_end = false`, but the function `wrap_time(time, t_init, t_end)` has no such keyword argument (grep finds it nowhere else in the repo). Stale/incorrect reference to a nonexistent kwarg. **Fix:** Delete the `With `extend_past_t_end = false`:` line (and any implied kwarg wording); the examples apply to the single-signature `wrap_time(time, t_init, t_end)`.
- **L400** `[typo]` — The `;` is placed inside the `map(...)` parentheses (`...];)`), so it is a stray keyword-arg separator rather than an output-suppressing trailing semicolon like the surrounding example lines intend.
- **L30** `[grammar]` — Incorrect article: "a independent" should be "an independent".

---

## EXT

### `ext/DataHandlingExt.jl`
- **L27** `[doc-error]` — The struct docstring's type-parameter list ends at `FUNC` (lines 19-28), but the actual struct (lines 50-61) has two additional parameters, `NAMES <: AbstractArray{<:AbstractString}` and `PR <: AbstractDict{<:AbstractString, <:AbstractArray}`, that are omitted from the docstring. **Fix:** Add `NAMES` and `PR` (with their bounds) to the docstring's type-parameter list to match the definition.
- **L131** `[doc-error]` — Docstring constructor header declares `start_date::Dates.DateTime`, but the real method accepts `start_date::Union{Dates.DateTime, Dates.Date}`. The header also omits the `compose_function` keyword entirely (it is only described in the keyword-arguments prose below). **Fix:** Update the header type to `Union{Dates.DateTime, Dates.Date}` and add `compose_function = identity` to the shown kwargs.
- **L460** `[doc-error]` — The docstring signature and body were copy-pasted from `time_to_date`: the real method takes `date::Dates.DateTime` (not `time::AbstractFloat`), and the code block `date = start_date + time` describes time_to_date, not date_to_time (which computes `period_to_seconds_float(date - start_date)`). **Fix:** Change the header arg to `date::Dates.DateTime` and the code block to `time = period_to_seconds_float(date - start_date)`.
- **L533** `[doc-error]` — Docstring signature header names the argument `time`, but the method parameter is `date::Dates.TimeType` (the prose below correctly refers to `date`). **Fix:** Rename the header argument to `date`: `previous_date(data_handler::DataHandler, date::Dates.TimeType)`.
- **L554** `[doc-error]` — Docstring signature header names the argument `time`, but the method parameter is `date::Dates.TimeType`; the following description also says "after the given `time`" while the arg is a date. **Fix:** Rename to `next_date(data_handler::DataHandler, date::Dates.TimeType)` and use `date` in the description.
- **L557** `[doc-error]` — `next_date`'s docstring claims it returns the same date when `date` is a snapshot, but the code returns the NEXT date (index+1, line 563). This line was copy-pasted from `previous_date` (where returning itself is correct). Compare `next_time`'s docstring which correctly says 'return the next time'. **Fix:** Change to 'If `date` is one of the snapshots, return the next date.' (and rename the arg to `date` in the signature line).
- **L111** `[typo]` — Doubled word "not not" in the comment.
- **L31** `[grammar]` — "the most efficiently way" uses an adverb where an adjective is required.

### `ext/InterpolationsRegridderExt.jl`
- **L53** `[doc-error]` — Missing comma after `dim_names::Union{Nothing, Tuple}` in the docstring keyword-argument list; the preceding kwargs (extrapolation_bc, dim_increasing) are comma-separated, so the header is malformed before `interpolation_method` on the next line. **Fix:** Add a trailing comma: `dim_names::Union{Nothing, Tuple},`.
- **L72** `[doc-error]` — Claims the default extrapolation_bc for '3D spaces' is (Periodic, Flat, Throw), but that is only the LatLongZ default; XYZ 3D spaces default to (Flat, Flat, Throw) per the constructor (line 114). **Fix:** Qualify the statement, e.g. 'For lat-long-z spaces, the default is ...' and note XYZ spaces default to (Flat, Flat, Throw).
- **L77** `[grammar]` — Extra article: 'The default is the `true` for each spatial dimension' should not have 'the' before the code span.

### `ext/NCFileReaderExt.jl`
- **L132** `[bug]` — Eager 3-arg get! evaluates its default unconditionally, so a new NCDataset is opened (and leaked unclosed) on every construction even when the file is already registered (the shared-dataset use case). **Fix:** Use the lazy do-block form: get!(OPEN_NCFILES, file_paths) do (NCDataset(...), Set([varname])) end.
- **L242** `[bug]` — In read(file_reader, date), the DateTime(0) sentinel branch returns the value produced by get!(...) do ... directly, i.e. the exact array object stored in the LRU cache, with no copy. On the first read the caller receives an alias of the cached array, so mutating the returned array silently corrupts the file reader's private cache. This is the same missing-copy defect as the static read() at L283 but a distinct code path/method. **Fix:** Wrap the get! result in copy(...), matching the haskey branch at L237, e.g. return copy(get!(file_reader._cached_reads, date) do ... end).
- **L249** `[bug]` — Dated read(reader,date) cache-miss path computes the slice and returns it but never stores it in _cached_reads (only the DateTime(0) static path uses get!); the LRU cache is dead for time-varying data, so every timed read re-reads from disk and re-runs preprocess_func. **Fix:** Wrap the miss path in get!(reader._cached_reads, date) do ... end and return copy(...).
- **L283** `[bug]` — Static read returns the cached array by reference (no copy), contradicting the ownership convention at L232-235; a caller mutating the return value corrupts the reader private cache. **Fix:** return copy(get!(...) do ... end).
- **L75** `[doc-error]` — Docstring signature header uses a single colon 'cache_max_size:Int' but Julia type annotation (and the real method at L93) uses '::'. This is a malformed type annotation in the documented signature. **Fix:** Change 'cache_max_size:Int = 128' to 'cache_max_size::Int = 128'.
- **L48** `[typo]` — Misspelling 'physcial' in the docstring for the dim_names field.
- **L95** `[typo]` — 'standarizing' is a misspelling of 'standardizing'.
- **L126** `[grammar]` — Garbled sentence 'When we have only no time data'. The branch corresponds to the single-file / no-aggregation case (aggtime_kwarg empty), where file_path_to_ncdataset becomes a single string rather than a vector.

### `ext/SpaceVaryingInputsExt.jl`
- **L20** `[doc-error]` — Markdown defect: `` ``data" `` opens with two backticks and closes with a straight double-quote, so the code span is unbalanced and renders incorrectly. **Fix:** Replace ``data" with `data` (balanced single-backtick code span) or "data".
- **L25** `[doc-error]` — ClimaCore LatLong(/Z)Point coordinates expose the field `.long`, not `.lon` (see totuple in InterpolationsRegridderExt.jl using pt.long); the example directs users to access a nonexistent field. **Fix:** Change coords.lon to coords.long.
- **L134** `[doc-error]` — The documented signature for the file_paths method omits the `compose_function = identity` kwarg that the actual method (line 154) accepts and forwards to DataHandler; it also shows `regridder_type::Symbol` while the real default is `regridder_type = nothing`. **Fix:** Add `compose_function = identity` to the documented kwargs and change `regridder_type::Symbol` to `regridder_type = nothing`.
- **L86** `[grammar]` — Garbled sentence: 'we assumed that your struct as a constructor' is missing a verb; 'as' should be 'has'.
- **L5** `[style]` — `searchsortednearest` is imported but never used anywhere in this extension (only linear_interpolation is used, at lines 66 and 120).

### `ext/TempestRegridderExt.jl`
- **L18** `[doc-error]` — Backticks incorrectly wrap the English word "the" together with the identifier; should code-format only `target_space`. **Fix:** Change to "... to the `target_space`."
- **L60** `[doc-error]` — `regrid_dir` is documented twice under "Positional arguments" (also line 58) and it is actually a keyword argument (it follows `;` in the signature at line 71), while the "Keyword arguments" section only lists `mono`. The Positional section also omits nothing but lists `input_file` before `varname`, opposite to the real positional order (target_space, varname, input_file). **Fix:** Remove the duplicate line 60, and move the `regrid_dir` bullet from the Positional arguments section to the Keyword arguments section; fix positional ordering to target_space, varname, input_file.
- **L322** `[doc-error]` — The docstring signature for `hdwrite_regridfile_rll_to_cgll` lists `mono = false` as a positional argument (preceded by a comma), but in the real signature (lines 350-351) `mono` is a keyword argument (after the `;`). The docstring also lacks the `;` separating positional from keyword args. **Fix:** Show `mono` after a `;` in the docstring signature, e.g. `space;\n        mono = false,`.
- **L341** `[doc-error]` — `varnames` is a Vector of names but described in the singular "the name of the variable". **Fix:** Change to "the names of the variables to be remapped".
- **L186** `[typo]` — Docstring signature header spells the first argument `REGIRD_DIR`; the real parameter (line 203) and the Arguments list (line 196) use `REGRID_DIR`.
- **L283** `[typo]` — Comment begins "If doesn't make sense"; should be "It doesn't make sense" (same typo duplicated at line 361).
- **L326** `[typo]` — 'fileneeds' is missing a space; should be 'file needs'.
- **L361** `[typo]` — Comment begins "If doesn't make sense"; should be "It doesn't make sense" (duplicate of line 283).
- **L21** `[grammar]` — "This" is capitalized mid-sentence after "Hence,"; also this documents a struct, not a function.
- **L160** `[style]` — `hspace` is computed but never used afterward (only `topology` and `target` are used by the dss! call); dead assignment.
- **L417** `[style]` — `out_type` is a local constant set to "cgll" (line 353), so this ternary is always true and the `all_nodes` branch (line 419) is unreachable dead code.

### `ext/TimeVaryingInputs0DExt.jl`
- **L76** `[perf]` — Enclosing function TimeVaryingInputs.evaluate!(destination, itp::InterpolatingTimeVaryingInput0D, time, args...) is the per-timestep entry point for 0D time-varying inputs (called every simulation step to fill the destination field with the interpolated scalar). It allocates a fresh 1-element heap Vector `[zero(eltype(destination))]` on every call solely to receive the scalar result of the inner evaluate! and then fill!s destination with it. This is an avoidable per-call heap allocation (scalar-sized, so GC pressure only, not grid-sized). **Fix:** Preallocate a 1-element buffer (or a Ref/0-dim array) once in the InterpolatingTimeVaryingInput0D struct and reuse it here instead of allocating `[zero(eltype(destination))]` each call.
- **L58** `[doc-error]` — The docstring signature header names the wrong type: it says `InterpolatingTimeVaryingInput23D`, but the method it documents (line 62, `Base.in(time, itp::InterpolatingTimeVaryingInput0D)`) is defined on `InterpolatingTimeVaryingInput0D`. This is a copy-paste of the identical docstring from TimeVaryingInputsExt.jl (line 113), where the 23D type is correct. **Fix:** Change `InterpolatingTimeVaryingInput23D` to `InterpolatingTimeVaryingInput0D` in the docstring header on line 58.
- **L148** `[typo]` — The private helper is misspelled `_evalulate_flat!` (extra `ul`); it should be `_evaluate_flat!`. It is spelled the same way at its definition (148) and both call sites (175, 209), so there is no runtime error, but it is a genuine identifier misspelling of `evaluate`.
- **L153** `[style]` — Inside the `else` branch of `_evalulate_flat!`, `time <= t_init` is a bare expression statement whose boolean result is computed and immediately discarded (no-op / dead code). It was almost certainly meant to be a comment (`# time <= t_init`) explaining the else branch; the sibling TimeVaryingInputsExt.jl has the same stray `time <= date_init` at line 218.

### `ext/TimeVaryingInputsExt.jl`
- **L218** `[bug]` — In the Flat extrapolation branch, `time <= date_init` is a bare boolean expression that is evaluated and discarded (dead no-op), and the enclosing `else` then unconditionally returns the `date_init` snapshot. As a result, for every `time < date_end` — including in-range times where date_init < time < date_end — the code returns the boundary value at date_init instead of interpolating. The Flat docstring (src/TimeVaryingInputs.jl:142) states the boundary value is used only when interpolating OUTSIDE the range, so in-range Flat evaluations are wrong. The orphaned `time <= date_init` is clearly the leftover of an original `elseif time <= date_init` condition whose interpolation `else` branch was dropped. **Fix:** Restore correct branching: change the `else` on line 217 to `elseif time <= date_init` (keeping the `regridded_snapshot!(dest, itp.data_handler, date_init)`), and add an inner `else` that forwards to `TimeVaryingInputs.evaluate!(dest, itp, time, itp.method)` so in-range times interpolate. (Equivalently, add `&& !(date_init <= time <= date_end)` to the Flat check on line 212.)
- **L178** `[grammar]` — The deprecation warning message is a garbled sentence missing a conjunction: "`t_start` was removed will be ignored".

### `ext/nc_common.jl`
- **L6** `[doc-error]` — Docstring signature header shows ds::NCDatasets.NCDataset, but the actual method (L12) is defined on ds::NetCDFDataset, the Union of NCDataset and MFDataset. The documented signature is narrower than the real one and misrepresents that the function also accepts multi-file datasets. **Fix:** Change the docstring header type to ds::NetCDFDataset to match the method definition.

### `ext/time_varying_inputs_linearperiodfilling.jl`
- **L348** `[bug]` — In the 'date earlier than interpolable region' branch, date_pre is moved to the NEXT period (target_period + period). The comment (lines 344-345) says 'bring it to the previous period' and the example (line 342) expects Date(1986,2,17), the previous period. The symmetric first case uses target_period for the earlier bound. As written, date_pre lands after both time and date_post, so coeff=(time-date_pre)/(date_post-date_pre) is inverted/out of [0,1], producing wrong interpolation for dates before the interpolable region. **Fix:** Change `target_period + period` to `target_period - period`.
- **L59** `[doc-error]` — The docstring example passes a 1-element vector [DateTime(1993, 8, 18)] as the `date` argument, but the function calls beginningofperiod(date, period) which requires a scalar date (and the sibling example on line 62 uses a scalar). Running this would error. **Fix:** Pass a scalar: _neighboring_periods(DateTime(1993, 8, 18), available_periods, Year(1)).
- **L62** `[doc-error]` — This example in the `_neighboring_periods` docstring calls `_extract_period`, not `_neighboring_periods`. It is a copy-paste leftover from the `_extract_period` docstring (lines 38-39) and does not demonstrate the documented function. **Fix:** Remove the stray _extract_period example (and its output on line 63) from the _neighboring_periods docstring.
- **L140** `[typo]` — Typo in docstring example literal: 'DateTime(199h5, 2, 18)' contains a stray 'h'; should be 'DateTime(1995, 2, 18)'.
- **L281** `[typo]` — The example says interpolating in 1987 'from 1985 and 1985', but coeff = 2/10 = (1987-1985)/(1995-1985); the two bounding periods are 1985 and 1995. The second '1985' should be '1995'.
- **L339** `[typo]` — Comment is missing the word 'earlier' (and has a double space where it belongs). The first case (line 320) reads 'the date is later than the interpolable region'; this branch handles the earlier case.
- **L360** `[typo]` — Misspelling 'coff' should be 'coeff' (matches the variable used and the correct comment on line 278).
- **L11** `[grammar]` — Grammar error: 'used move' is missing 'to' ('used to move'). Also 'viceversa' later on the line should be 'vice versa'.
- **L26** `[grammar]` — Garbled sentence missing a verb: 'because extracting period clearer in intent' should read 'because extracting period is clearer in intent'.
- **L238** `[grammar]` — Grammar error: 'should not used' should be 'should not use'.
- **L339** `[grammar]` — Missing word (and double space): parallels line 320 ('the date is later than'); should read 'earlier than'.

---

## DOCS

### `NEWS.md`
- **L34** `[doc-error]` — 395.5 exceeds the 360-degree longitude range and makes the cell-center example nonsensical; the intended value that yields non-colocated first/last centers is 359.5 (395/359 digit transposition). **Fix:** Change "395.5" to "359.5".
- **L81** `[doc-error]` — Example uses the alias `Intp` (also `Intp.Constant()` on line 86) but the import on line 77 is `import ClimaCore, Interpolations` with no `as Intp`, so `Intp` is undefined. **Fix:** Either import as alias (`import Interpolations as Intp`) or use `Interpolations.Linear()`/`Interpolations.Constant()`.
- **L299** `[doc-error]` — `compose_function` is a keyword argument of TimeVaryingInput (ext/TimeVaryingInputsExt.jl:163), but here it is passed as a bare trailing positional argument after keyword args, so it would not bind to the kwarg (broken example). **Fix:** Change to `compose_function = compose_function)` (or place it inside `(; compose_function)`).
- **L94** `[typo]` — "IterpolationsRegridder" is missing an "n"; the real type is `InterpolationsRegridder`.
- **L15** `[grammar]` — Subject-verb disagreement: "both conditions is met".
- **L127** `[grammar]` — Garbled sentence with a missing verb ("was by leveraging").
- **L171** `[grammar]` — The phrase "your variable of interested" (spanning lines 170-171) should be "your variable of interest".

### `README.md`
- **L25** `[doc-error]` — Broken docs link: URL path "datastrctures" is misspelled; the real page is datastructures.md (docs/make.jl maps to datastructures.md). **Fix:** Change URL to .../dev/datastructures/
- **L71** `[doc-error]` — Wrong script path: there is no `tests/` directory; the file is at `test/runtests.jl` (folder is singular `test`). **Fix:** Change `tests/runtests.jl` to `test/runtests.jl`.
- **L94** `[doc-error]` — `:note:` is not a valid GitHub emoji shortcode nor a valid GitHub alert; it renders as literal text ":note:" instead of an admonition (also on lines 112 and 145). **Fix:** Use a valid GitHub alert, e.g. `> [!NOTE]` on its own line followed by the text.
- **L109** `[doc-error]` — Same wrong path: runtests.jl is at test/runtests.jl, not tests/runtests.jl. **Fix:** Change `tests/runtests.jl` to `test/runtests.jl`.
- **L167** `[typo]` — "latter" should be "letter".
- **L13** `[grammar]` — Missing article: "is collection" is ungrammatical.
- **L174** `[grammar]` — "In either cases" mismatched number; "either" takes the singular.

### `docs/src/climaartifacts.md`
- **L73** `[bug]` — `context` is never defined; the context variable created on line 71 is `my_mpi_context`. This example would throw UndefVarError. **Fix:** Change `context` to `my_mpi_context`
- **L73** `[doc-error]` — The example defines the context on line 71 as `my_mpi_context = ClimaComms.context()`, but here passes `context`, which is never defined. The example would raise UndefVarError if run. **Fix:** Change `context` to `my_mpi_context`: `@clima_artifact("socrates", my_mpi_context)`.
- **L91** `[doc-error]` — The macro is named `@clima_artifact` (singular) — see `export @clima_artifact` and `macro clima_artifact` in src/ClimaArtifacts.jl. `@clima_artifacts` does not exist. **Fix:** Change `@clima_artifacts` to `@clima_artifact`.
- **L43** `[typo]` — 'processing' should be 'processes' — the sentence refers to MPI processes, not the act of processing.
- **L15** `[grammar]` — 'in a one short directive' is ungrammatical (article 'a' before 'one').
- **L31** `[grammar]` — Subject-verb/number disagreement: 'Artifact that are not marked ... are' — singular noun with plural verb.
- **L92** `[grammar]` — The preceding line ends with 'the', giving 'the `ClimaArtifacts` keeps track', which reads as if a word ('module') is missing.

### `docs/src/datahandling.md`
- **L146** `[bug]` — `regridded_snaphsot` is a misspelling of `regridded_snapshot` (the actual function, src/DataHandling.jl:59). This code would throw UndefVarError. Same typo on line 147. **Fix:** Change `regridded_snaphsot` to `regridded_snapshot` on lines 146 and 147
- **L100** `[doc-error]` — Copy-paste error: for files ["era1980.nc", "era1981.nc"] split along variables, DataHandler assigns lai_lv to the second file, so the text should say `lai_lv` is in `era1981.nc`, not `era1980.nc`. **Fix:** Change the second `era1980.nc` to `era1981.nc`.
- **L14** `[typo]` — Stray duplicated literal token "regridder_module" appears after the @ref link (it renders as prose "Regridders regridder_module)"), and the "(chiefly" parenthesis opened on line 13 ends up closed only by this stray fragment.
- **L146** `[typo]` — Example calls the nonexistent function `regridded_snaphsot` (letters transposed); the real API is `regridded_snapshot`. Occurs on both line 146 and line 147.
- **L13** `[grammar]` — "the various core tasks and features and split" is ungrammatical; the verb should be "are split", not "and split".
- **L48** `[grammar]` — Garbled sentence: "loaded when loading ... are loaded" is redundant and ungrammatical.
- **L79** `[grammar]` — "The heuristics implement are the following" is ungrammatical; should be the past participle "implemented".
- **L83** `[grammar]` — Missing "as": "the number of files is the same the number of variables" should read "the same as the number of variables".

### `docs/src/datastructures.md`
- **L52** `[bug]` — The 3-arg `get!(cache, key, default)` evaluates `default` eagerly, so `factorial(n - 1)` is always computed recursively regardless of the cache. The cache provides zero speedup, contradicting the comments on lines 54/56 ('The second time it will only compute the last element'). Verified: Base.get!(cache::LRUCache,key,default::V) in src/DataStructures.jl takes default by value (eager). **Fix:** Use the lazy do-block form: `return n * get!(cache, n - 1) do; factorial(n - 1) end`
- **L52** `[doc-error]` — The memoization example is broken: the 3-argument `get!(cache, n-1, factorial(n-1))` eagerly evaluates the default `factorial(n-1)` on every call regardless of the cache, so the recursion recomputes everything. This contradicts the comment on line 57 ("The second time it will only compute the last element") -- the cache never saves work. **Fix:** Use the lazy do-block form so the default is only computed on a miss, e.g. `return n * get!(() -> factorial(n - 1), cache, n - 1)` (or `get!(cache, n - 1) do; factorial(n - 1); end`).
- **L16** `[typo]` — "thant" is a misspelling of "than".

### `docs/src/faqs.md`
- **L19** `[doc-error]` — The comment lists NCDatasets as one of the packages to load, and the example reads a NetCDF file (distances.nc) which requires the NCDatasets extension, but the import block only has `import ClimaCore` and `import Interpolations` (line 17-18). `import NCDatasets` is missing, so the example as written cannot read the .nc file (cf. inputs.md lines 190-193 which include it). **Fix:** Add `import NCDatasets` to the import block (e.g. after line 17).
- **L28** `[doc-error]` — The prose states the variable `distance` is in centimeters "but we want it in meters," yet the preprocess function multiplies by 10. Converting cm to m requires dividing by 100 (x*0.01); `10x` yields a value 1000x too large, so this example silently produces wrong results. **Fix:** Change `x -> 10x` to `x -> x / 100` (or `x -> 0.01x`).

### `docs/src/filereaders.md`
- **L65** `[bug]` — The comment on line 64 says 'Change units for v' and the variable is `v_var`, but the variable name argument is "u" (copy-pasted from line 63). It should read variable "v". **Fix:** Change the second argument from "u" to "v"
- **L27** `[doc-error]` — Prose says the reader is accessed with `read!(file_reader, date)` which "returns the Array". But `read!` has signature `read!(dest, file_reader, date)` (ext/NCFileReaderExt.jl:295,305) — it writes into `dest` and does not return the array as described. The accessor that returns the Array (and is used in the example and later prose) is `read(file_reader, date)`. **Fix:** Change `read!(file_reader, date)` to `read(file_reader, date)`.
- **L33** `[doc-error]` — Wrong keyword-argument name: the constructor's kwarg is `preprocess_func` (ext/NCFileReaderExt.jl:74,92), not `preprocessing_func`. The example on line 65 correctly uses `preprocess_func`, so the prose is inconsistent with the real API. **Fix:** Change `preprocessing_func` to `preprocess_func`.
- **L65** `[doc-error]` — Copy-paste bug: the comment on line 64 says "Change units for v" and the result is assigned to `v_var`, but the reader is created for variable "u", not "v". The example never actually reads `v`. **Fix:** Change the variable name argument from "u" to "v": `v_var = FileReaders.NCFileReader("era5_2000.nc", "v", preprocess_func = x -> 1000x)`.
- **L34** `[grammar]` — Ungrammatical sentence fragment: "keyword argument, function is applied" is missing a subject/relative pronoun.

### `docs/src/index.md`
- **L36** `[typo]` — "and interface barrier" should be "an interface barrier" — wrong article/typo.
- **L40** `[typo]` — "map rectangular grids two (extruded) finite spectral elements" uses "two" where the preposition "to" is meant.
- **L20** `[grammar]` — "a MPI-safe" — MPI is read as an initialism starting with a vowel sound ("em"), so the article should be "an".
- **L80** `[grammar]` — "an least-recently-used" is incorrect; "least" begins with a consonant sound, so the article should be "a".

### `docs/src/inputs.md`
- **L85** `[doc-error]` — In this example `compose_function` is passed as a bare trailing positional argument, but the real constructor `TimeVaryingInput(file_paths, varnames, target_space; ... compose_function = identity)` accepts only 3 positional args and takes `compose_function` as a keyword. As written this is a 4th positional arg and would throw a MethodError. **Fix:** Change `compose_function)` to `compose_function = compose_function)` (or `; compose_function)`).
- **L140** `[doc-error]` — `!!! warn` is not a valid Documenter admonition type; the block will not render as a warning. **Fix:** Change `!!! warn` to `!!! warning`.
- **L251** `[doc-error]` — The bare text `datahandling_module` (the @ref anchor name) leaked into the visible prose after the link. **Fix:** Remove the stray ` datahandling_module`: `(chiefly the [`DataHandling`](@ref datahandling_module)) to construct a `Field` from`.
- **L1** `[typo]` — `SpaceVaringInputs` is misspelled (missing the second `y`); the module is `SpaceVaryingInputs`.
- **L6** `[typo]` — `SpaceVaringInputs` is misspelled again (missing `y`); correct name is `SpaceVaryingInputs`.
- **L199** `[typo]` — `albedo_filed` is a misspelling of `albedo_field`, and `we albedo_filed` should read `with albedo_field`.
- **L213** `[typo]` — Filename `cesem_albedo.nc` is misspelled; prose (line 185) and the SpaceVaryingInput example (line 289) use `cesm_albedo.nc`.
- **L227** `[typo]` — Filename `cesem_albedo.nc` is misspelled again (should be `cesm_albedo.nc`).
- **L11** `[grammar]` — Garbled/redundant clause: "loaded when loading ClimaCore is loaded". Same sentence repeats at line 246.
- **L120** `[grammar]` — Doubled words "of the of" and the sentence mixes imperative and passive ("return the value ... is used instead").
- **L223** `[grammar]` — Missing verb "is": "This often used" should be "This is often used".
- **L250** `[grammar]` — Subject-verb disagreement: the plural "`SpaceVaryingInput`s" takes "use", not "uses".
- **L274** `[grammar]` — "albedo data as a time" is garbled; the parallel prose at line 185 reads "albedo data as a function of time".

### `docs/src/onlinelogging.md`
- **L55** `[typo]` — 'strickly' is a misspelling of 'strictly'.

### `docs/src/outputpathgenerator.md`
- **L80** `[doc-error]` — The sentence is left incomplete (ends with a comma), and line 81 contains stray empty inline-code backticks `` `` `` — the description of the default style behavior is missing. **Fix:** Complete the sentence (e.g., '..., the default `ActiveLinkStyle()` is used.') and delete the stray '``' on line 81.
- **L95** `[doc-error]` — `sort_by_creation_time` is defined in the `Utils` submodule (src/Utils.jl); it is not accessible as `ClimaUtilities.sort_by_creation_time` (no re-export in src/ClimaUtilities.jl). Correct path is `ClimaUtilities.Utils.sort_by_creation_time`. **Fix:** Change to `ClimaUtilities.Utils.sort_by_creation_time` (or the unqualified `sort_by_creation_time` as used in the source docstring).

### `docs/src/regridders.md`
- **L114** `[bug]` — Regridding is done by `regrid`, not by re-calling the constructor. `InterpolationsRegridder(reg, data, dimensions)` matches no method (the constructor takes a target_space); the real API is `Regridders.regrid(regridder, data, dimensions)` (ext/InterpolationsRegridderExt.jl:152). Same error on line 115. **Fix:** Change both lines to `Regridders.regrid(reg, data, dimensions)` / `Regridders.regrid(reg, 2 .* data, dimensions)`
- **L93** `[doc-error]` — FAQ snippet uses the unqualified name `InterpolationsRegridder`, but the snippet only imports `Interpolations as Intp` (line 91) and everywhere else the doc qualifies it as `Regridders.InterpolationsRegridder`; as written the name is undefined. **Fix:** Qualify it: `regridder = Regridders.InterpolationsRegridder(target_space; extrapolation_bc)` (and/or add `import ClimaUtilities.Regridders`).
- **L114** `[doc-error]` — Example calls the constructor `InterpolationsRegridder` with (reg, data, dimensions) to regrid data, but the actual regridding API is `Regridders.regrid(regridder, data, dimensions)` (ext/InterpolationsRegridderExt.jl:152). As written this would try to re-construct a regridder and fail. **Fix:** Replace with `interpolated_data = Regridders.regrid(reg, data, dimensions)`.

### `docs/src/timemanager.md`
- **L69** `[bug]` — `@show "time1"` echoes the string literal ('"time1" = "time1"') rather than displaying the `time1` value, which is almost certainly the intent given the surrounding accessor calls. **Fix:** Drop the quotes: `@show time1 counter(time1) period(time1) epoch(time1) date(time1)`.
- **L37** `[doc-error]` — Invalid Documenter code fence: `@julia example` is not a recognized at-block (only @example/@repl/@setup/@docs/etc.) and won't render/execute as intended; other blocks use ```@example example1 or plain ```julia. **Fix:** Use a plain static block ```julia (the code is an alternative import not meant to run).
- **L41** `[typo]` — Package name is misspelled: `ClimaUtilites` is missing an 'i' (should be `ClimaUtilities`).
- **L3** `[grammar]` — 'alongside with' (spanning lines 3-4) is redundant; 'alongside' already means 'along with'.
- **L10** `[grammar]` — 'do not occur in floating-point errors' is ungrammatical.
- **L13** `[grammar]` — Missing words: 'can be thought a combination' should be 'can be thought of as a combination'.
- **L102** `[grammar]` — Article/number disagreement: 'a new `ITime`s' pairs singular 'a' with plural 'ITimes'.
- **L109** `[grammar]` — Missing preposition: 'resulting the dimensionless factor' should be 'resulting in the dimensionless factor'.
- **L112** `[grammar]` — Missing object after 'by': 'but multiplying by is fine' is incomplete.
- **L115** `[grammar]` — Sentence is left incomplete: '...units are transformed to the' dangles before the code block with no object.
- **L123** `[grammar]` — Missing verb: 'because it the greatest common divisor' should be 'because it is the greatest common divisor'.
- **L186** `[grammar]` — Wrong article before a vowel-sound identifier: 'a `ITime`' should be 'an `ITime`'.
- **L190** `[grammar]` — 'Resist to this temptation' is ungrammatical; 'resist' takes a direct object.
- **L194** `[grammar]` — Wrong article: 'with a `epoch`' should be 'with an `epoch`'.
- **L212** `[grammar]` — Wrong verb form: 'is ran' should be 'is run'.
- **L243** `[grammar]` — Garbled heading: 'multiply by a number by an ITime' has a duplicated/misplaced 'by'.

---

## TEST

### `test/data_handling.jl`
- **L379** `[doc-error]` — Stale copy-pasted comment: this block tests DataHandling.previous_date with DateTime inputs (available_dates[1]/[end]), not previous_time with times. The identical comment at line 330 is correct there but wrong here. **Fix:** Change comment to `# Previous date with date, boundaries (return the node)`.
- **L212** `[style]` — var3 is assigned but never used; only var1 and var2 are referenced in the DataHandler error tests below (lines 234, 243, 253). Dead assignment.
- **L439** `[style]` — The two 'On node' assertions for next_date (lines 435-438 and 439-442) are verbatim identical: both check next_date(data_handler, available_dates[10]) == available_dates[11]. The second adds zero coverage. The parallel next_time 'On node' block (lines 409-417) deliberately tests two DISTINCT inputs, so this duplicate almost certainly dropped an intended distinct case.

### `test/file_readers.jl`
- **L37** `[bug]` — This test is preceded by the comment "Read it a second time to check that the cache works" (line 36) but is a verbatim duplicate of the assertion at lines 30-31 (read(ncreader_u, DateTime(2021,01,01,01)) == nc["u10n"][:,:,2]). It re-reads from disk and compares to disk, so it passes identically whether or not caching occurs and cannot detect caching at all. Cross-checking ext/NCFileReaderExt.jl `read(file_reader, date)` (lines 231-262): for a non-sentinel date the function returns the freshly read slice WITHOUT ever writing to `_cached_reads` (only the static DateTime(0) branch uses get!). Thus the cache is never populated for time-varying reads and the top-of-function `haskey(_cached_reads, date)` branch is dead — a real src bug that this test silently masks while claiming to verify the cache. **Fix:** Make the test actually exercise caching, e.g. assert the value is present in the reader's cache after the first read (haskey(ncreader_u._cached_reads, DateTime(2021,01,01,01))) and/or that a second read returns a cached (copied) result; and fix ext/NCFileReaderExt.jl `read(file_reader, date)` to store the read array into `_cached_reads` on a cache miss.
- **L63** `[bug]` — Two bare comparison expressions (L63-64) with no @test wrapper inside the multi-file aggregation testset: results computed and silently discarded, so that behavior is not actually asserted. **Fix:** Prefix both L63 and L64 with @test.

### `test/onlinelogging.jl`
- **L74** `[style]` — Dead assignment: current_wall_time_per_step is computed on the last line of the testset and never used. The 4th _update! call on line 69 discards its return value (the per-step wall time), so this variable appears to be a leftover from an intended assertion comparing the returned wall_time_per_step_this_measurement against (t2-t1)/5 that was never written.

### `test/output_path_generator.jl`
- **L110** `[doc-error]` — The comment claims the scenario is a missing output_active link, but the code below only removes the output_0001 directory (rm(expected_output)) and leaves the output_active symlink in place (now dangling). So generate_output_path takes the link_exists=true branch (reads target "output_0001", increments to output_0002), not the else/'link missing' branch. The comment describes a code path the test never exercises; the valid 'missing link + existing folders' branch (src lines 219-235) is left uncovered. **Fix:** Either also remove output_link before line 117 to actually test the missing-link branch, or reword the comment to 'Dangling active link (target folder removed) and existing output_ folders'.
- **L16** `[typo]` — Testset name misspells the style: "RemovePrexistingStyle" is missing an 'e' (should be "Preexisting"). Every other reference in this file (lines 3, 20, 33, 53, 154) and the struct itself (src/OutputPathGenerator.jl) use "RemovePreexistingStyle".

### `test/regridders.jl`
- **L610** `[bug]` — err_x/err_y/err_z (lines 610-612) are computed WITHOUT abs.(), then checked with `@test maximum(err) < 1e-5` (lines 614-616). maximum() of a signed error array only bounds the largest positive error; a systematic positive bias (regridded > coordinate) would make all errors negative and pass trivially. Every other error check in this file (lines 252, 326-327, 348, 356) uses abs.(), so this one masks potential regressions. **Fix:** Wrap each error in abs.(): `err_x = abs.(reg_box.coordinates.x .- regridded_x)` (and likewise err_y, err_z), matching the abs.() pattern used elsewhere.
- **L91** `[doc-error]` — reg_horz_reversed is built with dim_increasing = (true, false) on dimensions (lon, lat), so it reverses the SECOND dimension (lat) and leaves lon unchanged. The comment states the opposite ('reverses lon and not lat'), contradicting both line 85 ('reverses the second dimension') and the code/assertions below. **Fix:** Change to: 'check that `reg_horz_reversed` reverses lat and not lon as expected'.
- **L84** `[typo]` — Misspelling: 'regirdder' should be 'regridder'.
- **L57** `[style]` — Inner loop variable j is unused: the body `data_lat3D_reversed[i, :, :] .= reverse(lat)` / `data_lat3D[i, :, :] .= lat` broadcasts across the whole (lat, z) slice in one assignment, so the j loop just repeats the identical assignment length(z) times.
- **L63** `[style]` — Inner loop variable j is unused: `data_lon3D[:, i, :] .= lon` fills the entire (lon, z) slice in one broadcast, so the j loop redundantly repeats the same assignment length(z) times.
- **L170** `[style]` — Inner loop variable j is unused: `data_lat3D[i, :, :] .= lat` fills the whole (lat, z) slice in one broadcast, so the j loop repeats the identical assignment length(z) times.
- **L175** `[style]` — Inner loop variable j is unused: `data_lon3D[:, i, :] .= lon` fills the whole (lon, z) slice in one broadcast, so the j loop repeats the identical assignment length(z) times.

### `test/space_varying_inputs.jl`
- **L23** `[style]` — Unused test fixtures. xlim, ylim, zlim (lines 23-25), nelements (26), radius (27), depth (28), n_elements_sphere (29), and npoly_sphere (30) are defined but never used; make_spherical_space(FT; context) (TestTools.jl) takes only FT and context and hardcodes its own radius/zlim/element counts. zmin/zmax (22-23) feed only the unused zlim, so they are dead too.

### `test/time_varying_inputs.jl`
- **L293** `[bug]` — `time` is not the loop variable (that is `times`); `time` resolves to `Base.time`, a Function, so `eltype(time)` is `Any` and `Any <: Number` is always false. This entire block (lines 294-305) never runs, silently disabling the only test that checks linear-interpolation VALUES against a manually computed `expected` (searchsortedfirst-based interp), leaving linear interpolation correctness unverified for all float-time cases. **Fix:** Change `eltype(time)` to `eltype(times)`.
- **L359** `[bug]` — Same defect as line 293: `time` resolves to `Base.time` (a Function), so `eltype(time) <: Number` is always false and the `@test Array(parent(dest))[1] ≈ expected` is never executed. The 'In between t_end and t_init' periodic linear-interpolation assertion (using `expected` from lines 351-353) is silently skipped, so that interpolation path is never actually checked. **Fix:** Change `eltype(time)` to `eltype(times)`.
- **L260** `[grammar]` — 'should lead be equivalent' (continuing onto line 261) is ungrammatical/garbled.
- **L269** `[grammar]` — 'should lead be equivalent' is ungrammatical/garbled (same phrasing error as line 260).

### `test/time_varying_inputs23.jl`
- **L489** `[style]` — Lines 489-490 (`time_delta = 0.1dt`; `target_time = available_times[end] + time_delta`) are re-assigned verbatim at lines 501-502 with no read in between (lines 492-499 only compute left_value/right_value and reference neither variable). The first pair is dead/overwritten-before-use, a duplicated block adding nothing.
- **L503** `[style]` — In the 'LinearInterpolation with PeriodicCalendar' block, `left_time` (503) and `right_time` (504) are assigned but never used: the `expected` computation on lines 507-508 uses `time_delta / dt`, not these variables. They are copy-paste leftovers from the earlier linear block (lines 471-472) where they WERE used in the interpolation fraction (line 479). Confirms they are dead, not a masked bug (time_delta/dt = 0.1 is the correct periodic fraction).

### `test/utils.jl`
- **L49** `[style]` — Dead assignment: `dt = 1` is never read (the integer wrap_time tests on lines 51-58 call wrap_time with only 3 args and do not use dt), and dt is unconditionally reassigned to Dates.Second(1) on line 61 for the date-based tests.

---

## OTHER (config / CI)

- **`.github/workflows/ci.yml:42`** `[bug]` — The logical AND is split across two separate ${{ }} template blocks. GitHub Actions substitutes each block independently and concatenates the results into a string like "true && false"; because any non-empty string is truthy in an if conditional, this condition is effectively ALWAYS TRUE. The codecov upload therefore runs on every matrix job (macOS, Windows, and Julia 1.12) instead of only ubuntu-latest + Julia 1.10 as intended.

---

## Fix plan (phased)

1. **Bugs (runtime) — src/ext first.** Lead with the `NCFileReaderExt.jl` cache trio (single commit: dated-read `get!` do-block, lazy registry `get!`, `copy` on all cached returns) + a regression test that a second dated read hits the cache and that a mutated return does not corrupt the cache. Then the other confirmed `src`/`ext` logic bugs.
2. **Bugs (test) — no-op/miswired tests.** Activate `test/file_readers.jl:63-64` and any other unasserted comparisons; if a newly-active assertion fails, treat it as a possible real defect, not a delete.
3. **Performance.** Apply the confirmed hot-path allocation fixes; benchmark `@allocated` before/after on the affected `evaluate!`/`regrid`/`read` path.
4. **Doc-errors** (wrong signatures/names/admonitions/examples), then **typos**, then **grammar/style** (bulk prose cleanup).

## Verification

- `julia --project -e 'using Pkg; Pkg.test()'` — confirms the newly-activated test assertions pass and the cache fixes do not break the close-ordering test (`test/file_readers.jl:46-53`).
- `julia --project=docs docs/make.jl` — confirms admonition/example fixes render and doctests build.
- `test/quality_assurance.jl` (Aqua) + JuliaFormatter — quality/format after edits.
- Marquee behavior check: two consecutive `FileReaders.read(reader, date)` calls; the second must not touch the NetCDF file and `reader._cached_reads` must contain `date` after the first.

---

## Appendix — candidates found but NOT yet verified (12)

These surfaced in pass-1 auditing but the run was stopped before their verifier judged them; treat as leads, not confirmed:

- **`NEWS.md:52`** `[doc-error]` — There is no `report_progress` function in the public API; the progress-reporting callback is `report_walltime` (src/OnlineLogging.jl / docs/src/onlinelogging.md).
- **`NEWS.md:171`** `[typo]` — 'your variable of interested' (line 170-171) should be 'your variable of interest'.
- **`README.md:183`** `[doc-error]` — There is no `Space` module; the space-input module is `SpaceVaryingInputs`.
- **`docs/src/datahandling.md:14`** `[doc-error]` — Stray leftover anchor text `regridder_module)` appears after the completed `@ref` link.
- **`docs/src/datahandling.md:43`** `[doc-error]` — The DataHandler regridded-fields cache default is 2, not 128 (ext/DataHandlingExt.jl: `cache_max_size::Int = 2`; NEWS.md v0.1.20 documents the reduction from 128 to 2). Stale value.
- **`docs/src/filereaders.md:39`** `[grammar]` — 'it reads and process the data' (spans lines 38-39) should be 'reads and processes'.
- **`ext/NCFileReaderExt.jl:259`** `[bug]` — The temporal (non-sentinel date) read path reads from disk and returns without ever storing into `_cached_reads`. Only the DateTime(0)/static branches use `get!`. So for time-varying data the cache is never populated and the `haskey` check at line 236 is always false, defeating the LRU read cache entirely (every call re-reads/re-slices from the NetCDF dataset).
- **`ext/SpaceVaryingInputsExt.jl:20`** `[typo]` — Malformed markdown/quoting: `` ``data" `` opens a double-backtick code span that is closed by a double-quote, rendering incorrectly.
- **`ext/TempestRegridderExt.jl:341`** `[grammar]` — `varnames` is a Vector of names but described in the singular "the name of the variable".
- **`ext/TimeVaryingInputs0DExt.jl:153`** `[bug]` — Same dead-condition defect as the 23D case: `time <= t_init` is a discarded boolean. `_evalulate_flat!` therefore returns `vals[end]` for time>=t_end and `vals[begin]` for ALL other times, so any interior evaluation with a Flat BC returns the first value instead of interpolating (this branch is taken unconditionally for Flat in both the NearestNeighbor and LinearInterpolation evaluate! methods).
- **`ext/TimeVaryingInputsExt.jl:239`** `[bug]` — `kwargs...` is splatted in positional position (after a comma, not a `;`), so keyword arguments are forwarded as positional Pairs rather than keywords. Latent (only bites with non-empty kwargs) but incorrect; the 0D analogue correctly uses `args...; kwargs...`. Same defect recurs at ext/TimeVaryingInputsExt.jl:251 and ext/time_varying_inputs_linearperiodfilling.jl:385 and 398.
- **`test/data_handling.jl:379`** `[style]` — Stale copy-pasted comment: this block tests DataHandling.previous_date with DateTime inputs (available_dates[1]/[end]), not previous_time with times. The identical comment at line 330 is correct there but wrong here.

---

## Not-done (for a future run)

- The **second-pass sweep** (novel-lens re-hunt per location, deduped vs the above) never ran — a full pass would likely surface more, especially grammar/style and deeper cross-file logic issues.
- The **12 unverified candidates** above need a verification pass.
- The workflow is resumable (run id `wf_ed710531-49c`) to finish the sweep.

