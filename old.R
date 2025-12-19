# ===============================================================
# Google Scholar + SJR Enrichment Pipeline (extended-only version)
# ======================= METHOD 2 VERSION ========================
# Pulls FULL AUTHORS from get_publication_data_extended()
# ===============================================================

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
  library(progressr)
  library(europepmc)
  library(rentrez)
  library(XML)
  library(writexl)
})

# ---------------------------- 1) CONFIG & HELPERS ----------------------------

INPUT_CSV <- "W:/HiWi ManyAnalysis/ThePubCatcher/batch01.csv"
SJR_CSV   <- "W:/HiWi ManyAnalysis/ThePubCatcher/sjr.csv"
OUT_DIR   <- "W:/HiWi ManyAnalysis/ThePubCatcher/newbatches/batch01"
CACHE_DIR <- fs::path(OUT_DIR, "cache")

dir_create(OUT_DIR); dir_create(CACHE_DIR)

PAUSE_MIN_SEC <- 1.0
PAUSE_MAX_SEC <- 2.5
MAX_TRIES     <- 3

PLOT_YEAR_MIN <- 2010
PLOT_YEAR_MAX <- 2025

`%||%` <- function(x, y) if (is.null(x) || (length(x)==1 && is.na(x))) y else x
ppause  <- function(min_s=PAUSE_MIN_SEC, max_s=PAUSE_MAX_SEC) Sys.sleep(runif(1,min_s,max_s))
backoff <- function(i) Sys.sleep((2^i) + runif(1,0,1))
norm_title <- function(x) str_squish(str_to_lower(x))

# ---------------------------- 2) LOAD INPUTS --------------------------------

cli_h1("Loading inputs")

ids <- read_csv(INPUT_CSV, show_col_types = FALSE) %>%
  clean_names() %>%
  rename(
    scholar_id  = id,
    author_name = name
  ) %>%
  mutate(across(everything(), as.character)) %>%
  distinct() %>%
  select(analysisid, everything())

sjr_raw <- read_csv2(SJR_CSV, show_col_types = FALSE)

# ---------------------------- 3) AUTHOR METRICS -----------------------------

fetch_metrics_one <- function(id, author_name, analysisid) {
  attempt <- 1
  repeat {
    res <- try(scholar::get_profile(id), silent = TRUE)
    if (!inherits(res, "try-error")) {
      ppause()
      return(tibble(
        scholar_id  = id,
        analysisid  = analysisid,
        author_name = author_name,
        h_index     = res$h_index %||% NA_integer_,
        i10_index   = res$i10_index %||% NA_integer_,
        total_cites = res$total_cites %||% NA_integer_,
        error       = NA_character_
      ))
    }
    if (attempt >= MAX_TRIES) {
      return(tibble(
        scholar_id  = id,
        analysisid  = analysisid,
        author_name = author_name,
        h_index = NA_integer_, i10_index = NA_integer_, total_cites = NA_integer_,
        error = as.character(res)
      ))
    }
    Sys.sleep(attempt*1.5); attempt <- attempt + 1
  }
}

cli_h1("Fetching author metrics")
pbm <- progress_bar$new(format="  [:bar] :current/:total :percent (:eta) metrics",
                        total=nrow(ids), clear=FALSE, width=60)

author_metrics <- pmap_dfr(
  list(ids$scholar_id, ids$author_name, ids$analysisid),
  function(id, nm, anid) {
    pbm$tick()
    fetch_metrics_one(id, nm, anid)
  }
) %>% clean_names()

# ---------------------------- 4) PUBLICATIONS (+CACHE) ----------------------

cache_read  <- function(path) if (fs::file_exists(path)) readRDS(path) else NULL
cache_write <- function(obj, path) saveRDS(obj, path)

fetch_pubs_one <- function(id, author_name, analysisid) {
  cache_file <- fs::path(CACHE_DIR, glue("pubs_{id}.rds"))
  cached <- cache_read(cache_file)
  if (!is.null(cached)) return(cached)
  
  attempt <- 1
  repeat {
    res <- try(scholar::get_publications(id=id), silent=TRUE)
    if (!inherits(res, "try-error")) {
      out <- res %>%
        clean_names() %>%
        mutate(
          scholar_id  = id,
          author_name = author_name,
          analysisid  = analysisid
        )
      cache_write(out, cache_file)
      ppause()
      return(out)
    }
    if (attempt >= MAX_TRIES) {
      out <- tibble(
        scholar_id  = id,
        author_name = author_name,
        analysisid  = analysisid,
        error = as.character(res)
      )
      cache_write(out, cache_file)
      return(out)
    }
    Sys.sleep(attempt*1.5); attempt <- attempt + 1
  }
}

