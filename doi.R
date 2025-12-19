install.packages("impactr", dependencies = TRUE)
install.packages("rcrossref", dependencies = TRUE)
rcrossref
impactr

library(scholar)
library(rcrossref)

install.packages("europepmc", dependencies = TRUE)
library(europepmc)

library(europepmc)

get_doi_europepmc <- function(title, author = NULL, year = NULL, limit = 5) {
  # Build Europe PMC query
  q <- paste0('TITLE:"', title, '"')
  if (!is.null(author)) q <- paste(q, paste0('AND AUTHOR:"', author, '"'))
  if (!is.null(year))   q <- paste(q, paste0("AND PUB_YEAR:", year))
  
  # Query EPMC
  res <- tryCatch(
    epmc_search(q, limit = limit, synonym = FALSE),
    error = function(e) return(NULL)
  )
  
  
  
  
  
  # ✔ Handle NULL or unexpected result structures
  if (is.null(res)) return(NA_character_)
  if (!is.data.frame(res)) return(NA_character_)
  if (nrow(res) == 0) return(NA_character_)
  if (!"doi" %in% colnames(res)) return(NA_character_)
  
  # Return first DOI found
  res$doi[1]
}


get_doi_europepmc("Estimating individual subjective values of emotion regulation strategies")


#--- let's see ---

library(europepmc)

get_doi_europepmc <- function(title, limit = 5) {
  if (is.na(title) || title == "") return(NA_character_)
  
  q <- paste0('TITLE:"', title, '"')
  
  res <- tryCatch(
    epmc_search(q, limit = limit, synonym = FALSE),
    error = function(e) return(NULL)
  )
  
  if (is.null(res)) return(NA_character_)
  if (!is.data.frame(res)) return(NA_character_)
  if (!"doi" %in% colnames(res)) return(NA_character_)
  if (nrow(res) == 0) return(NA_character_)
  
  res$doi[1]
}
df <- read.csv("W:/HiWi ManyAnalysis/ThePubCatcher/experimental.csv", stringsAsFactors = FALSE)
df$doi <- sapply(df$title, get_doi_europepmc)
# it worked partially



#--- Cleaned df----

df <- read_csv("W:/HiWi ManyAnalysis/ThePubCatcher/data.csv")
df_cledf_clean <- df |>  filter(!is.na(DataUploaded)) |> 
  select(copyID, `Participant Name`)

df_clean |>  write.csv("W:/HiWi ManyAnalysis/ThePubCatcher/data.csv")
