###############################################################################
# bracket_sim.R
# 2026 NBA Playoff Bracket Simulator
#
# Monte Carlo simulation using the Bayesian hierarchical model from
# nba_point_spread. Produces:
#   1. Win probability table (team x round)
#   2. Modal bracket (single best pick for a contest)
#   3. Championship probability bar chart
#   4. Round-by-round heatmap
#
# Usage: Rscript bracket_sim.R
#
# Update WEST_8_SEED / EAST_8_SEED once play-in results are known.
###############################################################################

library(tidyverse)
library(janitor)

set.seed(202)

# ── Load model data ────────────────────────────────────────────────────────────
# Reads from local data/ if export_model_data.R has been run; otherwise falls
# back to the sibling nba_point_spread repo (original behaviour).
local_data <- file.path("data", "draws_slim.rds")
if (file.exists(local_data)) {
  message("Using local data/ snapshot (self-contained mode)")
  .cfg              <- readRDS("data/season_config.rds")
  PLAYOFF_START     <- .cfg$PLAYOFF_START
  PLAYOFF_FORM_SHRINKAGE_K <- .cfg$PLAYOFF_FORM_SHRINKAGE_K
  rm(.cfg)
  .local_mode <- TRUE
} else {
  message("data/ snapshot not found — falling back to nba_point_spread repo")
  nba_root <- "/Users/jacobpstein/Documents/nba_point_spread"
  source(file.path(nba_root, "R/helpers/season_config.R"))
  source(file.path(nba_root, "R/helpers/ev_calculations.R"))
  source(file.path(nba_root, "R/helpers/tanking_score.R"))
  .local_mode <- FALSE
}

# ── Configuration ─────────────────────────────────────────────────────────────
N_DRAWS        <- 12000L
SERIES_WINS    <- 4L
today          <- Sys.Date()
output_dir     <- "output"
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

WEST_8_SEED <- "PHX"   # Phoenix beat Golden State in West play-in
EAST_8_SEED <- "ORL"   # Orlando beat Charlotte in East play-in

# Playoff home court advantage boost: historical playoff HFA ~2.5 pts,
# model posterior ~1.58 pts. Adding 1.0 closes this gap.
PLAYOFF_HFA_BOOST <- 1.0

# Injury adjustments: additive offset (points) to a team's expected scoring.
# Negative = team scores fewer points (key player out).
# Keys are 3-letter abbreviations.
injury_adj <- c(
  # LAL: Luka Doncic + Austin Reaves both out (per The Athletic, Apr 18)
  "LAL" = -6.0,
  # TOR: Immanuel Quickley (hamstring) questionable; TOR went 5-22 vs elite teams
  "TOR" = -1.5
  # To add more: append a comma after TOR line and uncomment below
  # , "BOS" = -2.0   # Jaylen Brown (Achilles) — returning Apr 18
  # , "PHX" = -0.8   # Mark Williams (foot) — out for play-in
)

# Play-in teams have ~2 days rest into Apr 19 (played Apr 16-17); game_logs only
# goes through Apr 15 so the rest_lookup would over-estimate. Override here.
rest_days_override <- c(
  PHX = 2L,   # played West play-in Apr 17
  ORL = 2L    # played East play-in Apr 16
)

# ── NBA team ID and abbreviation lookups ──────────────────────────────────────
# NBA team IDs (string) — same keys as team_index_df$team_id
team_ids <- c(
  ATL = "1610612737", BOS = "1610612738", BKN = "1610612751", CHA = "1610612766",
  CHI = "1610612741", CLE = "1610612739", DAL = "1610612742", DEN = "1610612743",
  DET = "1610612765", GSW = "1610612744", HOU = "1610612745", IND = "1610612754",
  LAC = "1610612746", LAL = "1610612747", MEM = "1610612763", MIA = "1610612748",
  MIL = "1610612749", MIN = "1610612750", NOP = "1610612740", NYK = "1610612752",
  OKC = "1610612760", ORL = "1610612753", PHI = "1610612755", PHX = "1610612756",
  POR = "1610612757", SAC = "1610612758", SAS = "1610612759", TOR = "1610612761",
  UTA = "1610612762", WAS = "1610612764"
)
id_to_abbrev <- setNames(names(team_ids), unname(team_ids))