cli_h1("Fetching publications")
pbp <- progress_bar$new(format="  [:bar] :current/:total :percent (:eta) pubs",
                        total=nrow(ids), clear=FALSE, width=60)

all_pubs <- pmap(
  list(ids$scholar_id, ids$author_name, ids$analysisid),
  function(id, nm, anid) {
    pbp$tick()
    fetch_pubs_one(id, nm, anid)
  }
) %>% list_rbind()

if ("error" %in% names(all_pubs)) {
  pub_errors <- all_pubs %>% filter(!is.na(error))
  pubs_ok    <- all_pubs %>% filter(is.na(error)) %>% select(-error)
} else {
  pub_errors <- tibble()
  pubs_ok    <- all_pubs
}

pubs_ok <- pubs_ok %>% distinct(scholar_id, title, .keep_all = TRUE)

# ---------------------------- 4B) FULL AUTHORS (EXTENDED API) ---------------

cli_h1("Fetching full authors from EXTENDED metadata")

# memoized + rate-limited
get_pub_ext_mem <- memoise::memoise(get_publication_data_extended)
safe_rate <- ratelimitr::limit_rate(get_pub_ext_mem, rate(n=1, period=2))

fetch_extended <- function(scholar_id, pubid, tries=6) {
  for (i in seq_len(tries)) {
    out <- try(safe_rate(scholar_id, pubid), silent=TRUE)
    if (!inherits(out, "try-error") && !is.null(out)) {
      
      desc <- if ("Description" %in% names(out))
        paste(out$Description, collapse=" ")
      else NA_character_
      
      authors_full <- if ("Authors" %in% names(out))
        paste(out$Authors, collapse=", ")
      else NA_character_
      
      return(tibble(
        description  = desc,
        authors_full = authors_full
      ))
    }
    backoff(i)
  }
  tibble(description=NA_character_, authors_full=NA_character_)
}

pb_ext <- progress_bar$new(
  format="  [:bar] :current/:total :percent (:eta) ext",
  total=nrow(pubs_ok), clear=FALSE, width=60
)

ext_data <- pmap_dfr(
  list(pubs_ok$scholar_id, pubs_ok$pubid),
  function(sid, pid) {
    pb_ext$tick()
    fetch_extended(sid, pid)
  }
)

pubs_ok <- bind_cols(pubs_ok, ext_data)

# ---------------------------- 5) UNIFY (Pubs + Metrics) ---------------------

am_small <- author_metrics %>%
  select(scholar_id,
         author_name_metrics = author_name,
         h_index, i10_index, total_cites)

unified <- pubs_ok %>%
  mutate(authors = authors_full) %>%   # FULL AUTHORS HERE
  select(-author) %>%                  # remove truncated author column
  left_join(am_small, by="scholar_id") %>%
  mutate(author_name = coalesce(author_name, author_name_metrics)) %>%
  select(-author_name_metrics) %>%
  relocate(analysisid, scholar_id, author_name, authors,
           h_index, i10_index, total_cites)

# ---------------------------- AUTHORSHIP ROLE (SIMPLE VERSION) -------------------------------

normalize_name <- function(x) {
  x %>%
    tolower() %>%
    stringr::str_replace_all("[^a-z ]", "") %>%
    stringr::str_squish()
}

unified <- unified %>%
  mutate(
    # normalize the profile owner's name
    author_name_norm = normalize_name(author_name),
    
    # split full author list and normalize
    authors_list = str_split(authors, ",\\s*"),
    authors_list_norm = map(authors_list, ~ normalize_name(.x)),
    
    # first author
    is_first_author = map2_lgl(authors_list_norm, author_name_norm, ~ {
      length(.x) > 0 && .x[1] == .y
    }),
    
    # last author
    is_last_author = map2_lgl(authors_list_norm, author_name_norm, ~ {
      length(.x) > 0 && .x[length(.x)] == .y
    }),
    
    # final simple rule:
    # first → "first", last → "last", otherwise → "middle"
    authorship_role = case_when(
      is_first_author ~ "first",
      is_last_author  ~ "last",
      TRUE            ~ "middle"
    )
  ) %>%
  select(-author_name_norm, -authors_list, -authors_list_norm)



# ---------------------------- 6) SJR CLEANING & JOIN ------------------------

