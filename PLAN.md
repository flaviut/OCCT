# PLAN: Reproduce and Fix `mkoffsetshape` Invalid Result (OCCT)

## Status (Current Progress)

- Phase 1 completed: `DRAWEXE` batch-mode crash on `pload MODELING` fixed locally.
- Phase 2 completed: OCCT-level repro confirmed with the exported FreeCAD `.brep`.
- Current state:
  - `pload MODELING` works in batch mode (no crash)
  - `checkshape s` reports source shape is valid
  - baseline `mkoffsetshape ... join=a` originally reproduced invalid result (`BRepCheck_UnorientableShape`)
  - the visible arc-join corner defect was localized to bad tube/tube intersection geometry coming from `GeomInt_IntSS` (one symmetric torus/torus branch only)
  - root-side `GeomInt_IntSS` fallback (WLine approximation validation + local WLine-BSpline fallback) now removes the bad corner and the large tolerance blow-up
  - result tolerance for the baseline `+1.0, join=a` case is back to normal scale (`Tolerance MAX ~1.1e-6`; no ~20+ vertex tolerance inflation)
  - the follow-up `BRepCheck_InvalidSameParameterFlag` on the fallback-generated tube/tube edge is now resolved locally in `PipeInter()` by a measured same-`t` validation (3D curve vs both pcurves on support faces) and conditional `SameParameter` flag assignment when deviation is already small
  - baseline `+1.0, join=a` now validates again (`checkshape r`), and the join/tol/remove_internal matrix classifications match the expected/non-regressed pattern (all tested positive offsets valid; negative-offset classifications unchanged)
  - additional local stress testcase `wrench.brep` (conical seam-adjacent wrench-head-like cutout) reproduced a similar arc-path invalidity:
    - `join=a` initially failed (`BRepCheck_UnorientableShape` / `BRepCheck_NotClosed`)
    - failing subwire was a seam-adjacent cone/cone loop with a large inflated seam-vertex tolerance
    - `PipeInter()` diagnostics showed `ok=0, dev=0` because the local curve-on-surface validator did not handle wrapped/non-elementary pipe faces
  - local `PipeInter()` support-surface validation now handles generic surfaces via `Extrema_ExtPS` fallback in `IsOnSurface(...)`, which re-enables the existing `Inter3D()` containment fallback for bad `GeomInt_IntSS` sections on wrapped cone/cone pipe faces
  - with that change, `wrench.brep` `+1.0, join=a` validates (`checkshape r`) again; quarter-sphere baseline remains valid (no observed regression in the prior repro)
  - `wrench.brep` `+1.0, join=i` remains invalid and appears to be a separate issue (not part of the arc-join fix path)
  - `wrench.brep` characterization sweep (same local matrix dimensions as the quarter-sphere case) indicates:
    - `join=a`, positive offsets: valid for tested tolerances (`1e-7`..`1e-5`) and `remove_internal` (`0/1`)
    - `join=a`, negative offsets: still invalid (`BRepCheck_UnorientableShape`)
    - `join=i`, both offset signs: consistently invalid (`BRepCheck_SelfIntersectingWire`) for tested tolerances / `remove_internal`
  - `wrench.brep` `join=i` follow-up investigation (new):
    - independent flag sweep showed `intersection` / `selfInter` flags do not change the failure class for `join=i` (`intersection=1` only amplified tolerance before the local fix attempt)
    - disabling final `UpdateTolerance(...)` (temporary local experiment) exposed earlier raw defects:
      - `BRepCheck_InvalidCurveOnSurface`
      - `BRepCheck_InvalidSameParameterFlag`
      - `BRepCheck_InvalidPointOnCurve*`
      before the downstream `SelfIntersectingWire` / `UnorientableShape` reports
    - localized raw faulty edges are analytic circles on cone/cone, cone/cylinder, and cone/sphere transitions with two pcurves, where one support pcurve is geometrically exact while the other is offset on the support surface by ~`3e-2`..`9e-2`
    - temporary `BRepOffset_Inter2d::ExtentEdge(...)` diagnostics confirmed these bad pcurves are already created inside `ExtentEdge()` (same-`t` curve-vs-pcurve-on-surface deviation nonzero on one support, zero on the other)
    - temporary isolation switch skipping `ExtentEdge()` modifications for multi-pcurve circle edges restored `wrench.brep` `+1.0, join=i` validity and reduced the raw invalid edge set, localizing the issue to `ExtentEdge()` circle handling
  - local `join=i` fix candidate validated:
    - `BRepOffset_Inter2d::ExtentEdge(...)` now preserves the copied edge (skips extension/reprojection) for analytic circle edges carrying multiple pcurves
    - rationale: these edges can already carry consistent pcurves on multiple supports; re-extension/reprojection can desynchronize one pcurve (observed on cone/cone and cone/sphere transitions)
    - `wrench.brep` matrix after this local fix:
      - `join=i`, positive offsets (`+1.0`): valid for tested tolerances and `remove_internal` values
      - `join=i`, negative offsets (`-1.0`): unchanged `BRepCheck_SelfIntersectingWire`
    - quarter-sphere baseline and matrix remain unchanged (positive `join=i` valid; negative `join=i` still `BRepCheck_IntersectingWires`)
    - note: `wrench.brep` with `join=i` and `intersection=1` still shows a separate invalidity (`UnorientableShape` / `NotClosed`) after the `ExtentEdge()` circle fix, but the previous large tolerance blow-up is removed
