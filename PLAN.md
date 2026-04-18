# NBA Playoff Bracket Simulator — Implementation Plan

## Goal

Predict the 2026 NBA playoffs bracket using the existing Bayesian hierarchical model from `nba_point_spread` (73.8% OOS direction accuracy). Outputs: (1) modal bracket for a contest, (2) full win-probability table, (3) visualizations.

## Approach: Monte Carlo from Bayesian Posteriors

**Why this is the most reliable method:**
- Propagates full posterior uncertainty through each round
- Correctly handles series format: P(win series) ≠ P(win single game)
- Model is calibrated and validated on 130+ OOS games
- Produces full probability distribution, not just a point estimate

## Method Reliability Comparison

| Method | Reliability | Notes |
|--------|------------|-------|
| Monte Carlo from Bayesian posteriors (implemented) | Highest | Full uncertainty quantification, validated model |
| Simple spread picks | Lowest | No series-level uncertainty, no round correlation |
| Vegas championship futures | Comparable to model | Good signal but 10-20% vig; no per-round probabilities |
| 40% Vegas / 60% model blend | Slightly higher than model | Can add as sensitivity check after games start |

## Play-In Handling

Two `NA`-default variables at script top:
- When `NA`: simulate play-in game per draw, propagating uncertainty into all downstream rounds
- When set (e.g., `"PHX"`): use directly as known 8-seed

## Adjustments

- **Playoff HFA boost** (`PLAYOFF_HFA_BOOST = 1.0`): closes gap between model posterior (~1.58 pts) and historical playoff HFA (~2.5 pts)
- **Injury adjustments** (`injury_adj` named vector): point offset applied to team expected scoring. Active as of 2026-04-18: `LAL = -6.0` (Dončić + Reaves out), `TOR = -1.5` (Quickley hamstring)
- **Rest days override** (`rest_days_override` named integer vector): bypasses game_logs rest computation for teams whose last game isn't in the logs (e.g., play-in participants). Active: `PHX = 2L`, `ORL = 2L`

## Critical Files

| File | Role |
|------|------|
| `nba_point_spread/fits/season_fit_*.rds` | 12,000 posterior draws (source of all probabilities) |
| `nba_point_spread/data/processed/team_index.rds` | NBA team ID → Stan integer ID mapping |
| `nba_point_spread/data/processed/scaling_params.rds` | Standardization params for features |
| `nba_point_spread/data/raw/game_logs.rds` | Rest, form, blowout context for each team |
| `nba_point_spread/R/04_daily_predict.R` | Reference for predict_game pattern |

## Implementation

### Key Functions

1. **`get_stan_id(abbrev)`**: converts team abbreviation → Stan integer ID via `team_index_df`
2. **`simulate_game(home, away, d, ctx_home, ctx_away)`**: single draw, single game; returns logical (home wins)
   - Mirrors `predict_game()` from `04_daily_predict.R`
   - Applies `PLAYOFF_HFA_BOOST` and `injury_adj`; sets tanking = 0 and Vegas weight = 0
3. **`simulate_series(top, bottom, d, ctx_lookup)`**: best-of-7, home court schedule games 1,2,5,7 at top seed. Returns `list(winner = abbrev, games = integer)` — both used downstream
4. **`reseed(winners, conf)`**: pairs surviving teams by seed (handles 2 or 4 teams)
5. **`resolve_playin(home, away, d, ctx_lookup, known_seed)`**: returns `known_seed` if set, else simulates
6. **`build_ctx(abbrev)`**: builds rest/form/blowout context for a team; checks `rest_days_override` before falling back to game_logs computation

### Performance Optimization

Pre-extract `theta_offense` and `theta_defense` into two 12,000 × 30 matrices before the loop. This avoids repeated `draws_df[[paste0("theta_offense[", i, "]")]]` string lookups inside 12,000 iterations.

### Bracket Structure

- Rounds: R1 (8 series) → Semis (4) → Conf Finals (2) → NBA Finals (1)
- NBA re-seeding after each round: highest remaining seed vs lowest within conference
- NBA Finals home court: team with lower original seed number hosts

## Outputs

All to `output/`:
- `bracket_probs_YYYYMMDD.csv` — P(advance past each round) for all 18 teams
- `modal_bracket_YYYYMMDD.csv` — single deterministic bracket pick (plurality winner per slot)
- `bracket_sim_results_YYYYMMDD.rds` — raw 12,000-draw results for reuse (includes `r1_games` vector)
- `bracket_champion_probs.png` — horizontal bar chart (caption: "Data: NBA.com/stats")
- `bracket_heatmap.png` — team × round probability heatmap

Console also prints:
- **R1 matchup win probabilities** — per-series win % for all 8 first-round matchups
- **R1 series length distribution** — sweep/4-1/4-2/4-3 breakdown per series
- **Finals matchup matrix** — conditional win % for all likely Finals pairings (≥30 draws)

## Verification Checks

1. Championship probabilities sum to 1.0
2. West and East Finals probabilities each sum to ~0.5
3. Top seeds (OKC, SAS, DET, BOS) have highest championship probabilities
4. After updating play-in seeds, re-run and confirm probabilities shift

## Current State (2026-04-18)

All implementation complete. Last run produced clean output with:
- Play-in seeds fixed: `WEST_8_SEED = "PHX"`, `EAST_8_SEED = "ORL"`
- Rest override active for PHX and ORL (2 days each)
- Active injuries: LAL −6.0, TOR −1.5
- Modal champion: OKC (36%). Full results in CLAUDE.md.