# ── Home court schedule for a best-of-7 ──────────────────────────────────────
# Top seed is home for games 1, 2, 5, 7; bottom seed home for 3, 4, 6
TOP_SEED_HOME_GAMES    <- c(1L, 2L, 5L, 7L)
BOTTOM_SEED_HOME_GAMES <- c(3L, 4L, 6L)

# ── Playoff bracket structure ─────────────────────────────────────────────────
# Each series: list(top=abbrev, bottom=abbrev, conf=conference)
# PLAYIN_W8 / PLAYIN_E8 resolved before simulation

make_series <- function(top, bottom, conf) {
  list(top = top, bottom = bottom, conf = conf)
}

WEST_R1_TEMPLATE <- list(
  make_series("OKC",  "PLAYIN_W8", "WEST"),  # 1 vs 8
  make_series("LAL",  "HOU",       "WEST"),  # 4 vs 5
  make_series("DEN",  "MIN",       "WEST"),  # 3 vs 6
  make_series("SAS",  "POR",       "WEST")   # 2 vs 7
)

EAST_R1_TEMPLATE <- list(
  make_series("DET",  "PLAYIN_E8", "EAST"),  # 1 vs 8
  make_series("CLE",  "TOR",       "EAST"),  # 4 vs 5
  make_series("NYK",  "ATL",       "EAST"),  # 3 vs 6
  make_series("BOS",  "PHI",       "EAST")   # 2 vs 7
)

# Original seeds by abbreviation (used for re-seeding after each round)
SEEDS <- c(
  OKC = 1L, SAS = 2L, DEN = 3L, LAL = 4L, HOU = 5L, MIN = 6L, POR = 7L,
  GSW = 8L, PHX = 8L,
  DET = 1L, BOS = 2L, NYK = 3L, CLE = 4L, TOR = 5L, ATL = 6L, PHI = 7L,
  CHA = 8L, ORL = 8L
)

# ── Load model fit + supporting data ──────────────────────────────────────────
if (.local_mode) {
  message("Loading local data snapshot...")
  draws_df       <- readRDS("data/draws_slim.rds")
  scaling_params <- readRDS("data/scaling_params.rds")
  team_index_df  <- readRDS("data/team_index.rds")
  team_game_logs <- readRDS("data/game_logs_slim.rds")
  message("  ", nrow(draws_df), " posterior draws loaded")
} else {
  message("Loading most recent season fit...")
  fit_files <- list.files(file.path(nba_root, "fits"),
                          pattern = "^season_fit_.*\\.rds$", full.names = TRUE)
  fit_path  <- fit_files[which.max(file.mtime(fit_files))]
  message("  Using: ", basename(fit_path))
  fit       <- readRDS(fit_path)

  draws_raw <- fit$draws(format = "df")
  n_avail   <- nrow(draws_raw)
  draw_idx  <- sample(seq_len(n_avail), min(N_DRAWS, n_avail), replace = (N_DRAWS > n_avail))
  draws_df  <- draws_raw[draw_idx, ]
  message("  ", nrow(draws_df), " posterior draws extracted")

  message("Loading supporting data...")
  scaling_params <- readRDS(file.path(nba_root, "data/processed/scaling_params.rds"))
  team_index_df  <- readRDS(file.path(nba_root, "data/processed/team_index.rds"))
  game_logs_raw  <- readRDS(file.path(nba_root, "data/raw/game_logs.rds"))

  team_game_logs <- (if (is.data.frame(game_logs_raw)) game_logs_raw else game_logs_raw[[1]]) |>
    clean_names() |>
    mutate(
      team_id    = as.character(team_id)
      , game_date  = as.Date(game_date)
      , plus_minus = suppressWarnings(as.numeric(plus_minus))
      , wl         = as.character(wl)
    )
}

# ── Pre-extract theta matrices (key performance step) ─────────────────────────
message("Pre-extracting offense/defense parameter matrices...")
N_TEAMS   <- 30L
theta_off <- matrix(NA_real_, nrow = N_DRAWS, ncol = N_TEAMS)
theta_def <- matrix(NA_real_, nrow = N_DRAWS, ncol = N_TEAMS)
for (i in seq_len(N_TEAMS)) {
  off_col <- paste0("theta_offense[", i, "]")
  def_col <- paste0("theta_defense[", i, "]")
  if (off_col %in% names(draws_df)) theta_off[, i] <- draws_df[[off_col]]
  if (def_col %in% names(draws_df)) theta_def[, i] <- draws_df[[def_col]]
}

