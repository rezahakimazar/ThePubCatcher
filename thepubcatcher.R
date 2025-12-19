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
  library(osfr)
  library(writexl)
  library(jsonlite)
  library(stringi)
})

# ---------------------------- 1) CONFIG & HELPERS ----------------------------

INPUT_CSV <- "W:/HiWi ManyAnalysis/ThePubCatcher/SeparatedDatasets/Antonio_Maffei.csv"
SJR_CSV   <- "W:/HiWi ManyAnalysis/ThePubCatcher/sjr.csv"
OUT_DIR   <- "W:/HiWi ManyAnalysis/ThePubCatcher/SeparatedDatasets/Antonio_Maffei"
CACHE_DIR <- fs::path(OUT_DIR, "cache")

dir_create(OUT_DIR); dir_create(CACHE_DIR)

# --- UPDATED TIMING TO AVOID GOOGLE SCHOLAR RATE LIMITS ---

# Pauses between requests
PAUSE_MIN_SEC <- 3.5      
PAUSE_MAX_SEC <- 7.5      

# Retry fewer times, but with longer gaps
MAX_TRIES     <- 4        



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
  select(
    analysisid,
    scholar_id,
    author_name,
    osfid,
    osf_results,
    everything()
  )

sjr_raw <- read_csv2(SJR_CSV, show_col_types = FALSE)

# ---------------------------- 3) AUTHOR METRICS -----------------------------

fetch_metrics_one <- function(id, author_name, analysisid, osfid, osf_results) {
  attempt <- 1
  repeat {
    res <- try(scholar::get_profile(id), silent = TRUE)
    
    if (inherits(res, "try-error") || is.atomic(res) || is.null(res)) {
      if (attempt >= MAX_TRIES) {
        return(tibble(
          scholar_id   = id,
          analysisid   = analysisid,
          osfid        = osfid,
          osf_results  = osf_results,
          author_name  = author_name,
          h_index      = NA_integer_,
          i10_index    = NA_integer_,
          total_cites  = NA_integer_,
          error        = "profile_fetch_failed"
        ))
      }
      backoff(attempt); attempt <- attempt + 1; next
    }
    
    ppause()
    return(tibble(
      scholar_id   = id,
      analysisid   = analysisid,
      osfid        = osfid,
      osf_results  = osf_results,
      author_name  = author_name,
      h_index      = res$h_index %||% NA_integer_,
      i10_index    = res$i10_index %||% NA_integer_,
      total_cites  = res$total_cites %||% NA_integer_,
      error        = NA_character_
    ))
  }
}


cli_h1("Fetching author metrics")
pbm <- progress_bar$new(format="  [:bar] :current/:total :percent (:eta) metrics",
                        total=nrow(ids), clear=FALSE, width=60)

author_metrics <- pmap_dfr(
  list(
    ids$scholar_id,
    ids$author_name,
    ids$analysisid,
    ids$osfid,
    ids$osf_results
  ),
  fetch_metrics_one
) %>% clean_names()


# ---------------------------- 4) PUBLICATIONS (+CACHE) ----------------------

cache_read  <- function(path) if (fs::file_exists(path)) readRDS(path) else NULL
cache_write <- function(obj, path) saveRDS(obj, path)

fetch_pubs_one <- function(id, author_name, analysisid, osfid, osf_results) {
  cache_file <- fs::path(CACHE_DIR, glue("pubs_{id}.rds"))
  cached <- cache_read(cache_file)
  if (!is.null(cached)) return(cached)
  
  attempt <- 1
  repeat {
    res <- try(scholar::get_publications(id), silent = TRUE)
    
    if (inherits(res, "try-error") || is.atomic(res) || is.null(res) || nrow(res) == 0) {
      if (attempt >= MAX_TRIES) {
        out <- tibble(
          scholar_id   = id,
          analysisid   = analysisid,
          osfid        = osfid,
          osf_results  = osf_results,
          author_name  = author_name,
          title        = NA_character_,
          year         = NA_character_,
          cites        = NA_character_,
          pubid        = NA_character_,
          error        = "pubs_fetch_failed"
        )
        cache_write(out, cache_file)
        return(out)
      }
      backoff(attempt); attempt <- attempt + 1; next
    }
    
    out <- res %>%
      clean_names() %>%
      mutate(
        scholar_id   = id,
        analysisid   = analysisid,
        osfid        = osfid,
        osf_results  = osf_results,
        author_name  = author_name
      )
    
    cache_write(out, cache_file)
    ppause()
    return(out)
  }
}