- API path confirmed: DRAW `mkoffsetshape` calls `BRepOffsetAPI_MakeOffsetShape::PerformByJoin(...)`.

## Goal

Confirm and fix the kernel-level issue behind a FreeCAD failure where a 3D offset of a pocketed sphere produces invalid geometry (`Unorientable shape`) using OCCT directly (`mkoffsetshape` / `BRepOffsetAPI_MakeOffsetShape::PerformByJoin`).

## Context (What We Already Know)

### FreeCAD-side failure is real and geometry-related

- A new FreeCAD test was added for this sequence:
  1. Revolve a half-circle profile into a sphere
  2. Pocket away a quarter of the sphere
  3. Apply Part workbench 3D offset (`Part::Offset`, `Value=1.0`)
- The FreeCAD test fails for the intended reason (not setup noise):
  - `Offset.Shape.isValid() == False`
  - `shape.check(True)` reports: `Unorientable shape`

### Exact failing input shape has been exported

- The exact **pre-offset** source shape (from the failing FreeCAD test object graph) was exported to:
  - `/tmp/fc-offset-quarter-sphere-from-test/source_pre_offset_from_test.brep`

This is the artifact we want to feed directly into OCCT.

### Intended OCCT reproduction command

Target DRAW command (batch mode):

```bash
DRAWEXE -b -c "pload MODELING; restore /tmp/fc-offset-quarter-sphere-from-test/source_pre_offset_from_test.brep s; checkshape s; mkoffsetshape r s 1.0 1e-7 0 0 a 0; checkshape r"
```

Parameters match FreeCAD/OCCT offset settings:

- offset = `1.0`
- tol = `1e-7`
- intersection = `0` (false)
- selfInter = `0` (false)
- join = `a` (`GeomAbs_Arc`)
- remove internal edges = `0`

## Previous Blocker (Resolved)

`DRAWEXE` crashes before `mkoffsetshape` runs:

- `DRAWEXE -b -c ""` works
- `DRAWEXE -b -c "pload MODELING"` crashes (`SIGSEGV`)

GDB backtrace (user-provided) shows a DRAW/Tcl null-interpreter dereference:

- `Tcl_GetStringResult(interp=0x0)`
- from `Draw_Interprete(...)` in `src/Draw/TKDraw/Draw/Draw.cxx`

This was a **DRAW harness bug / error-handling crash** (not the offset operation bug), and it has now been fixed locally.

## Strategy

1. Keep the local DRAW crash fix (null Tcl result dereference guard)
2. Characterize the offset failure in OCCT with parameter variations
3. Prepare a concise OCCT testcase / upstream issue package (`.brep` + command + outputs)
4. Investigate/patch `TKOffset` if a localized fix is identifiable