# ── Compute playoff context for all candidate teams ───────────────────────────
message("Computing playoff context (rest, form, blowout) for each team...")

# Rest: days since last game before Apr 19 (playoff start)
sim_date <- as.Date("2026-04-19")

rest_lookup <- team_game_logs |>
  filter(game_date < sim_date) |>
  group_by(team_id) |>
  summarise(last_date = max(game_date), .groups = "drop") |>
  mutate(rest_log = log1p(pmin(as.numeric(sim_date - last_date), 7L)))

# Blowout rate: last 15 games before playoff start
blowout_lookup <- team_game_logs |>
  filter(game_date < sim_date) |>
  mutate(was_blowout_loss = as.integer(wl == "L" & !is.na(plus_minus) & abs(plus_minus) >= 20L)) |>
  arrange(team_id, game_date) |>
  group_by(team_id) |>
  summarise(blowout_rate_15 = mean(tail(was_blowout_loss, 15L), na.rm = TRUE), .groups = "drop") |>
  mutate(blowout_rate_15 = replace_na(blowout_rate_15, 0))

# Playoff form: shrinkage blend of playoff games + regular-season anchor
reg_form <- team_game_logs |>
  filter(game_date < PLAYOFF_START) |>
  arrange(team_id, game_date) |>
  group_by(team_id) |>
  summarise(form_5g_reg = mean(tail(plus_minus, 5L), na.rm = TRUE), .groups = "drop")

playoff_raw <- team_game_logs |>
  filter(game_date >= PLAYOFF_START, game_date < sim_date) |>
  arrange(team_id, game_date) |>
  group_by(team_id) |>
  summarise(
    n_playoff       = n()
    , pm_sum_playoff = sum(plus_minus, na.rm = TRUE)
    , .groups = "drop"
  )

form_lookup <- tibble(team_id = unique(team_game_logs$team_id)) |>
  left_join(reg_form,     by = "team_id") |>
  left_join(playoff_raw,  by = "team_id") |>
  mutate(
    form_5g_reg    = replace_na(form_5g_reg, 0)
    , n_playoff    = replace_na(n_playoff, 0L)
    , pm_sum_playoff = replace_na(pm_sum_playoff, 0)
    , form_5g = (pm_sum_playoff +
        PLAYOFF_FORM_SHRINKAGE_K * form_5g_reg) /
        (n_playoff + PLAYOFF_FORM_SHRINKAGE_K)
  ) |>
  select(team_id, form_5g)

# Build per-team context list indexed by abbreviation
build_ctx <- function(abbrev) {
  tid <- team_ids[[abbrev]]
  list(
    rest_log    = if (abbrev %in% names(rest_days_override)) {
      log1p(pmin(rest_days_override[[abbrev]], 7L))
    } else {
      coalesce(rest_lookup$rest_log[rest_lookup$team_id == tid][1], log1p(3))
    }
    , form_5g   = coalesce(form_lookup$form_5g[form_lookup$team_id == tid][1], 0)
    , blowout_15 = coalesce(blowout_lookup$blowout_rate_15[blowout_lookup$team_id == tid][1], 0)
  )
}

all_playoff_abbrevs <- c(
  "OKC", "GSW", "PHX", "LAL", "HOU", "DEN", "MIN", "SAS", "POR",
  "DET", "CHA", "ORL", "CLE", "TOR", "NYK", "ATL", "BOS", "PHI"
)
ctx_lookup <- setNames(lapply(all_playoff_abbrevs, build_ctx), all_playoff_abbrevs)

# ── Stan ID lookup ─────────────────────────────────────────────────────────────
get_stan_id <- function(abbrev) {
  tid <- team_ids[[abbrev]]
  team_index_df$stan_id[team_index_df$team_id == tid]
}

