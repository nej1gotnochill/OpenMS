# quantms Benchmark Prototype (Day 8)

A standalone, runnable **framework** for benchmarking the ProteoBench LFQ DDA
Q Exactive dataset through [bigbio/quantms](https://github.com/bigbio/quantms).

This is the first prototype of the workflow behind OpenMS Issue #8788 /
PR #9839. It deliberately does **not** implement the full workflow yet — no
dataset bootstrap, no metric extraction, no baseline comparison. Those come in
later milestones. Today's goal is a clean, extensible skeleton:

```
bootstrap (download → RAW→mzML → SDRF)     ← future (PR: dataset bootstrap)
    ↓
benchmark_quantms.sh
    ├── 1. check_dependencies
    ├── 2. validate_inputs
    ├── 3. run_pipeline      (nextflow run . -profile dev,docker ...)
    ├── 4. collect_outputs   (msstats CSV, mzTab, trace)
    └── 5. generate_summary
```

## Purpose

- Run the quantms pipeline on a ProteoBench LFQ benchmark dataset with a
  reproducible, versioned command.
- Make the **rescoring experiment** Timo requested a one-flag switch:
  `ENABLE_RESCORING=false` (Comet + Percolator) vs `true` (Comet + MS²Rescore
  + Percolator).
- Capture logs and the key deliverables (`*_msstats_in.csv`, mzTab,
  execution trace) for later comparison / metric extraction.

## Requirements

| Tool | Why |
|---|---|
| [Nextflow](https://www.nextflow.io/) | runs the quantms pipeline |
| Docker (or Podman) | container execution (`-profile docker`) |
| Java 17+ | Nextflow runtime |
| Python 3 | quantms auxiliary steps |
| git | the quantms repo |

The script checks all of these automatically (`check_dependencies`) and fails
with a clear message if any are missing.

**Also required but not yet automated:** the benchmark dataset (mzML + FASTA +
SDRF) must exist on disk before the pipeline can execute. See
[Inputs](#inputs).

## Inputs

| Item | Where | Status in prototype |
|---|---|---|
| `SDRF` | `config.env` → `SDRF` | validated (must exist) |
| `FASTA` | `config.env` → `FASTA` | validated (must exist) |
| mzML files | `config.env` → `MZML_DIR` (default: `DATASET_DIR`) | validated (dir + ≥1 `.mzML`) |
| Output dir | `config.env` → `OUTDIR` | created + writability checked |
| quantms repo | `config.env` → `QUANTMS_DIR` | used as `nextflow run <dir>` |

Target dataset: **`quant_lfq_DDA_ion_QExactive`** (Q Exactive HF-X HYE,
PXD028735) — 6 RAW files, mixed-species FASTA, ground truth log2FC
**Human 0 / E. coli −2 / Yeast +1**. RAW→mzML conversion is a *future*
bootstrap step, not part of this script.

## Outputs

| Output | Location |
|---|---|
| Run log | `logs/run.log` |
| Pipeline stdout/stderr | `logs/quantms.log` |
| Summary (config + command + exit) | `logs/summary.log` |
| Collected deliverables | `outputs/` (`*_msstats_in.csv`, `.mzTab`, `execution_trace_*.txt`) |
| Full quantms results | `OUTDIR` (from config) — mzTab, consensusXML, qpx parquet, `pipeline_info/` |

## How to run

```bash
# 1. Edit config.env — set QUANTMS_DIR, DATASET_DIR, MZML_DIR, FASTA, SDRF, OUTDIR

# 2. Dry run (default): checks + validates + prints the command, does NOT execute
bash benchmark_quantms.sh

# 3. Real run, once the dataset is on disk
#    set DRY_RUN="false" in config.env, then:
bash benchmark_quantms.sh

# 4. Run the MS²Rescore comparison (Path B)
#    set ENABLE_RESCORING="true" in config.env, then re-run
```

Using a custom config without editing the default:

```bash
bash benchmark_quantms.sh my_config.env
```

## Key configuration

| Variable | Meaning |
|---|---|
| `PROFILE` | Nextflow profiles, default `dev,docker` (Timo's requirement: current OpenMS dev container) |
| `SEARCH_ENGINE` | default `comet` |
| `ENABLE_RESCORING` | `false` → `--ms2features_enable false`; `true` → `--ms2features_enable true` |
| `DRY_RUN` | `true` = print command only (default); `false` = execute |
| `NEXTFLOW_EXTRA_ARGS` | e.g. `-resume` |

## Current limitations

- **No dataset bootstrap** — downloads, RAW→mzML conversion, and SDRF
  construction are not implemented (next milestone).
- **Dry run by default** — the script never executes the pipeline until
  `DRY_RUN=false`.
- **No metric extraction or baseline comparison** — outputs are collected
  only; ProteoBench scoring / epsilon / CV / missing values come later.
- **No rescoring internals tuning** — `ENABLE_RESCORING` toggles
  `ms2features_enable` only; MS²PIP/DeepLC parameters are not yet exposed.
- Tested in Git Bash on Windows; POSIX paths (`/c/...`) recommended, Windows
  paths (`C:\...`) are converted automatically when `cygpath` is available.

## Structure

```
benchmark-prototype/
├── benchmark_quantms.sh   # main script (5 steps, see above)
├── config.env             # all configurable values
├── README.md
├── logs/                  # run.log, quantms.log, summary.log
├── outputs/               # collected deliverables
└── scripts/               # future helper scripts (bootstrap, metrics, ...)
```
