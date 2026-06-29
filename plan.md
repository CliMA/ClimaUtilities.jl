# Plan: A `MultiColumnDataHandler` for `MultiColumnFiniteDifferenceSpace`

## Context

ClimaCore's `multiple-columns` branch adds `MultiColumnFiniteDifferenceSpace`:
N independent vertical columns at arbitrary (lat, lon), sharing z-levels
(layout `VIFH{LG,Nv,1,N}`). We want `TimeVaryingInput` and `SpaceVaryingInput`
to produce fields on this space, sourced from either (a) per-column data (a
vector of NCDatasets, or one dataset with a `column` dim) or (b) a single
global lat/lon[/z] grid sampled at each column.

**Key finding that simplifies everything:** `TimeVaryingInput` and
`SpaceVaryingInput` are **duck-typed**. `InterpolatingTimeVaryingInput23D` has
an unconstrained type param
([ext/TimeVaryingInputsExt.jl:86](ext/TimeVaryingInputsExt.jl#L86)), and
`TimeVaryingInput(data_handler; method, context)`
([:127](ext/TimeVaryingInputsExt.jl#L127)) takes *any* object implementing the
`DataHandling` interface. `SpaceVaryingInput(dh)` is just
`regridded_snapshot(dh)`
([ext/SpaceVaryingInputsExt.jl:142](ext/SpaceVaryingInputsExt.jl#L142)).
**So you do not need a custom `*VaryingInput`.** You only need a new data-source
type (call it `MultiColumnDataHandler`, analogous to the existing
`DataHandler`) that satisfies the interface below. Time interpolation is handled
for free; all that is column-specific lives in `regridded_snapshot!`.

## The interface contract (what the new type must expose)

The new type is consumed only through these. Implement exactly this surface:

**Fields read directly** by the input types: `.target_space`,
`.available_dates`, `.start_date`.

**`DataHandling.*` methods** (stubs already declared in
[src/DataHandling.jl:44-65](src/DataHandling.jl#L44)): `available_times`,
`available_dates`, `previous_time`, `next_time`, `previous_date`, `next_date`,
`time_to_date`, `date_to_time`, `dt`, `regridded_snapshot(dh, date)`,
`regridded_snapshot(dh, time)`, `regridded_snapshot(dh)` (no-arg, for
`SpaceVaryingInput`), `regridded_snapshot!(dest, dh, time)`, and `Base.close`.

The first 9 are **space-agnostic** — pure functions of
`available_dates`/`available_times`/`start_date`
([ext/DataHandlingExt.jl:391-552](ext/DataHandlingExt.jl#L391)). Reuse them
verbatim (copy the small bodies, or refactor the existing ones into shared
helpers keyed on those three fields). All the new work is in
`regridded_snapshot[!]`.

### Assumptions `TimeVaryingInput.evaluate!` bakes in (satisfy or it breaks)

- **Scalar field, same device as `dest`.** Buffers are `zeros(target_space)`
  and combined via `dest .= (1-coeff).*f0 .+ coeff.*f1`. Multi-var must compose
  to one scalar; `regridded_snapshot` must return on
  `ClimaComms.context(target_space)`'s device (the per-column-CPU-fill-onto-GPU
  issue).
- **`start_date` is used DIRECTLY for numeric time**:
  `date = start_date + Millisecond(1000·time)`
  ([ext/TimeVaryingInputsExt.jl:236](ext/TimeVaryingInputsExt.jl#L236)),
  bypassing `time_to_date`. Keep
  `time_to_date`/`date_to_time`/`available_times` all consistent with "seconds
  since `start_date`" or the numeric and date paths disagree silently.
- **`available_dates` sorted/non-empty/aligned with `available_times`**, read as
  a field (`.available_dates[begin]/[end]`, `in`).
- **`previous_date`/`next_date` return strictly-bracketing distinct dates**
  (else `coeff` divides by zero); both are called with a `DateTime`, as is
  `regridded_snapshot!`.
- **Cache must hold ≥ stencil-width dates at once** (2 for Linear, 4 for
  LinearPeriodFilling) — set `cache_max_size` accordingly or it thrashes every
  timestep (ties to Concern 1).

## Functions to implement (in build order, first → last)

Put everything in a new file `ext/MultiColumnDataHandlingExt.jl`, `include`d
from [the extension module](ext/ClimaUtilitiesClimaCoreNCDatasetsExt.jl) (no
`Project.toml` change — the existing `ClimaCore+NCDatasets` extension covers
it). Legend: **[new]** write it · **[reuse]** existing logic, copy/delegate ·
**[wiring]** package plumbing. Ordered so each phase is independently verifiable
before the next depends on it.

### Phase 0 — Wiring (so it precompiles & is callable)
1. `function MultiColumnDataHandler end` stub in `src/DataHandling.jl` + add
   `:MultiColumnDataHandler` to both `extension_fns` entries (drives the import
   error-hint). **[wiring]**
2. `function default_z_interpolation end` stub in `src/DataHandling.jl` (the
   z-interp seam). **[wiring]**
3. `function MultiColumnNCFileReader end` stub in `src/FileReaders.jl` (mirror
   `NCFileReader`). **[wiring]**
   *Verify:* package precompiles; calling these without ClimaCore/NCDatasets
   gives the import hint.

### Phase 1 — Read layer (perf-critical; testable in isolation — Concern 1)
`NCFileReader` doesn't fit the per-column path: `read` is **per-date only**
([ext/NCFileReaderExt.jl:221-252](ext/NCFileReaderExt.jl#L221)), its constructor
**errors on an index-only dimension**
([:158-163](ext/NCFileReaderExt.jl#L158)), and aggregation is **time-only**
([:100-116](ext/NCFileReaderExt.jl#L100)). So add
`MultiColumnNCFileReader <: FileReaders.AbstractFileReader`.

**Reader contract** (mirrors `AbstractFileReader`; see how `DataHandler`
consumes one at
[ext/DataHandlingExt.jl:304-358](ext/DataHandlingExt.jl#L304)):
- `read`/`read!` return **raw `Array`s, never ClimaCore `Field`s**. The reader
  is ClimaCore-agnostic; turning arrays into a `Field` happens later (per-column
  fill, fn 20, or the regridder for global-grid). `NCFileReader.read` likewise
  returns a plain `Array`.
- **Dimensions are struct fields, not return values.** Expose `.dimensions`
  (here the **source z levels**) and `.dim_names`; `DataHandler` reads
  `fr.dimensions`/`fr.dim_names` once at construction, never from `read`. These
  feed the z-interp hook / regridder.
- Expose `.available_dates::Vector{DateTime}` as a field too (read directly),
  in addition to the `available_dates(fr)` function.
- **Pick and document a fixed array layout** for the slab, e.g.
  `(Nlevel, Ncolumn, Ntime)` — drop `Ntime` for a single date, drop `Nlevel`
  for surface-only. The fill layer then takes `slab[:, h, :]` for column h.
- Per-column horizontal location is **index-only** (column h ↔ file/index h);
  the (lat,lon) come from the *space*, not the reader. Optionally read the
  file's lat/lon to assert they match the space's columns.
- No regridding, no z-interpolation, no ClimaCore types inside the reader.

4. `FileReaders.MultiColumnNCFileReader(file_paths, varname;`
   `column_dim=nothing, window_size, preprocess_func)` — open dataset(s)
   (vector ⇒ one per column; single file ⇒ column-indexed), read
   `available_dates` via `read_available_dates`, tolerate an index-only
   `column`/`site` dim, reuse `OPEN_NCFILES` handle-sharing. **[new]**
5. `FileReaders.read(fr, dates)` — contiguous time **slab** `var[…, t0:t1]` in
   one call; + `read(fr, date)` single + static no-time forms. Returns a raw
   `Array` in the documented layout. **[new]**
6. `FileReaders.read!(dest, fr, dates)` — in-place slab read into a raw buffer.
   **[new]**
7. `FileReaders.available_dates(fr)` → `Vector{DateTime}`. **[new, trivial]**
8. `Base.close(fr)` — drop from `OPEN_NCFILES`; close when last user (mirror
   [ext/NCFileReaderExt.jl:188-201](ext/NCFileReaderExt.jl#L188)). **[new]**
9. `_read_column_window(reader, h, date)` + `_refill_window!` — sliding-window
   buffer over the reader's slabs (serve W dates per read; buffer separate from
   any per-date LRU). **[new]**
   *Verify:* open files, read a slab; one slab read serves W consecutive dates.

### Phase 2 — Handler skeleton: struct + constructor + time axis
10. `struct MultiColumnDataHandler` + the two backend types
    `PerColumnBackend`/`GlobalGridBackend`. **[new]**
11. `MultiColumnDataHandler(file_paths, varnames, target_space;`
    `start_date=DateTime(1979,1,1), layout=:auto, column_dim=nothing,`
    `z_interpolation=default_z_interpolation, compose_function=identity,`
    `cache_max_size=2, …)` — select backend from `file_paths` shape +
    `layout`/`column_dim` (per-column first), read the shared time axis.
    **[new]**
12. `DataHandling.available_times(dh)` → `dh.available_times`. **[reuse]**
    *(required by TVI ctor)*
13. `DataHandling.available_dates(dh)` → `dh.available_dates`. **[reuse]**
    *(required)*
14. `DataHandling.time_to_date(dh, time)` → `DateTime`; must equal
    `start_date + time`. **[reuse]** *(required)*
15. `DataHandling.date_to_time(dh, date)` → seconds. **[reuse]** *(required by
    PeriodicCalendar)*
16. `DataHandling.previous_date(dh, date)` → strictly-bracketing `DateTime`.
    **[reuse]** *(required)*
17. `DataHandling.next_date(dh, date)` → strictly-bracketing `DateTime`.
    **[reuse]** *(required)*
18. `DataHandling.dt(dh)` → spacing. **[reuse]** *(required by
    `PeriodicCalendar{Nothing}` only)*
19. `DataHandling.previous_time(dh, t)` / `(dh, date)` and `next_time(...)`.
    **[reuse]** *(round out interface; not hit by TVI/SVI)*
    *Verify:* construct from per-column files; `previous/next_date`, `dt`
    match a hand-computed axis.

### Phase 3 — Snapshots + per-column fill (produces a Field)
20. `_fill_snapshot!(dest, dh, b::PerColumnBackend, date)` — loop columns, get
    column data (fn 9), optional z-interp hook (fn 2), then **memcpy** into the
    column-contiguous `VIFH` parent (`parent(dest[colidx])`). CPU per-column;
    GPU = host-assemble + single `copyto!` (Concern 2). **[new]**
21. `DataHandling.regridded_snapshot(dh, date::DateTime)` → `Field`:
    `get!(cache, date) do … _fill_snapshot!(…) end`. **[new]** *(core)*
22. `DataHandling.regridded_snapshot(dh, time::AbstractFloat)` (via
    `time_to_date`) and `regridded_snapshot(dh)` (static, key `DateTime(0)`, →
    `SpaceVaryingInput`). **[new, trivial]**
    - `DataHandling.regridded_snapshot!(dest, dh, time)` is **already generic**
      ([ext/DataHandlingExt.jl:648](ext/DataHandlingExt.jl#L648)) — **[reuse —
      no new method]**
    *Verify:* `regridded_snapshot(dh, date)` returns a finite per-column field
    (use a trivial test hook, e.g. copy-when-levels-match; the real z-interp
    comes from the external package).

### Phase 4 — Global-grid backend
23. `_fill_snapshot!(dest, dh, b::GlobalGridBackend, date)` — `read!` buffers →
    `compose_function` → `regrid(b.regridder, data, b.dimensions)` →
    `dest .= result`; extend the fn 11 constructor for the global-grid layout.
    Mirrors `DataHandler`'s body; the regridder works unchanged on this space
    (`LatLongZPoint` coords — verify the eltype guard at
    [regridder guard](ext/InterpolationsRegridderExt.jl#L72)). Reuses
    `NCFileReader` unchanged. **[reuse-heavy]**
    *Verify:* one global file fills all columns by sampling each column's
    (lat,lon).

### Phase 5 — Lifecycle + end-to-end
24. `Base.close(dh::MultiColumnDataHandler)` — close all file readers (mirror
    existing). **[new]**
25. *(optional)* a real `default_z_interpolation` method once the external
    package is chosen — until then the fn 2 stub errors clearly. **[external]**
    *Verify:* `TimeVaryingInput(dh; method=LinearInterpolation())` + `evaluate!`
    across two dates, and `SpaceVaryingInput(dh)` static case.

## Concerns to watch (including the ones you raised)

1. **File reading is the main cost — design for read-ahead / speculative
   prefetch (PRIMARY concern).** Per-column with N files = N dataset handles +
   N reads *per snapshot*; one-value-at-a-time reads make this the bottleneck
   (the fill itself is a memcpy — the concern is I/O, not compute). Strategy:
   - **Over-read on purpose.** When data for time `t` is requested, read a
     *contiguous time slab* `[t, t+W·dt]` per column in one NetCDF call
     (`var[:, :, t0:t1]`) instead of a single slice. Amortizes
     open/seek/decompress over W steps. NCDatasets slicing reads a contiguous
     block cheaply.
   - **Speculate on cadence.** Access is highly regular and monotonic (fixed
     `dt`: every 1 month, every 6 h, …). `TimeVaryingInput` marches forward and
     only ever needs `previous_date`/`next_date` (two adjacent snapshots). So a
     per-column **sliding window buffer** of the next W timesteps, refilled when
     the requested time passes the buffer's end, covers all interpolation needs
     with 1 read per W snapshots instead of 1 per snapshot. `dt(dh)` already
     gives the cadence.
   - **Buffer layer is new and separate from the existing caches.** The
     `NCFileReader` LRU caches *single-date* arrays
     ([ext/NCFileReaderExt.jl](ext/NCFileReaderExt.jl)); the DataHandler LRU
     caches *regridded full fields* per date. The prefetch buffer sits at the
     raw per-column read level (holding a time *slab* per column) — add it in
     the `PerColumnBackend`, don't overload the existing per-date caches. Still
     reuse `OPEN_NCFILES` handle-sharing.
   - **Whole-series shortcut.** Per-column site data is often small
     (`N × Nv × Ntime`); if it fits, read each column's entire series once at
     construction and skip windowing entirely.
   - **Layout matters.** Opening hundreds of tiny NetCDF files is slow
     regardless of buffering — encourage the single column-indexed dataset
     (`data[column, z, time]`) as the performant default; one handle, one slab
     read covers all columns.
   - *Optional later:* async prefetch (read next window on a task while the
     current one is consumed) to overlap I/O with compute — a follow-up, not v1.

2. **GPU (per-column path is CPU-only).** `Fields.bycolumn` on GPU collapses to
   a single `fn(:)` call
   ([fields.jl:9](../../ClimaCore.jl/multiple-columns/ext/cuda/fields.jl#L9)),
   so a per-column host loop that writes `field[colidx]` **will not work on
   GPU**. Because the fill is a memcpy, the GPU answer is clean: assemble the
   N-column slab in a host array, then **one `copyto!` to the device field's
   `VIFH` parent** (no per-column loop). Decide: (a) CPU-only first, error
   clearly on `CUDADevice`; or (b) host-assemble + single `copyto!` for GPU. The
   global-grid path is already GPU-safe (regridder adapt is wired).

3. **Shared time-axis assumption.** Built on one `available_dates` for all
   columns. To keep "no rewrite later," keep
   `available_dates`/`available_times`/`start_date` on the *outer* struct (the
   stable duck-typed facade) and, if per-column axes are needed later, move the
   source-of-truth into the backend while the facade fields stay. Add an
   assertion that all columns share the axis at construction.

4. **Backend selection ambiguity.** "vector of files" vs "one global file" vs
   "one column-indexed file" must be disambiguated explicitly (a
   `layout`/`column_dim` keyword), not guessed — mirror the documented
   `file_paths` heuristic in the existing `DataHandler` constructor.

5. **Interpolations.jl is a weakdep, confined to `InterpolationsRegridder`**
   (extension
   `ClimaUtilitiesClimaCoreInterpolationsExt = ["ClimaCore","Interpolations"]`).
   The **per-column backend must not depend on it** — don't route per-column
   through `default_regridder_type`
   ([src/Regridders.jl:36-44](src/Regridders.jl#L36)), or it will spuriously
   demand `import Interpolations`. The global-grid backend *does* require it (by
   design, same as `DataHandler`); fail with the existing "import
   Interpolations" hint if absent. Verify the regridder's `Adapt.adapt`-to-GPU
   path ([adapt call](ext/InterpolationsRegridderExt.jl#L123)) actually works on
   the new space — that combo is new.
   (`Utils.linear_interpolation` is homegrown, not Interpolations.jl.)

6. **Vertical-interp seam.** Keep `z_interpolation` a single well-named hook
   with a default stub that errors until the external package is wired. Decide
   whether the *global-grid* backend also routes z through this hook or lets
   `InterpolationsRegridder` do 3-D interpolation directly.

7. **`SingletonCommsContext` only.** Both `PointCloudGrid` and
   `PointColumnEnsembleSpace` hard-assert it — no MPI distribution; every rank
   holds all N columns. Fine for the regridder (already assumes full data per
   rank), but don't add distribution logic.

8. **Avoid horizontal/topology APIs.**
   `quadrature_style`/`Spaces.horizontal_space`+quadrature error on
   `PointCloudGrid`. Don't call anything that assumes a spectral-element
   horizontal space.

9. **Likely-to-surface-during-implementation:** writing a raw `Vector` into a
   `VF` column view (`parent(field[colidx])` vs broadcast); face vs center
   spaces (`level` takes `PlusHalf` for faces); `compose_function` for
   multi-variable per-column reads; whether `regridded_snapshot` cache key
   handles static (`DateTime(0)`) data.

## Verification

- Unit: construct from (i) a vector of per-column files and (ii) a global file;
  check `available_times`, `previous/next_time`, and that
  `regridded_snapshot(dh, date)` returns a field on the target space with
  expected per-column values (stub z-hook).
- Integration: `TimeVaryingInput` + `evaluate!` with `LinearInterpolation`
  across two dates; `SpaceVaryingInput(dh)` static case.
- Run existing `test/data_handling.jl`-style tests adapted to the new space;
  add a CPU test first, then decide GPU per Concern 1.

## Claude's Concerns

A deep, adversarially-verified pass over the plan. Each was checked against the
actual code; "(verified)" = the failure mode is real, "(nuanced)" = the
mechanism is real but narrower than it first looks. These are *additional* to
"Concerns to watch" above.

- **Per-column data is mapped to the grid's column index, not to physical
  (lat,lon) — wrong file order silently lands data on the wrong column.
  (verified, HIGH)** `PointCloudGrid` binds internal column `h` to `points[h]`
  by position (`for (h, pt) in enumerate(points)` in
  [pointcloud.jl](../../ClimaCore.jl/multiple-columns/src/Grids/pointcloud.jl)),
  and the fill writes `slab[:, h, :]` into `parent(dest[colidx])` for `h=1..N`.
  If the user's `points` order differs from the file/column-dim order (sorted
  by lat, by site id, etc.), every column gets another location's timeseries —
  a fully finite, plausible field, no error, no NaN. Make the lat/lon match a
  **mandatory** assertion (compare file coords to `coordinate_field` per `h`, or
  permute to grid order), not the "optional" check the reader contract states.
  The global-grid backend is immune (it regrids by physical coordinate).

- **`_FillValue`/`missing` is never stripped on the data-read path, so fill
  sentinels poison the field. (verified, HIGH)** `read` applies only
  `preprocess_func`; `nomissing` is called *only* on dimension arrays
  ([ext/NCFileReaderExt.jl:160](ext/NCFileReaderExt.jl#L160)). NCDatasets masks
  CF fill values to `missing` by default, so a column slab becomes
  `Union{Missing,FT}` — which either throws on `copyto!` into the `FT` `VIFH`
  parent, or (if a raw numeric sentinel like `9.96921e36` slips through) writes
  an absurd value that then gets *time-interpolated* with a real neighbor into
  silent garbage. Land/ocean masks make this common. The reader needs a
  documented fill policy, not a reliance on `preprocess_func`.

- **`dt(dh)` is undefined for monthly data — the likely real use case.
  (verified, HIGH)** `dt` errors on non-equispaced times
  ([ext/DataHandlingExt.jl:411-416](ext/DataHandlingExt.jl#L411)) and monthly
  climatology forcing is non-equispaced in seconds (month lengths differ). The
  `PeriodicCalendar{Nothing}` path and the constructor's `isequispaced` guard
  ([ext/TimeVaryingInputsExt.jl:191-196](ext/TimeVaryingInputsExt.jl#L191)) will
  error; you must use `PeriodicCalendar(period, repeat_date)`. The windowing
  scheme's "fixed `dt` cadence" assumption (Concern 1) also breaks for monthly
  data — size windows by *count*, not by `t + W·dt`.

- **The window buffer must bracket both neighbors and serve the global
  endpoints, not just stream forward. (verified, MED-HIGH)** Each step TVI reads
  *both* `previous_date` and `next_date`; `Flat` and `PeriodicCalendar`
  additionally read `date_init`/`date_end` (the global first/last) regardless of
  sim time (evaluate! `Flat` branch + `_time_range_dt_dt_e`). A naive forward
  window evicts `date0` when fetching `date1` (re-read every boundary) and never
  holds the endpoints → thrash. The window must hold the `[prev,next]` bracket
  and special-case endpoint access; restarts and backward/rejected adaptive
  steps also violate forward-only.

- **Per-column NetCDF reads inside a multithreaded `bycolumn` are a data race.
  (verified, MED)** `bycolumn` dispatches on the device and the CPU multithread
  variant runs `Threads.@threads for h`
  ([bycolumn](../../ClimaCore.jl/multiple-columns/src/Fields/indices.jl#L117)).
  NetCDF dataset handles are not safe for concurrent reads and `OPEN_NCFILES` is
  an unlocked `Dict`. Do the I/O serially (outside the threaded region) and only
  parallelize the pure memcpy — or the default device-dispatched `bycolumn` will
  silently corrupt reads.

- **"Fill is a memcpy" undersells the real case: z-interpolation runs per column
  every snapshot. (nuanced, MED)** The plan repeatedly frames the fill as a
  cheap memcpy "unless z-interp" — but you confirmed z-interp onto target levels
  *is* needed. So every column runs an interpolation pass on each cache miss,
  and the GPU host-assemble path must run that interp on the host first. Budget
  this compute; it is not free. (The good news, verified by killing the opposite
  concern: writing into `parent(dest[colidx])` is genuinely valid and contiguous
  — the memcpy *mechanism* is fine.)

- **The z-interp hook's type boundary is unspecified. (verified, MED)** The plan
  hands `z_interpolation` a ClimaCore column field, but the external package
  almost certainly wants plain `Vector`s, and it is undefined who allocates the
  output. Pin the contract: the hook takes/returns plain arrays
  (`src_z, raw → values_on_target_z`), and the fill copies the result into
  `parent(dest[colidx])`.

- **Recompute of per-column target z each snapshot is wasted allocation.
  (verified, MED)** Plan fn 20 derives target z via `Spaces.column(dest,colidx)`
  + `coordinate_field` inside the per-snapshot column loop, but z-levels are
  static — hoist them to the constructor (a precomputed per-column z vector),
  out of the hot path.

- **The `MultiColumnNCFileReader` import hint only fires if you also register
  the symbol. (nuanced, LOW-MED)** The error hint keys on the function *name*
  via `extension_fns` in `src/FileReaders.jl`; the bare stub (fn 3) gives a
  `MethodError` unless `:MultiColumnNCFileReader` is added to that list.
  Easy to forget; add it alongside the stub.

- **Two caches (regridded-Field LRU + raw window buffer) need a memory budget,
  even though they're correct. (nuanced, LOW-MED)** Verification found no
  coherence bug, but for large `N` the Field LRU alone holds ≥2 full `Nv×N`
  fields and the window holds `W×Nv×N×nvars` raw values. Keep them distinct
  (Concern 1 already says so) and document the combined footprint.

- **Parametrize the struct on the backend type. (nuanced, LOW)** A
  `backend::AbstractColumnBackend` abstract field is type-unstable; make it a
  type parameter `B` (the sketch already does — keep it that way, don't let the
  "swappable backend" prose become an abstract field).