cli_h1("Fetching publications")
pbp <- progress_bar$new(format="  [:bar] :current/:total :percent (:eta) pubs",
                        total=nrow(ids), clear=FALSE, width=60)

all_pubs <- pmap_dfr(
  list(
    ids$scholar_id,
    ids$author_name,
    ids$analysisid,
    ids$osfid,
    ids$osf_results
  ),
  fetch_pubs_one
)

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

fetch_extended <- function(scholar_id, pubid, tries = 6) {
  
  # DEFAULT output — ensures authors_full ALWAYS exists
  default <- tibble(
    description  = NA_character_,
    authors_full = NA_character_
  )
  
  for (i in seq_len(tries)) {
    
    out <- try(safe_rate(scholar_id, pubid), silent = TRUE)
    
    # Invalid return → retry
    if (inherits(out, "try-error") || is.null(out) || !is.list(out)) {
      backoff(i)
      next
    }
    
    # Extract fields safely
    desc <- if ("Description" %in% names(out))
      paste(out$Description, collapse = " ")
    else NA_character_
    
    auth <- if ("Authors" %in% names(out))
      paste(out$Authors, collapse = ", ")
    else NA_character_
    
    return(tibble(
      description  = desc,
      authors_full = auth
    ))
  }
  
  return(default)
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

pubs_ok <- dplyr::bind_cols(pubs_ok, as_tibble(ext_data))

if (!"authors_full" %in% names(pubs_ok)) {
  pubs_ok$authors_full <- NA_character_
}

# ---------------------------- 5) UNIFY (Pubs + Metrics) ---------------------

am_small <- author_metrics %>%
  select(
    scholar_id,
    osfid,
    osf_results,
    author_name_metrics = author_name,
    h_index,
    i10_index,
    total_cites
  )

unified <- pubs_ok %>%
  mutate(authors = authors_full) %>%
  left_join(am_small, by = "scholar_id") %>%
  mutate(author_name = coalesce(author_name, author_name_metrics)) %>%
  select(-author_name_metrics, -osfid.x, -osf_results.x) %>%
  relocate(
    analysisid,
    scholar_id,
    osfid.y,
    osf_results.y,
    author_name,
    authors,
    h_index,
    i10_index,
    total_cites
  ) |> 
  rename(osfid = osfid.y)

#------------- STANDARDIZE THE NAMES OF THE JOURNALS FOR THE FETCHED DATA ---------------

normalize_journal <- function(x) {
  x %>%
    stri_trans_general("Latin-ASCII") %>%  # remove accents
    str_to_lower() %>%
    str_replace_all("&", " and ") %>%      # standardize &
    str_replace_all("[^a-z0-9 ]", " ") %>% # remove punctuation
    str_squish()
}

unified <- unified %>%
  mutate(journal = normalize_journal(journal))




# ---------------------------- AUTHORSHIP ROLE (LAST NAME LOGIC, CLEANED) ------------------------------

extract_lastname <- function(x) {
  x %>%
    stringr::str_replace_all("\\*", "") %>%            # remove asterisks
    stringr::str_replace_all(",", " ") %>%             # handle "Last, First"
    stringr::str_replace_all("[^A-Za-z\\s]", "") %>%   # remove punctuation
    stringr::str_squish() %>%
    stringr::str_split("\\s+") %>%
    purrr::map_chr(function(parts) {
      if (length(parts) == 0) return(NA_character_)
      
      # remove single-letter initials (T, J, etc.)
      parts <- parts[nchar(parts) > 1]
      
      # take the LAST remaining token as surname
      if (length(parts) == 0) NA_character_ else tolower(tail(parts, 1))
    })
}

unified <- unified %>%
  mutate(
    authors_list = str_split(authors, ",\\s*"),
    
    first_author_raw = map_chr(authors_list, ~ .x[1] %||% NA_character_),
    last_author_raw  = map_chr(authors_list, ~ .x[length(.x)] %||% NA_character_),
    
    author_lastname = extract_lastname(author_name),
    first_lastname  = extract_lastname(first_author_raw),
    last_lastname   = extract_lastname(last_author_raw),
    
    authorship_role = case_when(
      author_lastname == first_lastname ~ "first",
      author_lastname == last_lastname  ~ "last",
      TRUE                              ~ "middle"
    )
  ) %>%
  select(-authors_list, -first_author_raw, -last_author_raw,
         -first_lastname, -last_lastname, -author_lastname)


# ---------------------------- ROBUST JOURNAL NORMALIZATION ----------------------------


# --- Normalize SJR table ---
sjr_clean <- sjr_raw %>%
  clean_names() %>%
  mutate(
    title = normalize_journal(title),
    sjr_best_quartile = str_to_upper(sjr_best_quartile)
  ) %>%
  group_by(title) %>%
  summarise(
    sjr_best_quartile = case_when(
      any(sjr_best_quartile == "Q1") ~ "Q1",
      any(sjr_best_quartile == "Q2") ~ "Q2",
      any(sjr_best_quartile == "Q3") ~ "Q3",
      any(sjr_best_quartile == "Q4") ~ "Q4",
      TRUE ~ NA_character_
    ),
    journal_h_index = suppressWarnings(max(h_index, na.rm = TRUE)),
    .groups = "drop"
  ) %>%
  rename(journal_title = title)  |> 
  select(-journal_h_index)



# --- Case-insensitive, punctuation-insensitive join ---
unified <- unified %>%
  left_join(
    sjr_clean,
    by = c("journal" = "journal_title")
  )

non_journals <- c(
  "osf",
  "arxiv",
  "biorxiv",
  "medrxiv",
  "psyarxiv"
)

unified <- unified %>%
  mutate(
    journal = if_else(journal %in% non_journals, NA_character_, journal)
  )

colnames(unified)


# ---------------------------- 7) EEG TAGGING --------------------------------

EEG_PATTERNS <- c(
  "\\beeg\\b",
  "electro-?encephalograph\\w*",
  "\\bp100\\b", "\\bp1\\b", "\\bn1\\b",
  "\\bp2\\b", "\\bn2\\b",
  "\\bp3\\b", "\\bp300\\b",
  "\\bn400\\b", "\\bp600\\b",
  "\\bcnv\\b", "\\bmmn\\b",
  "\\bern\\b", "\\bfrn\\b",
  "\\blrp\\b",
  "\\berp\\b",
  "\\bssvep\\b",
  "steady[- ]state\\s+visually\\s+evoked\\s+potential\\w*",
  "\\bvisual\\s+evoked\\s+potential\\w*"
)

EEG_REGEX <- regex(str_c(EEG_PATTERNS, collapse="|"), ignore_case=TRUE)

eeg_tagged <- unified %>%
  mutate(
        check =
      str_detect(str_to_lower(description %||% ""), EEG_REGEX) |
      str_detect(str_to_lower(title %||% ""),       EEG_REGEX)   
  ) %>%
  group_by(scholar_id) %>%
  mutate(
    total_pubs = n(),
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

# ABSTRACTS
get_abstract_pubmed <- function(pmid) {
  if (is.na(pmid)) return(NA_character_)
  
  rec <- tryCatch(
    entrez_fetch(db="pubmed", id=pmid, rettype="abstract"),
    error = function(e) return(NA_character_)
  )
  
  rec
}
final_version$abstract_full <- sapply(
  final_version$doi,
  function(d) get_abstract_pubmed(doi_to_pmid(d))
)


# ---------------------------- EEG TAGGING ON FULL ABSTRACT ----------------------------

final_version <- final_version %>%
  mutate(
    check_full_abstract = str_detect(
      str_to_lower(abstract_full %||% ""),
      EEG_REGEX
    )
  )

# ---------------------------- UPDATE CHECK USING FULL ABSTRACT ----------------------------

final_version <- final_version %>%
  mutate(
    check = check | check_full_abstract
  ) |> 
  select(-check_full_abstract)

final_version <- final_version |> 
  mutate(eeg_pubs = sum(check == "TRUE", na.rm = TRUE),
         prop_eeg   = if_else(total_pubs > 0, eeg_pubs / total_pubs, NA_real_)
)

# ---------------------------- EEG-ONLY H-INDEX --------------------------------

# h-index helper
h_index_vec <- function(cites_vec) {
  if (length(cites_vec) == 0 || all(is.na(cites_vec))) return(0)
  c_sorted <- sort(as.numeric(cites_vec), decreasing = TRUE)
  sum(c_sorted >= seq_along(c_sorted))
}

# Compute EEG-only h-index per author
corrected_h <- final_version %>%
  filter(check == TRUE) %>%                     
  group_by(scholar_id) %>%
  summarise(corrected_h_index = h_index_vec(cites), .groups="drop")

# Join back into the final dataframe
final_version <- final_version %>%
  left_join(corrected_h, by = "scholar_id") |> 
  select(-description, -abstract_full)


final_version <- final_version |>   rename(osf_results = osf_results.y)


# ---------------------------- SAVE RESULTS ----------------------------------

clean_version <- final_version |>
  filter(check == TRUE) |>
  select(
    analysisid,
    scholar_id,
    osfid,
    osf_results.y,
    everything(),
    -authors_full,
    -authors,
    -journal,
    -pubid,
    -cid,
    -number,
    -check
  )


  


#----- ONLY KEEP FIRST AND LAST AUTHORSHIP----
final_version <- final_version |> 
  filter(authorship_role == "first" | authorship_role == "last") |> 
  select(-authors)

# Recency-weighted EEG impact per author (sum over EEG papers only)
# Assumes your data frame is named `df` and already contains ONLY EEG-related papers
# If not, see the optional filter section below.


# -----------------------
# User-set parameters
# -----------------------
HALF_LIFE_YEARS <- 5          # H: citations weight halves every H years
CURRENT_YEAR    <- 2026       # set to the analysis year you want to use
USE_LOG1P        <- TRUE      # TRUE = log(1 + cites), FALSE = raw cites

df_eeg <- final_version |> filter(check == TRUE)

# -----------------------
# Compute per-paper score (EEG papers only)
# -----------------------
lambda <- log(2) / HALF_LIFE_YEARS

df_scored <- df_eeg %>%
  mutate(
    # Ensure required columns exist and are usable
    year  = suppressWarnings(as.integer(year)),
    cites = suppressWarnings(as.numeric(cites)),
    
    # Age in years (paper published this year -> age = 1)
    age = pmax(1L, CURRENT_YEAR - year + 1L),
    
    # Citation transform
    cite_term = if (USE_LOG1P) log1p(pmax(0, cites)) else pmax(0, cites),
    
    # Exponential time discount
    time_weight = exp(-lambda * age),
    
    # Final per-paper score
    paper_score = cite_term * time_weight
  )

# -----------------------
# Aggregate to author impact (SUM of paper scores)
# -----------------------
author_impact <- df_scored %>%
  group_by(scholar_id, author_name) |> 
  mutate(sum_impact = sum(paper_score, na.rm = TRUE))

#---- CHECK OSF----
get_osf_user_summary <- function(OSF) {
  tryCatch({
    
    user <- osf_retrieve_user(OSF)
    registrations <- osf_ls_nodes(user, n = Inf)
    user_flat <- fromJSON(toJSON(user, auto_unbox = TRUE), flatten = TRUE)
    user_df <- as.data.frame(user_flat)
    
    date <- user_flat[["meta.attributes.date_registered"]]
    
    year <- as.integer(
      format(
        as.POSIXct(date),
        "%Y"
      )
    )
    
    user_df |>
      mutate(
        year_joined = year,
        n_registrations = nrow(registrations)
      ) |>
      select(
        osf_id = id,
        osf_name = name,
        year_joined,
        n_registrations
      )
    
  }, error = function(e) {
    tibble(
      osf_id = OSF,
      osf_name = NA_character_,
      year_joined = NA_integer_,
      n_registrations = NA_integer_
    )
  })
}

osf_checked <- author_impact |> 
  mutate(test = map(osfid, get_osf_user_summary)) |> 
  unnest(test) |> 
  select(-osf_id, -osf_name, -cite_term, -time_weight, -paper_score, -age) |> 
  mutate(eegcites = sum(cites))




# ---------------------------- ONE ROW PER AUTHOR SUMMARY ----------------------------

author_summary <- osf_checked %>%
  group_by(scholar_id, analysisid, author_name, osfid, osf_results) %>%
  summarise(
    h_index             = first(h_index),
    corrected_h_index   = first(corrected_h_index),
    i10_index           = first(i10_index),
    total_cites        = first(total_cites),
    total_pubs          = first(total_pubs),
    total_eeg_pubs      = first(eeg_pubs),
    
    osf_join            = first(year_joined),  # ← OPTIONAL ALIAS
    
    osf_registrations   = first(n_registrations),
    eegcites            = first(eegcites),
    eeg_impact          = first(sum_impact),
    prop_eeg            = if_else(total_pubs > 0, total_eeg_pubs / total_pubs, NA_real_),
    first_eeg_pub       = suppressWarnings(min(as.numeric(year), na.rm = TRUE)),
    .groups = "drop"
  ) |> 
  relocate(osfid, .before = author_name) |> 
  relocate(osf_results, .after = osf_registrations) |> 
  relocate(first_eeg_pub, .before = osf_join) |> 
  relocate(prop_eeg, .after = total_eeg_pubs)
  



#---- OUTPUT ----
write_xlsx(osf_checked, "W:/HiWi ManyAnalysis/ThePubCatcher/SeparatedDatasets/Antonio_Maffei/Antonio_Maffei_full.xlsx")
write_xlsx(author_summary, "W:/HiWi ManyAnalysis/ThePubCatcher/SeparatedDatasets/Antonio_Maffei/Antonio_Maffei_summary.xlsx")