sjr_clean <- sjr_raw %>%
  clean_names() %>%
  mutate(
    title_norm = norm_title(title),
    sjr_best_quartile = str_to_upper(sjr_best_quartile)
  ) %>%
  group_by(title_norm) %>%
  summarise(
    sjr_best_quartile = case_when(
      any(sjr_best_quartile=="Q1") ~ "Q1",
      any(sjr_best_quartile=="Q2") ~ "Q2",
      any(sjr_best_quartile=="Q3") ~ "Q3",
      any(sjr_best_quartile=="Q4") ~ "Q4",
      TRUE ~ NA_character_
    ),
    journal_h_index = suppressWarnings(max(h_index, na.rm=TRUE)),
    .groups="drop"
  ) %>%
  mutate(journal_h_index = ifelse(is.finite(journal_h_index),
                                  journal_h_index, NA_real_))

unified <- unified %>%
  mutate(title_norm = norm_title(journal)) %>%
  left_join(sjr_clean, by="title_norm") %>%
  select(-title_norm)

# ---------------------------- 7) EEG TAGGING --------------------------------

EEG_PATTERNS <- c(
  "eeg", "electro-?encephalograph\\w*",
  "\\bp100\\b", "\\bp1\\b", "\\bn1\\b",
  "\\bp2\\b", "\\bn2\\b",
  "\\bp3\\b", "\\bp300\\b",
  "\\bn400\\b", "\\bp600\\b",
  "\\bcnv\\b", "\\bmmn\\b",
  "\\bern\\b", "\\bfrn\\b",
  "\\blrp\\b", "erp"
)

EEG_REGEX <- regex(str_c(EEG_PATTERNS, collapse="|"), ignore_case=TRUE)

eeg_tagged <- unified %>%
  mutate(
    check = str_detect(str_to_lower(description %||% ""), EEG_REGEX) |
      str_detect(str_to_lower(journal %||% ""), EEG_REGEX)
  ) %>%
  group_by(scholar_id) %>%
  mutate(
    total_pubs = n(),
    eeg_pubs   = sum(check, na.rm=TRUE),
    prop_eeg   = if_else(total_pubs>0, eeg_pubs/total_pubs, NA_real_)
  ) %>%
  ungroup()

# ---------------------------- DOI + PUBTYPE ---------------------------------

get_doi_europepmc <- function(title, limit=5) {
  if (is.na(title) || title=="") return(NA_character_)
  q <- paste0('TITLE:"', title, '"')
  res <- tryCatch(epmc_search(q, limit=limit, synonym=FALSE),
                  error=function(e) return(NULL))
  if (is.null(res) || !"doi" %in% colnames(res) || nrow(res)==0) return(NA_character_)
  res$doi[1]
}

eeg_tagged$doi <- sapply(eeg_tagged$title, get_doi_europepmc)

final_version <- eeg_tagged

doi_to_pmid <- function(doi) {
  res <- entrez_search(db="pubmed", term=paste0(doi,"[DOI]"))
  if (length(res$ids)==0) return(NA)
  res$ids[1]
}

get_pubtype_pubmed <- function(pmid) {
  rec <- tryCatch(
    entrez_fetch(db = "pubmed", id = pmid, rettype = "xml", parsed = TRUE),
    error = function(e) return(NULL)
  )
  if (is.null(rec) || inherits(rec, "try-error")) return(NA)
  pub_types <- xpathSApply(rec, "//PublicationType", xmlValue)
  if (length(pub_types)==0) return(NA_character_)
  pub_types
}

get_pubtype_from_doi <- function(doi) {
  if (is.na(doi) || doi=="") return(NA)
  pmid <- doi_to_pmid(doi)
  if (is.na(pmid)) return(NA)
  get_pubtype_pubmed(pmid)
}

final_version$pubtype <- sapply(final_version$doi, function(x) {
  pt <- get_pubtype_from_doi(x)
  if (is.null(pt) || all(is.na(pt))) return(NA)
  paste(pt, collapse="; ")
})

# ---------------------------- SAVE RESULTS ----------------------------------

full_version <- final_version |>   write_xlsx("W:/HiWi ManyAnalysis/ThePubCatcher/newbatches/batch01_full.xlsx")

clean_version <- final_version |> 
  select(-authors_full, -is_first_author, -is_last_author, -pubid, -cid, -number, -scholar_id, -description) |> 
  rename(author_cites = total_cites,
          paper_cites = cites,
         paper_title = title,
         sjr_q = sjr_best_quartile
         ) |> 
  write_xlsx("W:/HiWi ManyAnalysis/ThePubCatcher/newbatches/batch01_clean.xlsx")

