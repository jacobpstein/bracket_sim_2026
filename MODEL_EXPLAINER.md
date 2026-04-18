# How the Playoff Bracket Model Works

---

## The Short Version

The model answers one question: *given everything we know about how NBA teams have played all season, what's the probability each team wins each round?*

It works in two stages.

**Stage 1 — Learn team strength from the season.** Every NBA game this season is fed into a statistical model that estimates how good each team is at scoring and how good each team is at preventing scoring. These estimates aren't single numbers — they're probability distributions, meaning the model holds uncertainty about exactly how strong each team is. A team that's gone 64-18 with a +12 point differential has a tight, confident estimate. A team that's been inconsistent has a wider, fuzzier one.

**Stage 2 — Simulate the bracket.** The model runs the full 2026 playoff bracket 12,000 times. Each run draws a slightly different version of team strengths (reflecting that uncertainty), simulates every game of every series, and records who wins each round. After 12,000 runs, you count: OKC won the championship in 4,300 of them → 36% championship probability.

The result isn't "OKC wins." It's a full probability distribution over every possible bracket outcome — which is much more useful for a contest where you need to think about value, not just the most likely pick.

**Why trust it?** The underlying model has been validated on 130+ games it never saw during training, correctly predicting the winning team 73.8% of the time — well above the ~60% you'd get from Vegas lines alone.

---

## The Technical Details

### The Bayesian Hierarchical Model (Stage 1)

The core model lives in `nba_point_spread/stan/nba_spread.stan` and is fit via `03_fit_season_model.R` using Stan's MCMC sampler (No-U-Turn Sampler). It's a **Bayesian hierarchical model** of game-level point differentials.

#### Likelihood

For each game, the observed point differential (home minus away) is modeled as:

```
score_diff ~ Student_t(ν, μ_spread, σ_points)
```

The Student-t distribution (rather than Normal) accommodates occasional blowouts without distorting the rest of the fit. The `ν` (degrees of freedom) prior is `Gamma(2, 0.3)`, which allows real heavy tails.

The expected spread `μ_spread` is:

```
μ_spread = μ_offense
         + home_advantage
         + θ_offense[home] - θ_defense[away]   ← home team contribution
         - (θ_offense[away] - θ_defense[home])  ← away team contribution
         + β_rest    × rest_std
         + β_form    × form_std
         + β_blowout × blowout_std
         + β_tanking × tanking_score
```

#### Team Parameters

- **`θ_offense[i]`** and **`θ_defense[i]`**: team-level random effects, one pair per team (30 teams). Both are drawn from a shared Normal hyperprior — the league average offense/defense — which provides partial pooling. A team with few games gets pulled toward the league mean; a team with 82 games barely moves.
- **`μ_offense`**: global baseline (posterior mean ~115.9 pts), absorbing the league-wide scoring environment.
- **`home_advantage`**: posterior mean ~1.58 pts.

#### Context Features (standardized differentials)

Three game-level features are included as home-minus-away standardized differentials:

| Feature | Construction | Posterior β |
|---|---|---|
| `rest_log` | `log1p(min(days_since_last_game, 7))` | ~0.71 |
| `form_5g` | Shrinkage blend of last-5 plus/minus (see below) | ~0.81 |
| `blowout_rate_15` | Fraction of last 15 games that were 20+ pt losses | ~1.10 |

All three are centered and scaled by parameters stored in `scaling_params.rds`, computed once at model-fit time to prevent standardization leakage.

**Tanking score** is zeroed for all playoff teams (from play-in start onwards), since no team has a lottery incentive.

#### Posterior Inference

Stan produces 12,000 joint posterior draws over all parameters: all 60 team effects, the global parameters, the βs, and `σ_points`. These draws encode the full joint uncertainty — teams that are harder to estimate are noisier across draws.

---

### Playoff Form: James-Stein Shrinkage

Once the playoffs start, the `form_5g` feature blends regular-season and playoff performance:

```
form_5g = (playoff_plus_minus_sum + K × reg_season_form) /
          (n_playoff_games + K)
```

where `K = 5` (from `season_config.R`). This is a James-Stein style shrinkage estimator:

- 0 playoff games played → 100% regular-season anchor
- 5 playoff games → 50/50 blend
- 15 playoff games → 75% playoff, 25% regular season

This prevents a single Game 1 blowout from dominating the feature.

---

### The Bracket Simulation (Stage 2)

The bracket simulation lives in `bracket_sim.R`. For each of the 12,000 posterior draws `d`:

#### 1. Play-in resolution
If `WEST_8_SEED` / `EAST_8_SEED` are set (currently PHX, ORL), use them directly. Otherwise simulate the play-in game using `simulate_game()`.

#### 2. Game simulation
`simulate_game(home, away, d, ctx_home, ctx_away)` computes:

```
μ_h = μ_offense[d] + (home_advantage[d] + PLAYOFF_HFA_BOOST)
      + θ_offense[d, home] - θ_defense[d, away]
      + β_rest[d] × rest_std + β_form[d] × form_std + β_blowout[d] × blowout_std
      + injury_adj[home]

μ_a = μ_offense[d]
      + θ_offense[d, away] - θ_defense[d, home]
      + injury_adj[away]

spread ~ Normal(μ_h - μ_a, σ_points[d])
```

Home team wins if `spread > 0`. Note:
- `PLAYOFF_HFA_BOOST = 1.0` closes the gap between the model's posterior HFA (~1.58 pts) and historical playoff HFA (~2.5 pts)
- Vegas blending is intentionally absent (present in daily predictions but not the bracket sim, which runs pure model)
- `injury_adj` is a named vector of point offsets (e.g., `"LAL" = -6.0` for Dončić + Reaves out)

#### 3. Series simulation
`simulate_series(top, bottom, d, ctx_lookup)` runs games until one team reaches 4 wins. Home court follows the NBA schedule: games 1, 2, 5, 7 at the top seed; games 3, 4, 6 at the bottom seed. Returns `list(winner, games)`.

#### 4. Re-seeding
After each round, `reseed(winners, conf)` re-ranks surviving teams by their original seed and pairs highest vs. lowest (1v4, 2v3 for semis; 1v2 for conf finals). This matches the NBA's actual bracket format.

#### 5. Aggregation
After 12,000 draws, probabilities are computed as:
```
P(team advances past round R) = count(team in round R winners) / 12,000
```

Series length distributions, head-to-head Finals probabilities, and the modal bracket (plurality winner per slot) are also computed from the same results list.

---

### Key Model Parameters

| Parameter | Value | Source |
|---|---|---|
| N posterior draws | 12,000 | Matches nba_point_spread pipeline |
| `σ_points` (game noise) | ~11.0 pts | Stan posterior mean |
| `home_advantage` | ~1.58 pts | Stan posterior mean |
| `PLAYOFF_HFA_BOOST` | +1.0 pts | Manual calibration to historical playoff HFA |
| `PLAYOFF_FORM_SHRINKAGE_K` | 5 | season_config.R |
| Stan fit used | `season_fit_2026-04-17.rds` | Latest fit, full regular season |
| Game logs through | 2026-04-15 | Last day of regular season |

---

### Active Adjustments (2026-04-18 run)

```r
injury_adj <- c(
  "LAL" = -6.0,   # Doncic + Reaves both out (The Athletic, Apr 18)
  "TOR" = -1.5    # Quickley hamstring + 5-22 record vs elite teams
)

rest_days_override <- c(
  PHX = 2L,       # played West play-in Apr 17
  ORL = 2L        # played East play-in Apr 16
)
```