# ── Game simulation function ───────────────────────────────────────────────────
# Returns TRUE if home team wins.
simulate_game <- function(home_abbrev, away_abbrev, d, ctx_home, ctx_away) {
  h_idx <- get_stan_id(home_abbrev)
  a_idx <- get_stan_id(away_abbrev)

  off_h <- theta_off[d, h_idx]
  def_h <- theta_def[d, h_idx]
  off_a <- theta_off[d, a_idx]
  def_a <- theta_def[d, a_idx]

  # Standardize context differentials (home minus away)
  rest_std <- ((ctx_home$rest_log - ctx_away$rest_log) - scaling_params$rest_mean) /
    scaling_params$rest_sd
  form_std <- ((ctx_home$form_5g - ctx_away$form_5g) - scaling_params$form_mean) /
    scaling_params$form_sd
  blowout_std <- ((ctx_home$blowout_15 - ctx_away$blowout_15) - scaling_params$blowout_mean) /
    scaling_params$blowout_sd

  # Injury adjustments: positive = home gets benefit, negative = home penalized
  inj_h <- if (home_abbrev %in% names(injury_adj)) injury_adj[[home_abbrev]] else 0
  inj_a <- if (away_abbrev %in% names(injury_adj)) injury_adj[[away_abbrev]] else 0

  # Expected spread (home - away); tanking = 0 for all playoff teams
  mu_h <- draws_df$mu_offense[d] +
    (draws_df$home_advantage[d] + PLAYOFF_HFA_BOOST) +
    off_h - def_a +
    draws_df$beta_rest[d]    * rest_std +
    draws_df$beta_form[d]    * form_std +
    draws_df$beta_blowout[d] * blowout_std +
    inj_h

  mu_a <- draws_df$mu_offense[d] +
    off_a - def_h +
    inj_a

  mu_spread <- mu_h - mu_a

  # Single noise draw (one sigma_points gives spread_sd ≈ 11-12 pts, as in 04_daily_predict.R)
  rnorm(1L, mu_spread, draws_df$sigma_points[d]) > 0
}

# ── Series simulation function ─────────────────────────────────────────────────
# Returns list(winner = abbrev, games = total_games_played).
simulate_series <- function(top_abbrev, bottom_abbrev, d, ctx_lookup) {
  top_wins    <- 0L
  bottom_wins <- 0L
  game_num    <- 1L

  while (top_wins < SERIES_WINS && bottom_wins < SERIES_WINS) {
    if (game_num %in% TOP_SEED_HOME_GAMES) {
      home <- top_abbrev; away <- bottom_abbrev
    } else {
      home <- bottom_abbrev; away <- top_abbrev
    }

    ctx_h <- ctx_lookup[[home]]
    ctx_a <- ctx_lookup[[away]]

    home_wins <- simulate_game(home, away, d, ctx_h, ctx_a)

    if (home_wins) {
      if (home == top_abbrev) top_wins <- top_wins + 1L else bottom_wins <- bottom_wins + 1L
    } else {
      if (away == top_abbrev) top_wins <- top_wins + 1L else bottom_wins <- bottom_wins + 1L
    }

    game_num <- game_num + 1L
  }

  list(
    winner = if (top_wins == SERIES_WINS) top_abbrev else bottom_abbrev
    , games = game_num - 1L
  )
}

# ── Re-seeding function ────────────────────────────────────────────────────────
# Given surviving teams (4 for semis, 2 for conf finals) ranked by original seed,
# pair highest vs lowest within conference.
reseed <- function(winners, conf) {
  seeds  <- SEEDS[winners]
  ranked <- winners[order(seeds)]  # ascending seed (1 = best)
  n      <- length(ranked)
  if (n == 4L) {
    list(
      make_series(ranked[1], ranked[4], conf)   # 1 vs 4
      , make_series(ranked[2], ranked[3], conf)  # 2 vs 3
    )
  } else if (n == 2L) {
    list(make_series(ranked[1], ranked[2], conf))  # top seed hosts
  } else {
    stop("reseed expects 2 or 4 winners, got ", n)
  }
}

# ── Play-in resolution helper ─────────────────────────────────────────────────
# If seed is set, return it directly. Otherwise simulate the play-in game.
resolve_playin <- function(home_abbrev, away_abbrev, d, ctx_lookup, known_seed) {
  if (!is.na(known_seed)) return(known_seed)
  home_wins <- simulate_game(home_abbrev, away_abbrev, d,
                             ctx_lookup[[home_abbrev]], ctx_lookup[[away_abbrev]])
  if (home_wins) home_abbrev else away_abbrev
}

# ── Full bracket simulation ────────────────────────────────────────────────────
message("Simulating ", N_DRAWS, " bracket iterations...")
pb <- txtProgressBar(min = 0, max = N_DRAWS, style = 3)

results <- vector("list", N_DRAWS)

