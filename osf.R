library(osfr)



get_osf_user_summary <- function(OSF) {
  
  tryCatch({
    
    user <- osf_retrieve_user(OSF)
    registrations <- osf_ls_nodes(user, n = Inf)
    
    user_flat <- fromJSON(toJSON(user, auto_unbox = TRUE), flatten = TRUE)
    user_df <- as.data.frame(user_flat)
    
    date <- user_flat["meta.attributes.date_registered"]
    
    year <- as.integer(
      format(
        as.POSIXct(date$meta.attributes.date_registered),
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

results <- test |> 
  mutate(test = map(osfid, get_osf_user_summary)) |> 
  unnest(test) |> 
  select(-osf_id, -osf_name)

