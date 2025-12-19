# ===============================================================
# Google Scholar + SJR Enrichment Pipeline (extended-only version)
# ==========================================================7=====

suppressPackageStartupMessages({
  library(tidyverse)
  library(janitor)
  library(cli)
  library(progress)
  library(fs)
  library(readr)
  library(stringr)
  library(purrr)
  library(scholar)
  library(glue)
  library(memoise)
  library(ratelimitr)
  library(progressr
          
          
          )
})

# ---------------------------- 1) CONFIG & HELPERS ----------------------------

INPUT_CSV <- "SPECIFY INPUT FILE"
SJR_CSV   <- "SPECIFY THE SJR DATASET"
OUT_DIR   <- "SPECIFY THE OUTPUT DIRECTORY"
CACHE_DIR <- fs::path(OUT_DIR, "cache")

dir_create(OUT_DIR); dir_create(CACHE_DIR)

PAUSE_MIN_SEC <- 1.0
PAUSE_MAX_SEC <- 2.5
MAX_TRIES     <- 3

PLOT_YEAR_MIN <- 2010
PLOT_YEAR_MAX <- 2025

`%||%` <- function(x, y) if (is.null(x) || (length(x) == 1 && is.na(x))) y else x
ppause  <- function(min_s = PAUSE_MIN_SEC, max_s = PAUSE_MAX_SEC) Sys.sleep(runif(1, min_s, max_s))
backoff <- function(i) Sys.sleep((2 ^ i) + runif(1, 0, 1))
norm_title <- function(x) str_squish(str_to_lower(x))

# ---------------------------- 2) LOAD INPUTS --------------------------------

cli_h1("Loading inputs")

ids <- read_csv(INPUT_CSV, show_col_types = FALSE) %>%
  clean_names() %>%
  rename(scholar_id = id, author_name = name) %>%
  mutate(across(everything(), as.character)) %>%
  distinct()

sjr_raw <- read_csv2(SJR_CSV, show_col_types = FALSE)

# ---------------------------- 3) AUTHOR METRICS -----------------------------

fetch_metrics_one <- function(id, author_name) {
  attempt <- 1
  repeat {
    res <- try(scholar::get_profile(id), silent = TRUE)
    if (!inherits(res, "try-error")) {
      ppause()
      return(tibble(
        scholar_id  = id,
        author_name = author_name,
        h_index     = res$h_index %||% NA_integer_,
        i10_index   = res$i10_index %||% NA_integer_,
        total_cites = res$total_cites %||% NA_integer_,
        error       = NA_character_
      ))
    }
    if (attempt >= MAX_TRIES) {
      return(tibble(
        scholar_id  = id, author_name = author_name,
        h_index = NA_integer_, i10_index = NA_integer_, total_cites = NA_integer_,
        error = as.character(res)
      ))
    }
    Sys.sleep(attempt * 1.5); attempt <- attempt + 1
  }
}

cli_h1("Fetching author metrics")
pbm <- progress_bar$new(format = "  [:bar] :current/:total :percent (:eta) metrics",
                        total = nrow(ids), clear = FALSE, width = 60)

author_metrics <- map2_dfr(ids$scholar_id, ids$author_name, function(id, nm) {
  pbm$tick(); fetch_metrics_one(id, nm)
}) %>% clean_names()

# ---------------------------- 4) PUBLICATIONS (+CACHE) ----------------------

cache_read  <- function(path) if (fs::file_exists(path)) readRDS(path) else NULL
cache_write <- function(obj, path) saveRDS(obj, path)

fetch_pubs_one <- function(id, author_name) {
  cache_file <- fs::path(CACHE_DIR, glue("pubs_{id}.rds"))
  cached <- cache_read(cache_file)
  if (!is.null(cached)) return(cached)
  
  attempt <- 1
  repeat {
    res <- try(scholar::get_publications(id = id), silent = TRUE)
    if (!inherits(res, "try-error")) {
      out <- res %>%
        clean_names() %>%
        mutate(scholar_id = id, author_name = author_name)
      cache_write(out, cache_file)
      ppause()
      return(out)
    }
    if (attempt >= MAX_TRIES) {
      out <- tibble(scholar_id = id, author_name = author_name, error = as.character(res))
      cache_write(out, cache_file)
      return(out)
    }
    Sys.sleep(attempt * 1.5); attempt <- attempt + 1
  }
}

cli_h1("Fetching publications")
pbp <- progress_bar$new(format = "  [:bar] :current/:total :percent (:eta) pubs",
                        total = nrow(ids), clear = FALSE, width = 60)

all_pubs <- map2(ids$scholar_id, ids$author_name, function(id, nm) {
  pbp$tick(); fetch_pubs_one(id, nm)
}) %>% list_rbind()