for (d in seq_len(N_DRAWS)) {
  # Resolve play-in 8-seeds
  # West: PHX hosts GSW (model had PHX -5.9)
  # East: CHA hosts ORL (model had CHA home)
  west_8 <- resolve_playin("PHX", "GSW", d, ctx_lookup, WEST_8_SEED)
  east_8 <- resolve_playin("CHA", "ORL", d, ctx_lookup, EAST_8_SEED)

  # Fill play-in placeholders into R1 brackets
  west_r1 <- WEST_R1_TEMPLATE
  west_r1[[1]]$bottom <- west_8
  east_r1 <- EAST_R1_TEMPLATE
  east_r1[[1]]$bottom <- east_8

  all_r1 <- c(west_r1, east_r1)

  # Round 1 (8 series) — capture game counts for series length output
  r1_results      <- lapply(all_r1, function(s) simulate_series(s$top, s$bottom, d, ctx_lookup))
  r1_winners      <- vapply(r1_results, `[[`, character(1L), "winner")
  r1_games        <- vapply(r1_results, `[[`, integer(1L),   "games")

  west_r1_winners <- r1_winners[1:4]
  east_r1_winners <- r1_winners[5:8]

  # Round 2 (Conference Semifinals) — re-seed within each conference
  west_r2_series <- reseed(west_r1_winners, "WEST")
  east_r2_series <- reseed(east_r1_winners, "EAST")

  west_r2_winners <- vapply(west_r2_series, function(s) {
    simulate_series(s$top, s$bottom, d, ctx_lookup)$winner
  }, character(1L))
  east_r2_winners <- vapply(east_r2_series, function(s) {
    simulate_series(s$top, s$bottom, d, ctx_lookup)$winner
  }, character(1L))

  # Conference Finals — re-seed the 2 survivors
  west_cf_series <- reseed(west_r2_winners, "WEST")
  east_cf_series <- reseed(east_r2_winners, "EAST")

  west_cf_winner <- simulate_series(
    west_cf_series[[1]]$top, west_cf_series[[1]]$bottom, d, ctx_lookup
  )$winner
  east_cf_winner <- simulate_series(
    east_cf_series[[1]]$top, east_cf_series[[1]]$bottom, d, ctx_lookup
  )$winner

  # NBA Finals: WEST champion hosts (higher seed gets home court;
  # if both are same seed, West gets home court by conference record)
  west_seed <- SEEDS[west_cf_winner]
  east_seed <- SEEDS[east_cf_winner]
  finals_top    <- if (west_seed <= east_seed) west_cf_winner else east_cf_winner
  finals_bottom <- if (west_seed <= east_seed) east_cf_winner else west_cf_winner

  champion <- simulate_series(finals_top, finals_bottom, d, ctx_lookup)$winner

  results[[d]] <- list(
    west_8         = west_8
    , east_8       = east_8
    , west_r1      = west_r1_winners
    , east_r1      = east_r1_winners
    , r1_games     = r1_games          # game counts for 8 R1 series, same order as all_r1
    , west_r2      = west_r2_winners
    , east_r2      = east_r2_winners
    , west_cf      = west_cf_winner
    , east_cf      = east_cf_winner
    , champion     = champion
  )

  setTxtProgressBar(pb, d)
}
close(pb)
message("Simulation complete.")

# ── Save raw results ───────────────────────────────────────────────────────────
sim_rds <- file.path(output_dir, paste0("bracket_sim_results_", today, ".rds"))
saveRDS(results, sim_rds)
message("Raw results saved -> ", sim_rds)

# ── Aggregate win probabilities ────────────────────────────────────────────────
message("Aggregating probabilities...")

all_teams <- c(
  "OKC", "SAS", "DEN", "LAL", "HOU", "MIN", "POR",
  "DET", "BOS", "NYK", "CLE", "TOR", "ATL", "PHI",
  "GSW", "PHX", "CHA", "ORL"
)

conf_map <- c(
  OKC="WEST", SAS="WEST", DEN="WEST", LAL="WEST", HOU="WEST", MIN="WEST", POR="WEST",
  GSW="WEST", PHX="WEST",
  DET="EAST", BOS="EAST", NYK="EAST", CLE="EAST", TOR="EAST", ATL="EAST", PHI="EAST",
  CHA="EAST", ORL="EAST"
)

count_appearances <- function(field, team) {
  sum(vapply(results, function(r) {
    val <- r[[field]]
    if (is.null(val)) return(0L)
    team %in% val
  }, integer(1L)))
}