## Work Plan

### Phase 1: Fix DRAW crash on `pload MODELING`

Status: Completed

1. Inspected `src/Draw/TKDraw/Draw/Draw.cxx` / `Draw_Interpretor`.
2. Confirmed crash site was null Tcl interpreter dereference via `theCommands.Result()`.
3. Patched DRAW to guard null interpreter and print fallback error message.
4. Rebuilt OCCT / DRAW stack.
5. Validated:
   - `DRAWEXE -b -c ""` still works
   - `DRAWEXE -b -c "pload MODELING"` no longer crashes

### Phase 2: Reproduce `mkoffsetshape` issue in OCCT

Status: Completed

1. Verified command availability (`help mkoffsetshape`, `help checkshape`) after `pload MODELING`.
2. Ran batch DRAW repro command on exported `.brep`.
3. Recorded results:
   - `checkshape s`: source shape is valid
   - `mkoffsetshape r ...`: result is invalid
   - `checkshape r`: reports unorientable shape (`BRepCheck_UnorientableShape`) and bad subshape orientation
4. Repeated the batch repro to confirm repeatability (consistent failure).

### Phase 3: Kernel-Level Investigation (Offset)

Status: In Progress

1. Confirmed DRAW `mkoffsetshape` uses the same API path:
   - `BRepOffsetAPI_MakeOffsetShape::PerformByJoin(...)` (done)
2. Confirmed behavior matches FreeCAD at kernel level:
   - same `.brep`, same offset parameters produce invalid/unorientable result (done)
3. Characterization runs completed (join/tolerance/internal-edges/sign):
   - Matrix executed for:
     - join type: `a` (`GeomAbs_Arc`) vs `i` (`GeomAbs_Intersection`)
     - tolerance: `1e-7`, `1e-6`, `1e-5`
     - remove internal edges: `0`, `1`
     - offset sign: `+1.0`, `-1.0`
   - Results summary:
     - `+1.0` with `join=a`: always invalid (`BRepCheck_UnorientableShape`)
     - `+1.0` with `join=i`: valid for all tested tolerances and `remove_internal` values
     - `-1.0` with `join=a`: invalid (`BRepCheck_UnorientableShape`, also `BRepCheck_NotClosed` subshape reported)
     - `-1.0` with `join=i`: invalid (`BRepCheck_IntersectingWires`)
   - Tolerance (`1e-7`..`1e-5`) and `remove_internal` (`0/1`) did not change classification in this testcase
   - Captured artifacts:
     - `mkoffsetshape_phase3_matrix.summary.tsv`
     - `mkoffsetshape_phase3_matrix.raw.log`