# --- SAFE split on optional `error` column ---
if ("error" %in% names(all_pubs)) {
  pub_errors <- all_pubs %>% filter(!is.na(error))
  pubs_ok    <- all_pubs %>% filter(is.na(error)) %>% select(-error)
} else {
  pub_errors <- tibble()
  pubs_ok    <- all_pubs
}

pubs_ok <- pubs_ok %>% distinct(scholar_id, title, .keep_all = TRUE)

# ---------------------------- 5) UNIFY (Pubs + Metrics) ---------------------

am_small <- author_metrics %>%
  select(scholar_id, author_name_metrics = author_name, h_index, i10_index, total_cites)

unified <- pubs_ok %>%
  left_join(am_small, by = "scholar_id") %>%
  mutate(author_name = coalesce(author_name, author_name_metrics)) %>%
  select(-author_name_metrics) %>%
  relocate(scholar_id, author_name, h_index, i10_index, total_cites)

# ---------------------------- 6) SJR CLEANING & JOIN ------------------------

sjr_clean <- sjr_raw %>%
  clean_names() %>%
  mutate(
    title_norm        = norm_title(title),
    sjr_best_quartile = str_to_upper(sjr_best_quartile)
  ) %>%
  group_by(title_norm) %>%
  summarise(
    sjr_best_quartile = case_when(
      any(sjr_best_quartile == "Q1", na.rm = TRUE) ~ "Q1",
      any(sjr_best_quartile == "Q2", na.rm = TRUE) ~ "Q2",
      any(sjr_best_quartile == "Q3", na.rm = TRUE) ~ "Q3",
      any(sjr_best_quartile == "Q4", na.rm = TRUE) ~ "Q4",
      TRUE ~ NA_character_
    ),
    journal_h_index = suppressWarnings(max(h_index, na.rm = TRUE)),
    .groups = "drop"
  ) %>%
  mutate(journal_h_index = ifelse(is.finite(journal_h_index), journal_h_index, NA_real_))

unified <- unified %>%
  mutate(title_norm = norm_title(journal)) %>%
  left_join(sjr_clean, by = "title_norm") %>%
  select(-title_norm)

# ---------------------------- 7) EXTENDED-ONLY METADATA ---------------------

# unique scholar_id/pubid pairs
pairs <- unified %>% distinct(scholar_id, pubid)

# memoized + rate-limited
get_pub_ext_mem <- memoise::memoise(get_publication_data_extended)
safe_rate       <- ratelimitr::limit_rate(get_pub_ext_mem, rate(n = 1, period = 2))

# pull only Description, with retries/backoff
fetch_description <- function(scholar_id, pubid, max_tries = 6) {
  for (i in seq_len(max_tries)) {
    out <- try(safe_rate(scholar_id, pubid), silent = TRUE)
    if (!inherits(out, "try-error") && !is.null(out) && "Description" %in% names(out)) {
      desc <- out$Description
      if (!all(is.na(desc))) return(paste(desc, collapse = " "))
    }
    backoff(i)
  }
  NA_character_
}

cli_h1("Fetching extended descriptions (only)")
handlers(global = TRUE)
with_progress({
  p <- progressor(steps = nrow(pairs))
  pairs <- pairs %>%
    mutate(description = pmap_chr(
      list(scholar_id, pubid),
      ~ { p(); fetch_description(..1, ..2) }
    ))
})

unified_ext <- unified %>% left_join(pairs, by = c("scholar_id", "pubid"))

# ---------------------------- 8) EEG TAGGING (via Description only) ---------

EEG_PATTERNS <- c(
  "eeg",
  "electro-?encephalograph\\w*",
  "\\bp100\\b", "\\bp1\\b", "\\bn1\\b",
  "\\bp2\\b", "\\bn2\\b",
  "\\bp3\\b", "\\bp300\\b",
  "\\bn400\\b", "\\bp600\\b",
  "\\bcnv\\b", "\\bmmn\\b",
  "\\bern\\b", "\\bfrn\\b",
  "\\blrp\\b"
)
EEG_REGEX <- regex(str_c(EEG_PATTERNS, collapse = "|"), ignore_case = TRUE)

eeg_tagged <- unified_ext %>%
  mutate(
    check = str_detect(str_to_lower(description %||% ""), EEG_REGEX) |
      str_detect(str_to_lower(journal %||% ""), EEG_REGEX)  # keep as weak fallback if you want
  ) %>%
  group_by(scholar_id) %>%
  mutate(
    total_pubs = n(),
    eeg_pubs   = sum(check, na.rm = TRUE),
    prop_eeg   = if_else(total_pubs > 0, eeg_pubs / total_pubs, NA_real_)
  ) %>%
  ungroup()

eeg_tagged |> 
  select(-pubid, -cid, -scholar_id) |> 
  write.csv("WRITE THE TAGGED FILE (IN THIS CASE EEG-TAGGED")