count_exact <- function(field, team) {
  sum(vapply(results, function(r) {
    val <- r[[field]]
    if (is.null(val)) return(0L)
    as.integer(identical(val, team))
  }, integer(1L)))
}

probs_df <- tibble(abbrev = all_teams) |>
  mutate(
    conference  = conf_map[abbrev]
    , seed      = SEEDS[abbrev]
    , p_r1_win  = vapply(abbrev, \(t) count_appearances("west_r1", t) + count_appearances("east_r1", t), integer(1L)) / N_DRAWS
    , p_r2_win  = vapply(abbrev, \(t) count_appearances("west_r2", t) + count_appearances("east_r2", t), integer(1L)) / N_DRAWS
    , p_cf_win  = vapply(abbrev, \(t) count_exact("west_cf", t) + count_exact("east_cf", t), integer(1L)) / N_DRAWS
    , p_champion = vapply(abbrev, \(t) count_exact("champion", t), integer(1L)) / N_DRAWS
  ) |>
  arrange(conference, seed)

# ── Console summary ────────────────────────────────────────────────────────────
cat("\n=== 2026 NBA Playoff Win Probabilities ===\n\n")
probs_df |>
  mutate(
    across(starts_with("p_"), \(x) sprintf("%.1f%%", x * 100))
  ) |>
  rename(
    Team         = abbrev
    , Conf       = conference
    , Seed       = seed
    , `R1 Win`   = p_r1_win
    , `Semis Win` = p_r2_win
    , `CF Win`   = p_cf_win
    , Champion   = p_champion
  ) |>
  print(n = Inf)

# ── R1 matchup win probabilities ──────────────────────────────────────────────
r1_matchup_defs <- list(
  list(top = "OKC", bottom = "PHX", label = "West (1) OKC  vs PHX (8)", field = "west_r1", idx = 1L),
  list(top = "LAL", bottom = "HOU", label = "West (4) LAL  vs HOU (5)", field = "west_r1", idx = 2L),
  list(top = "DEN", bottom = "MIN", label = "West (3) DEN  vs MIN (6)", field = "west_r1", idx = 3L),
  list(top = "SAS", bottom = "POR", label = "West (2) SAS  vs POR (7)", field = "west_r1", idx = 4L),
  list(top = "DET", bottom = "ORL", label = "East (1) DET  vs ORL (8)", field = "east_r1", idx = 1L),
  list(top = "CLE", bottom = "TOR", label = "East (4) CLE  vs TOR (5)", field = "east_r1", idx = 2L),
  list(top = "NYK", bottom = "ATL", label = "East (3) NYK  vs ATL (6)", field = "east_r1", idx = 3L),
  list(top = "BOS", bottom = "PHI", label = "East (2) BOS  vs PHI (7)", field = "east_r1", idx = 4L)
)

matchup_df <- tibble(
  series   = vapply(r1_matchup_defs, `[[`, character(1L), "label")
  , top    = vapply(r1_matchup_defs, `[[`, character(1L), "top")
  , bottom = vapply(r1_matchup_defs, `[[`, character(1L), "bottom")
  , p_top  = vapply(seq_along(r1_matchup_defs), function(i) {
      m <- r1_matchup_defs[[i]]
      mean(vapply(results, function(r) r[[m$field]][m$idx] == m$top, logical(1L)))
    }, numeric(1L))
) |>
  mutate(
    p_bottom   = 1 - p_top
    , top_pct  = sprintf("%.1f%%", p_top    * 100)
    , bot_pct  = sprintf("%.1f%%", p_bottom * 100)
  )

cat("\n=== Round 1 Matchup Win Probabilities ===\n\n")
for (i in seq_len(nrow(matchup_df))) {
  cat(sprintf("  %-28s  %s %-6s | %s %-6s\n",
    matchup_df$series[i],
    matchup_df$top[i],    matchup_df$top_pct[i],
    matchup_df$bottom[i], matchup_df$bot_pct[i]
  ))
}

# ── Series length distribution (R1) ───────────────────────────────────────────
cat("\n=== Round 1 Series Length Distribution ===\n\n")

r1_game_mat <- do.call(rbind, lapply(results, `[[`, "r1_games"))  # N_DRAWS x 8

