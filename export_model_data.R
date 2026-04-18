###############################################################################
# export_model_data.R
#
# Run once from nba_point_spread to snapshot everything bracket_sim.R needs.
# After this, playoff_sim is fully self-contained — no sibling repo required.
#
# Usage: Rscript export_model_data.R
###############################################################################

library(tidyverse)
library(janitor)

nba_root   <- "/Users/jacobpstein/Documents/nba_point_spread"
out_dir    <- "/Users/jacobpstein/Documents/playoff_sim/data"
N_DRAWS    <- 12000L

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ── 1. Posterior draws — slim extract ─────────────────────────────────────────
message("Loading Stan fit...")
fit_files <- list.files(file.path(nba_root, "fits"),
                        pattern = "^season_fit_.*\\.rds$", full.names = TRUE)
fit_path  <- fit_files[which.max(file.mtime(fit_files))]
message("  Using: ", basename(fit_path))

fit       <- readRDS(fit_path)
draws_raw <- fit$draws(format = "df")

set.seed(202)
draw_idx  <- sample(seq_len(nrow(draws_raw)), min(N_DRAWS, nrow(draws_raw)),
                    replace = (N_DRAWS > nrow(draws_raw)))
draws_raw <- draws_raw[draw_idx, ]

# Keep only the columns bracket_sim.R actually uses
keep_cols <- c(
  paste0("theta_offense[", 1:30, "]"),
  paste0("theta_defense[", 1:30, "]"),
  "mu_offense", "home_advantage",
  "beta_rest", "beta_form", "beta_blowout",
  "sigma_points"
)
missing <- setdiff(keep_cols, names(draws_raw))
if (length(missing)) warning("Columns not found in draws: ", paste(missing, collapse = ", "))

draws_slim <- draws_raw[, intersect(keep_cols, names(draws_raw))]
message("  Extracted ", nrow(draws_slim), " draws × ", ncol(draws_slim), " columns")

saveRDS(draws_slim, file.path(out_dir, "draws_slim.rds"))
message("  Saved draws_slim.rds  (",
        round(file.size(file.path(out_dir, "draws_slim.rds")) / 1e6, 1), " MB)")

# ── 2. Scaling params ──────────────────────────────────────────────────────────
message("Copying scaling_params.rds...")
file.copy(file.path(nba_root, "data/processed/scaling_params.rds"),
          file.path(out_dir, "scaling_params.rds"), overwrite = TRUE)

# ── 3. Team index ──────────────────────────────────────────────────────────────
message("Copying team_index.rds...")
file.copy(file.path(nba_root, "data/processed/team_index.rds"),
          file.path(out_dir, "team_index.rds"), overwrite = TRUE)

# ── 4. Game logs — slim to columns bracket_sim.R uses ─────────────────────────
message("Slimming game_logs.rds...")
game_logs_raw <- readRDS(file.path(nba_root, "data/raw/game_logs.rds"))
game_logs <- (if (is.data.frame(game_logs_raw)) game_logs_raw else game_logs_raw[[1]]) |>
  clean_names() |>
  mutate(
    team_id   = as.character(team_id),
    game_date = as.Date(game_date),
    plus_minus = suppressWarnings(as.numeric(plus_minus)),
    wl        = as.character(wl)
  ) |>
  select(team_id, game_date, plus_minus, wl)

saveRDS(game_logs, file.path(out_dir, "game_logs_slim.rds"))
message("  Saved game_logs_slim.rds  (",
        round(file.size(file.path(out_dir, "game_logs_slim.rds")) / 1e6, 1), " MB)")

# ── 5. Season config constants ─────────────────────────────────────────────────
message("Saving season config constants...")
season_config <- list(
  PLAYOFF_START            = as.Date("2026-04-18"),
  PLAYOFF_FORM_SHRINKAGE_K = 5L
)
saveRDS(season_config, file.path(out_dir, "season_config.rds"))

message("\nDone. Files in ", out_dir, ":")
for (f in list.files(out_dir, full.names = TRUE)) {
  message("  ", basename(f), "  (", round(file.size(f) / 1e6, 2), " MB)")
}
message("\nNext: update bracket_sim.R to read from data/ instead of nba_root.")
