# playoff_sim — Claude Reference

## What This Project Does

Monte Carlo simulation of the 2026 NBA playoff bracket using the Bayesian hierarchical model from the `nba_point_spread` project. Produces:
- Win probability table (team × round)
- Modal bracket (single best pick for a bracket contest)
- Championship probability bar chart
- Round-by-round heatmap

## Quick Run

```bash
Rscript bracket_sim.R
```

Outputs go to `output/` (CSV + PNG files). Runtime ~2 minutes.

## Current Results (2026-04-18, final — injury adjustments + The Athletic context applied)

Modal bracket: **OKC beats DET** in the NBA Finals.

| Team | R1 Win | Semis | CF | Champion |
|---|---|---|---|---|
| OKC (W1) | 96% | 86% | 57% | **36%** |
| SAS (W2) | 97% | 78% | 35% | **20%** |
| DET (E1) | 96% | 76% | 44% | **20%** |
| BOS (E2) | 94% | 59% | 31% | 13% |
| NYK (E3) | 73% | 34% | 17% | 7% |
| HOU (W5) | 85% | 14% | 3% | 1% |

**Active injury adjustments:** LAL = -6.0 (Dončić + Reaves out), TOR = -1.5 (Quickley hamstring + 5-22 vs elite)

**Round 1 matchup win probabilities:**
- OKC 96% / PHX 4% — HOU 85% / LAL 15% — DEN 72% / MIN 28% — SAS 97% / POR 3%
- DET 96% / ORL 5% — CLE 49% / TOR 51% — NYK 73% / ATL 27% — BOS 94% / PHI 6%

**Most likely Finals:** OKC vs DET (24%), OKC wins 61% of those
**Bracket contest picks:** OKC champion; BOS over NYK in East semis; pick CLE over TOR (experts strongly favor CLE despite model coin-flip)
**Tiebreaker (Finals MVP points in 2026 playoffs):** ~700 (SGA, ~33 ppg × ~22 games)

## Updating Play-In Results

Once play-in results are known, edit the top of `bracket_sim.R`:

```r
WEST_8_SEED <- "PHX"   # confirmed: PHX beat GSW
EAST_8_SEED <- "ORL"   # confirmed: ORL beat CHA
```

Re-run the script. When `NA`, the script simulates the play-in uncertainty.

## Adjusting for Injuries

In `bracket_sim.R` at the top, edit `injury_adj`. Currently active:

```r
injury_adj <- c(
  "LAL" = -6.0,   # Doncic + Reaves both out (The Athletic, Apr 18)
  "TOR" = -1.5    # Quickley hamstring + 5-22 vs elite record
  # , "BOS" = -2.0  # Jaylen Brown (Achilles) — uncomment if limited Game 1
  # , "PHX" = -0.8  # Mark Williams (foot)
)
```

Negative = team scores fewer points per game. Applied to every game that team plays.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PLAYOFF_HFA_BOOST` | 1.0 | Extra pts added to home_advantage (historical playoff HFA ~2.5 vs model ~1.58) |
| `N_DRAWS` | 12000 | Posterior draw count (matches nba_point_spread pipeline) |
| `injury_adj` | `c()` | Named vector of point offsets by team abbreviation |
| `WEST_8_SEED` | `"PHX"` | Confirmed: PHX beat GSW in West play-in |
| `EAST_8_SEED` | `"ORL"` | Confirmed: ORL beat CHA in East play-in |
| `rest_days_override` | `c(PHX=2L, ORL=2L)` | Manual rest override for play-in teams (game_logs only through Apr 15) |

## Dependencies

- All model data from `/Users/jacobpstein/Documents/nba_point_spread/`
- Most recent fit: `fits/season_fit_*.rds` (latest selected automatically)
- `tidyverse`, `janitor`, `ragg`, `scales`, `usaidplot` (optional; falls back to `theme_minimal`)

## Plot Styling

- Heatmap: viridis palette (`scale_fill_viridis_c`), legend removed
- Both plots: caption includes `wizardspoints.substack.com`

## Conventions (matching nba_point_spread)

- Native pipe `|>` throughout
- `set.seed(202)` at top
- Trailing operators in multi-line arithmetic
- `usaid_plot()` theme where possible

## Model Approach

Uses the validated Bayesian hierarchical model (73.8% OOS direction accuracy):
- Team offense/defense random effects from Stan posterior
- Playoff HFA boost to match historical playoff home advantage
- Play-in uncertainty propagated per draw when seeds are unknown
- Best-of-7 series simulation (game-by-game, first to 4 wins), returns winner + games played
- NBA re-seeding after each round (1 vs 4, 2 vs 3 within conference)
- Championship home court: lower seed number hosts
- James-Stein shrinkage blend for playoff form (K=5, from season_config.R)
- Vegas blend intentionally NOT applied (pure model spreads; Vegas blend lives in 04_daily_predict.R)

## Console Outputs (beyond win probability table)

- **R1 matchup win probabilities** — per-series win % for all 8 first-round games
- **Series length distribution** — sweep/4-1/4-2/4-3 breakdown per R1 matchup
- **Finals matchup matrix** — conditional win probability for all likely Finals pairings (≥30 draws)

## File Layout

```
playoff_sim/
├── bracket_sim.R              ← main script
├── CLAUDE.md                  ← this file
├── PLAN.md                    ← implementation plan
├── MODEL_EXPLAINER.md         ← plain-English + technical model explanation
└── output/
    ├── bracket_probs_*.csv    ← win probability table
    ├── modal_bracket_*.csv    ← single contest pick
    ├── bracket_sim_results_*.rds  ← raw simulation for reuse
    ├── bracket_champion_probs.png
    └── bracket_heatmap.png
```