for (i in seq_along(r1_matchup_defs)) {
  m     <- r1_matchup_defs[[i]]
  games <- r1_game_mat[, i]
  pct   <- prop.table(table(factor(games, levels = 4:7))) * 100
  cat(sprintf("  %-28s  4-0: %4.1f%%  4-1: %4.1f%%  4-2: %4.1f%%  4-3: %4.1f%%\n",
    m$label, pct["4"], pct["5"], pct["6"], pct["7"]
  ))
}

# ── Head-to-head Finals matchup matrix ────────────────────────────────────────
cat("\n=== Potential Finals Matchups (conditional win probabilities) ===\n\n")

finals_pairs <- tibble(
  west  = vapply(results, `[[`, character(1L), "west_cf")
  , east  = vapply(results, `[[`, character(1L), "east_cf")
  , champ = vapply(results, `[[`, character(1L), "champion")
) |>
  group_by(west, east) |>
  summarise(n = n(), p_west = mean(champ == west), .groups = "drop") |>
  filter(n >= 30) |>
  mutate(
    pct_occurs = sprintf("%.1f%%", n / N_DRAWS * 100)
    , west_win = sprintf("%.1f%%", p_west * 100)
    , east_win = sprintf("%.1f%%", (1 - p_west) * 100)
  ) |>
  arrange(desc(n))

cat(sprintf("  %-5s vs %-5s  %-8s  %s  %s\n", "WEST", "EAST", "Occurs", "W win%", "E win%"))
cat(sprintf("  %s\n", strrep("-", 45)))
for (i in seq_len(nrow(finals_pairs))) {
  r <- finals_pairs[i, ]
  cat(sprintf("  %-5s vs %-5s  %-8s  %-6s  %s\n",
    r$west, r$east, r$pct_occurs, r$west_win, r$east_win))
}

# ── Modal bracket ──────────────────────────────────────────────────────────────
message("\nComputing modal bracket...")

modal_series <- function(slot_abbrevs) {
  tab <- table(slot_abbrevs)
  names(tab)[which.max(tab)]
}

# For each of the 15 series slots, find the modal winner
# Slots: W1v8, W4v5, W3v6, W2v7, E1v8, E4v5, E3v6, E2v7,
#        WCF_top, WCF_bot, ECF_top, ECF_bot, WCF, ECF, Finals

get_slot <- function(field, idx = NULL) {
  vals <- vapply(results, function(r) {
    v <- r[[field]]
    if (is.null(v)) return(NA_character_)
    if (!is.null(idx)) v[[idx]] else v
  }, character(1L))
  vals[!is.na(vals)]
}

modal_bracket <- tibble(
  series = c(
    "West R1 (1v8)", "West R1 (4v5)", "West R1 (3v6)", "West R1 (2v7)",
    "East R1 (1v8)", "East R1 (4v5)", "East R1 (3v6)", "East R1 (2v7)",
    "West Semis A",  "West Semis B",
    "East Semis A",  "East Semis B",
    "West Conf Finals", "East Conf Finals",
    "NBA Champion"
  )
  , winner = c(
    modal_series(get_slot("west_r1", 1L))
    , modal_series(get_slot("west_r1", 2L))
    , modal_series(get_slot("west_r1", 3L))
    , modal_series(get_slot("west_r1", 4L))
    , modal_series(get_slot("east_r1", 1L))
    , modal_series(get_slot("east_r1", 2L))
    , modal_series(get_slot("east_r1", 3L))
    , modal_series(get_slot("east_r1", 4L))
    , modal_series(get_slot("west_r2", 1L))
    , modal_series(get_slot("west_r2", 2L))
    , modal_series(get_slot("east_r2", 1L))
    , modal_series(get_slot("east_r2", 2L))
    , modal_series(get_slot("west_cf"))
    , modal_series(get_slot("east_cf"))
    , modal_series(get_slot("champion"))
  )
)

cat("\n=== Modal Bracket (Best Single Pick) ===\n\n")
print(modal_bracket, n = Inf)

# ── Save CSVs ──────────────────────────────────────────────────────────────────
probs_path  <- file.path(output_dir, paste0("bracket_probs_", today, ".csv"))
modal_path  <- file.path(output_dir, paste0("modal_bracket_", today, ".csv"))
write_csv(probs_df,      probs_path)
write_csv(modal_bracket, modal_path)
message("\nProbability table -> ", probs_path)
message("Modal bracket     -> ", modal_path)

# ── Plots ──────────────────────────────────────────────────────────────────────
message("Generating plots...")

# Attempt to load usaidplot; fall back to theme_minimal if not installed
use_usaid <- requireNamespace("usaidplot", quietly = TRUE)

