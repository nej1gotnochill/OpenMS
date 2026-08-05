# quantms benchmark prototype

This is a prototype I've been using while exploring OpenMS Issue #8788
(benchmark testing). The goal is to reproduce the bigbio/quantms workflow for
the ProteoBench LFQ benchmark dataset *outside* Nextflow, so benchmark results
can actually be compared before deciding how benchmarking should be integrated
into OpenMS.

It's intentionally small and not wired into the CMake/CTest build yet — that
comes later, once the run itself is proven reproducible.

## Why this exists

Timo asked for a reproducible quantms run (Comet + Percolator vs Comet +
MS²Rescore) on the ProteoBench Q Exactive HF-X dataset. Before building
anything into OpenMS proper, I want the run itself to be:

- reproducible — same command, same parameters, recorded in a summary
- comparable — the two rescoring paths toggled by one flag, same inputs
- observable — everything logged, key outputs collected, no black box

## How to run

```bash
cp config.env.example config.env   # then edit the paths
bash benchmark_quantms.sh          # dry run: dependency check + validation + prints the command
```

Set `DRY_RUN=false` in config.env and re-run once the dataset is actually on
disk. The script performs five steps:

1. dependency check — nextflow, docker/podman, java, python, git
2. input validation — SDRF, FASTA, mzML directory, writable output dir
3. pipeline — generates the nextflow command, executes it only if `DRY_RUN=false`
4. collect outputs — copies the msstats CSV, mzTab and execution trace into `outputs/`
5. summary — writes what ran and with which settings to `logs/summary.log`

`ENABLE_RESCORING=false` runs Comet + Percolator; `true` runs
Comet + MS²Rescore + Percolator.

## Status / limitations

- Dataset bootstrap (download, RAW→mzML, SDRF construction) is not
  implemented yet — that's the next piece.
- No metric extraction or baseline comparison yet; it only collects outputs.
- `config.env` is gitignored by design (machine-specific paths); the tracked
  `config.env.example` holds placeholders.