4. Kernel findings (arc-path investigation) so far:
   - The `+1.0` invalidity is strongly localized to the `GeomAbs_Arc` path, not shared shell/solid assembly:
     - `GeomAbs_Intersection` (`join=i`) is valid for the same source and parameters
     - Arc/intersection split happens early in `BRepOffset_MakeOffset::MakeOffsetShape()` (`BuildOffsetByArc` vs `BuildOffsetByInter`)
   - `checkshape r` reports bad subshape orientation on a faulty wire (`faulty_2`), not only a top-level shell/solid issue
   - Dumping `faulty_2` shows a wire spanning spherical / toroidal / planar support surfaces (consistent with arc-generated pipe/junction geometry)
   - Temporarily disabling final `UpdateTolerance(...)` changed the failure signature:
     - huge vertex tolerance inflation disappeared
     - raw defects became visible (`BRepCheck_InvalidCurveOnSurface`, `BRepCheck_InvalidSameParameterFlag`)
  - Visual/manual inspection after the local `SameParameter` patch showed a remaining geometric defect:
    - shape can be topologically valid while one fillet/fillet corner (tube/tube join) is visibly malformed
    - this is not just a `checkshape` artifact
  - Tolerance analysis of the "valid but wrong" result:
    - one corner vertex tolerance inflates dramatically (observed max ~20-23)
    - inflated tolerance masks the bad corner enough for `checkshape` to pass in some patched variants
  - `PipeInter()` instrumentation (tube/tube `GeomInt_IntSS` line quality) shows asymmetric intersection quality:
    - one symmetric branch (bottom corner) returns a section curve close to both tube surfaces (deviation ~`3e-5`)
    - the opposite symmetric branch (top/bad corner) returns a section curve already far from both tube surfaces (deviation ~`6.97`)
    - therefore the bad geometry is already present in the `GeomInt_IntSS` tube/tube section output before downstream wire/shell assembly
  - Working hypothesis (refined):
    - root cause is a bad tube/tube intersection section produced by `GeomInt_IntSS` for one torus/torus branch (likely periodic/seam branch handling / approximation on trimmed periodic supports)
    - `PipeInter()` currently trusts that section and propagates it into arc-join reconstruction
    - `SameParameter(...)` / `UpdateTolerance(...)` can amplify or mask the defect, but are not the primary cause
  - Local fix candidate validated:
    - added forced `BRepLib::SameParameter(E, Precision::Confusion(), true)` for edges created in `BRepOffset_Tool::PipeInter(...)`
    - baseline `mkoffsetshape ... join=a` (`+1.0`) now validates (`checkshape r`)
    - matrix rerun: all `+1.0` cases (`join=a` and `join=i`) validate; negative-offset classifications unchanged
    - however this is now understood as a topological-validity improvement, not a complete geometric fix for the fillet/filler join shape
  - Experimental pragmatic guard (not root-cause fix) validated locally:
    - when a `PipeInter()` `GeomInt_IntSS` line is grossly off both support surfaces, falling back to `Inter3D()` for that tube pair removes the large tolerance blow-up (max tolerance returns to ~`1e-6`)
    - this is a viable containment patch in `TKOffset`, but does not explain/fix the underlying `GeomInt_IntSS` defect
  - Root-side fix attempt in `GeomInt_IntSS` (WLine approximation path) now shows strong progress:
    - added validation of approximated WLine 3D curve against both support surfaces (periodic-surface cases) inside `GeomInt_IntSS::MakeCurve(...)`
    - when approximation is grossly off-support, `GeomInt_IntSS` falls back locally to WLine-point BSplines (3D + 2D), instead of letting a bad `Inter.Line(i)` propagate to `PipeInter()`
    - added periodic 2D pole unwrapping for this fallback path to avoid seam jumps in fallback pcurves
    - tagged diagnostics confirm fallback on the previously bad symmetric branch (observed fallback trigger with sampled deviations ~`0.697` on both support surfaces, limit `1e-3`)
    - after this root-side fallback, `PipeInter()` diagnostics show only small line deviations (~`3e-5` and ~`4e-6`) and no `PipeInter()->Inter3D()` fallback is needed
    - result tolerance for baseline `+1.0, join=a` drops back to normal scale (~`1.1e-6` max), eliminating the previous ~20+ tolerance blow-up
    - follow-up diagnostics localized the remaining `BRepCheck_InvalidSameParameterFlag` to the same fallback-generated tube/tube edge inside `PipeInter()`:
      - `BRepLib::SameParameter(...)` fails on the degree-1 WLine BSpline edge (`range 0..1268`, `1269` poles), leaving the flag unset
      - direct same-`t` sampling of `C3D(t)` vs `S(PCurve(t))` on both support faces shows small deviation (~`2.27e-7` on each face), i.e. the edge is already geometrically consistent enough
    - local completion fix in `PipeInter()`:
      - when `BRepLib::SameParameter(...)` fails, measure same-`t` curve/pcurve-on-surface deviation on both support faces
      - if the measured deviation is within a tight bound (current baseline: ~`2.27e-7`, limit ~`3.27e-5`), keep/update edge tolerance as needed and set the edge `SameParameter` flag explicitly
    - outcome after combined root geometry fix + measured same-parameter fallback:
      - baseline `+1.0, join=a` passes `checkshape`
      - baseline tolerance remains normal (~`1.1e-6` max)
      - matrix sweep restores the earlier expected classification pattern (positive offsets valid; negative-offset cases unchanged)
  - Additional arc-path testcase (`wrench.brep`, conical seam stress shape) findings:
    - `join=a` invalidity localized to a seam-adjacent cone/cone wire with `NotClosed` + `UnorientableShape`; one seam vertex tolerance inflated to ~`9.2e-2`
    - unlike the quarter-sphere torus/torus case, the bad section was not initially caught by `PipeInter()` diagnostics because `IsOnSurface(...)` returned unsupported for wrapped/non-elementary support surfaces (reported as `ok=0, dev=0`)
    - extending `BRepOffset_Tool::IsOnSurface(...)` with a generic `Extrema_ExtPS` distance check for non-elementary surfaces exposed large off-surface section deviations (observed ~`8e-2`..`4e-1` on several cone/cone pipe pairs)
    - this made the existing `PipeInter()->Inter3D()` fallback trigger (`fallback=1`) and restored validity for `wrench.brep` `+1.0, join=a`
    - `join=i` on `wrench.brep` remains invalid and is likely a distinct issue path
    - matrix behavior confirms the `join=i` failure is stable across sign/tolerance/`remove_internal` in this testcase, strengthening the split from the arc-path bug fixed here
  - `join=i` path root-cause progress on `wrench.brep`:
    - split the failure into earlier curve/pcurve consistency defects vs later tolerance/wire artifacts using an `UpdateTolerance(...)` skip experiment
    - traced the earliest reproducible raw defects to `BRepOffset_Inter2d::ExtentEdge(...)` on multi-pcurve analytic circle edges
    - identified that `ExtentEdge()` can leave one pcurve exact and another off-support on cone/sphere-family transitions
    - validated a localized workaround/fix path by preserving multi-pcurve circle edges in `ExtentEdge()`