# base_theme: for plots without a continuous fill aesthetic (bar charts)
# plain_theme: always theme_minimal, for plots with continuous fill (heatmaps)
base_theme <- if (use_usaid) {
  function() usaidplot::usaid_plot()
} else {
  function() theme_minimal(base_size = 13)
}
plain_theme <- function() theme_minimal(base_size = 13)

FILL_BLUE  <- "#172869FF"
FILL_RED   <- "#D9565CFF"
FILL_TEAL  <- "#3B9AB2"

# ── Plot 1: Championship probability bar chart ────────────────────────────────
champ_plot <- probs_df |>
  filter(p_champion > 0.001) |>
  mutate(
    label = paste0(abbrev, " (", conference, " ", seed, ")")
    , label = fct_reorder(label, p_champion)
  ) |>
  ggplot(aes(x = p_champion, y = label)) +
  geom_col(fill = FILL_BLUE, width = 0.7) +
  geom_text(
    aes(label = sprintf("%.1f%%", p_champion * 100))
    , hjust = -0.1, size = 3.5, color = "grey30"
  ) +
  scale_x_continuous(
    labels = scales::percent_format(accuracy = 1)
    , expand = expansion(mult = c(0, 0.15))
  ) +
  labs(
    title    = "2026 NBA Championship Probabilities"
    , subtitle = paste0("12,000-draw Bayesian bracket simulation (HFA +", PLAYOFF_HFA_BOOST, " pts)")
    , x       = NULL
    , y       = NULL
    , caption = "Data: NBA.com/stats | wizardspoints.substack.com"
  ) +
  base_theme()

ragg::agg_png(
  file.path(output_dir, paste0("bracket_champion_probs_", today, ".png"))
  , width = 1200, height = 800, res = 150
)
print(champ_plot)
dev.off()

# ── Plot 2: Round-by-round heatmap ────────────────────────────────────────────
heatmap_df <- probs_df |>
  filter(p_r1_win > 0.001 | p_champion > 0.001) |>
  select(abbrev, conference, seed, p_r1_win, p_r2_win, p_cf_win, p_champion) |>
  pivot_longer(
    cols      = starts_with("p_")
    , names_to  = "round"
    , values_to = "prob"
  ) |>
  mutate(
    round = recode(round,
      p_r1_win   = "R1 Win\n(Top 8)"
      , p_r2_win = "Semis Win\n(Top 4)"
      , p_cf_win = "Conf Finals\nWin (Top 2)"
      , p_champion = "Champion"
    )
    , round = factor(round, levels = c(
        "R1 Win\n(Top 8)", "Semis Win\n(Top 4)",
        "Conf Finals\nWin (Top 2)", "Champion"
      ))
    , team_label = paste0(abbrev, " (", conference, " ", seed, ")")
    , team_label = fct_reorder(team_label, -seed + (conference == "EAST") * 100)
  )

heatmap_plot <- heatmap_df |>
  ggplot(aes(x = round, y = team_label, fill = prob)) +
  geom_tile(color = "white", linewidth = 0.5) +
  geom_text(
    aes(label = if_else(prob >= 0.03, sprintf("%.0f%%", prob * 100), ""))
    , size = 3, color = "white", fontface = "bold"
  ) +
  scale_fill_viridis_c(
    option = "viridis"
    , name = "Probability"
    , labels = scales::percent_format(accuracy = 1)
    , limits = c(0, 1)
  ) +
  facet_grid(conference ~ ., scales = "free_y", space = "free_y") +
  labs(
    title    = "2026 NBA Playoffs: Round-by-Round Win Probabilities"
    , subtitle = paste0("12,000-draw Monte Carlo simulation")
    , x       = NULL
    , y       = NULL
    , caption = "Data: NBA.com/stats | wizardspoints.substack.com"
  ) +
  plain_theme() +
  theme(
    axis.text.y = element_text(size = 9)
    , strip.text = element_text(face = "bold")
    , legend.position = "none"
  )

ragg::agg_png(
  file.path(output_dir, paste0("bracket_heatmap_", today, ".png"))
  , width = 1200, height = 900, res = 150
)
print(heatmap_plot)
dev.off()

message("Plots saved -> ", output_dir, "/")
message("\nDone! To update play-in results, set WEST_8_SEED / EAST_8_SEED at the top and re-run.")