5. Fix plan (targeted, system-aware):
   - Goal:
     - fix the earliest arc-join geometry inconsistency (curve-on-surface / same-parameter / wire orientation), not merely suppress downstream checks or tolerance growth
   - Scope first:
     - focus on arc-join intersection edge construction (`BRepOffset_Tool::PipeInter`) and nearby arc-path edge assembly
     - avoid broad/global post-fixes that can hide defects or regress unrelated offset cases
   - Step A: Instrument the arc path locally (temporary diagnostics)
     - add guarded debug checks for arc-generated intersection edges / affected faces in the arc path
     - run `BRepCheck_Analyzer` (or targeted edge/vertex checks) immediately after creation and after `BRepTools::Update`
     - log which edge(s) fail (`InvalidCurveOnSurface`, `InvalidSameParameterFlag`, orientation mismatch)
     - track edge/vertex tolerances before and after final `UpdateTolerance(...)` to separate root-cause vs amplification
  - Step B: Patch geometry consistency at creation time (minimal fix)
    - ensure arc-generated tube/tube intersection edges entering arc-join reconstruction are geometrically valid on both support surfaces (not only topologically "fixable" by tolerance/same-parameter)
    - evaluate targeted fixes in this order:
      - validate `GeomInt_IntSS` section curves in `PipeInter` against both support surfaces before use (local diagnostics already show one branch can be grossly invalid)
      - if section is invalid: rebuild/replace it (preferred: root-cause in `GeomInt_IntSS`; fallback: `PipeInter` route to `Inter3D()` / robust face-face intersection for that pair)
      - improve periodic/seam branch handling for torus/torus intersections (likely in `GeomInt_IntSS` / section approximation path)
      - keep `BRepLib::SameParameter` in `PipeInter` as a consistency step, but treat it as secondary to section correctness
      - only then revisit additional pcurve/range/orientation consistency on reused arc-path edges
      - face orientation normalization only if still needed after curve/pcurve consistency is fixed
    - reject fixes that only increase tolerances or silence checks without producing valid geometry
  - Step C: Re-verify full pipeline behavior
     - baseline repro (`join=a`, `+1.0`) must become valid (`checkshape r`)
     - control case (`join=i`, `+1.0`) must remain valid
     - negative-offset cases (`-1.0`) should not regress in classification without explicit intent
     - rerun at least the current matrix summary sweep to catch accidental regressions in `join`/`tol`/`remove_internal`
     - Status: completed locally for current patch set
     - added spot verification on `wrench.brep`:
       - `+1.0, join=a` now valid after generic `PipeInter` support-surface validation fix
       - `+1.0, join=i` still invalid (tracked separately)
     - local `wrench.brep` matrix sweep confirms no regression in the repaired `join=a` positive-offset cases and shows a stable separate `join=i` self-intersection failure pattern
     - after the `ExtentEdge()` circle-edge fix candidate:
       - `wrench.brep` `join=i` positive-offset cases now validate across the tested matrix
       - `wrench.brep` `join=i` negative-offset cases remain invalid (`SelfIntersectingWire`)
       - quarter-sphere baseline/matrix classifications are unchanged
   - Step D: Regression test coverage
     - add a `TKOffset` regression test using the exported `.brep` (or a minimized reproducible shape if feasible)
     - assert validity for the arc-join positive-offset case once fixed
     - keep the test focused on `PerformByJoin(..., GeomAbs_Arc, ...)` behavior
     - Status: pending
  - Step E: Upstream-ready packaging (in parallel with patching)
    - preserve exact DRAW repro command + `.brep`
    - attach matrix summary and representative `checkshape` outputs
    - include note that `join=i` succeeds (important for localization)
    - include geometric-quality evidence:
      - visual asymmetry (one fillet/filler corner wrong while symmetric corner is correct)
      - `PipeInter()` / `GeomInt_IntSS` section-on-surface deviation measurements for the good vs bad branch
6. Prepare issue/testcase materials:
   - exact command(s)
   - `.brep` path / attachment
   - observed `checkshape` output
   - note that source shape validates while offset result does not
7. If needed after arc-path fix attempt stalls:
   - inspect downstream shell assembly / orientation handling (`MakeShells`, `MakeSolid`, `CorrectConicalFaces`) for secondary contributors
   - but keep this as second-line investigation because current evidence points earlier (arc face/wire construction)

## Deliverables

- A fix for the `DRAWEXE` null-interpreter crash (completed locally)
- Verified OCCT reproduction of the offset invalidity (completed)
- Captured OCCT command transcript for `mkoffsetshape` / `checkshape`
- Draft upstream testcase/issue materials if kernel issue is confirmed
- Root-cause diagnosis notes for `GeomInt_IntSS` / `PipeInter` tube-tube section quality (periodic/seam branch handling suspicion)
- `./build-and-test.sh` local loop script (build `TKOffset` + `DRAWEXE`, run baseline repro, summarize `checkshape`/`tolerance`, and optional matrix sweep)
- A localized kernel fix (preferred in arc-path generation) plus regression coverage, if achievable
  - Current local fix consists of:
    - root-side `GeomInt_IntSS` WLine approximation validation/fallback for periodic-surface bad branches
    - `PipeInter()` measured same-`t` fallback to set `SameParameter` only when the fallback-generated edge is already geometrically consistent
    - `PipeInter()` generic support-surface validation in `IsOnSurface(...)` (`Extrema_ExtPS` fallback for wrapped/non-elementary surfaces), enabling `Inter3D()` containment fallback on seam-heavy cone/cone pipe cases
    - `GeomInt_IntSS` periodic WLine approximation validation/fallback coverage extended into plane/non-plane approximation branches (preventive coverage; not required to trigger for the current `wrench.brep` arc repro)
    - `BRepOffset_Inter2d::ExtentEdge(...)` preservation of multi-pcurve analytic circle edges (skip extension/reprojection for that subset), fixing the `wrench.brep` `join=i` positive-offset invalidity in local testing

## Notes / Constraints

- We are using local OCCT build at `/home/user/dev/OCCT/build`
- Prefer CMake builds in local `./build` folders
- Keep `ccache` enabled
- Do not pass explicit `-jN`
- `DRAWEXE` currently works without extra `LD_LIBRARY_PATH` overrides in this environment
