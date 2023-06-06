
## launch with command: 
## nohup R CMD BATCH --no-save --no-restore '--args resume=1' race2022.R  ./Logs/race_log_$(date +%Y-%m-%d).txt &
## resume is an optional argument, specifies the row in the query terms table
## that will be used as the starting one

## Global variables
ADS_TABLE = "race2022"  ## table for storing ads
ADS_LOG = "race2022_ads_log"
PAGE_ID_LOG = "page_id_log"

PERSON = ""  ## person associated with the query
QUERY = ""  ## the query string
DB_CONN = "" ## database connector

QUERY_HASH = data.frame() ## table with hash values for ads

INGESTED_FIELDS = c("id,ad_creation_time,ad_creative_bodies,ad_creative_body",
                    "ad_creative_link_caption,ad_creative_link_captions",
                    "ad_creative_link_description,ad_creative_link_descriptions",
                    "ad_creative_link_titles,ad_creative_link_title",
                    "ad_delivery_start_time,ad_delivery_stop_time",
                    "ad_snapshot_url,bylines,currency",
                    "delivery_by_region,demographic_distribution",
                    "funding_entity,impressions,languages",
                    "page_id,page_name,potential_reach,publisher_platforms",
                    "spend")

library(dplyr)
library(httr)
library(jsonlite)
library(RMySQL)
library(tidyr)
library(readr)
library(base64enc)
library(digest)
library(urltools)

source("race2022_utils.R")

## read command line arguments
args = commandArgs(trailingOnly = T)

## right now there can only be one argument 'resume'
if (length(args) == 1) {
  ## one argument - extract the name and value
  v = unlist(strsplit(args, split="="))
  
  ## if the name is 'resume' convert the value to number and assign
  if (trimws(v[1]) == 'resume') {
    resume_row = as.numeric(v[2])
    print(paste0("Settig resume_row to ", resume_row))
  } 
} else {
  resume_row = 1
}

## long-lasting tokens
a = readLines("tokens.txt")
a_token = a

# a_token = c("EAADdgbOPVbgBACH96l2C2t2UXCzT1ICtImFx01mS4nDTxQOdWZClr2ZBHW9wK9MzGfhMXfdkcpiLJZBQV2oLXYY1mUnBsE11elhY0UvjZAz6sUJHkWk51KbggIZAaKMlNzfvCDCmctUdhZADQqG3WKJddOqyPkPWEZD",
#             "EAADdgbOPVbgBABAWd4SlaB2gwy4rU1FXrdjVQnO5ZAi4JdnG1NZBFdRN3TDJCNN87sIJbVQQ9yqgCAXIrM5UzeS5zB3tfZBUc0GCyvUBZAUJFmCewokg0pFtY4vhNRucFac6yOagEdwmXhAe9sTWZAfkI4NXHbPOUOMeRn8ADiYUPd3CeZCmlC5rZC7WjmF7FV7cG3AhpRo0ZC9QwiCyoL0OTi5xUZCqxvuQZD",
#             "EAADdgbOPVbgBAFSIzYcnk0cbuZBXp5m2EupaLdNo8ZBD1zfrXlAVPvxBkrZBStdXkouUhWfqYs8fisOR97LdW3ZA0fXdZA1jdpYplLNhVPmoMj51XshrakZBKq2ZASI21bwrzfWratZC6ezY5KGBzIF15g9P84qe14oZD",
#             "EAADdgbOPVbgBAInZCfKtANsT3NP1ZCG3qsvdumV2DEe00uGqT2PRcCNdwUJiG30avC1A3j96fYZB0UdxnmRluc3k2cXZAZCZANpEmrRnPiXcV7qqbRXZA6sIcbaDRAZAUj0JNTH5wSn41Umo9eYNq8ZA6b52tsw1xSO5d4CtWnnZBVWwZDZD")


## this is the endpoint for the ads_archive API
endpoint_url = 'https://graph.facebook.com/v12.0/ads_archive'

## parameters
## essentially, all fields that the API returns
## the search parameters are added later
min_date = as.character(Sys.Date() - 3)
## min_date = "2020-09-01"
## p = gsub("YYYY-MM-DD", min_date, p)
## p = 'limit=500&ad_delivery_date_min=YYYY-MM-DD&fields=publisher_platforms,ad_creative_link_caption,ad_creative_link_title,ad_creative_link_description,ad_creative_body,funding_entity,page_name,page_id,ad_snapshot_url,impressions,spend,ad_creation_time,ad_delivery_start_time,ad_delivery_stop_time,currency,region_distribution,demographic_distribution{age,gender,percentage,region}&ad_type=POLITICAL_AND_ISSUE_ADS&ad_active_status=ALL&ad_reached_countries=%5B%22US%22%5D'

query_url = param_set(endpoint_url, key="limit", value="200") %>% 
  param_set(key="ad_delivery_date_min", min_date) %>% 
  param_set("ad_type", "POLITICAL_AND_ISSUE_ADS") %>% 
  param_set("ad_active_status", "ALL") %>% 
  param_set("ad_reached_countries", "%5B%22US%22%5D") %>% 
  param_set(key="fields", value=paste0(INGESTED_FIELDS, collapse=","))

## open a connection to the MySQL server
DB_CONNECTOR = dbConnect(RMySQL::MySQL(), host="localhost",
                 user="xxxx", password="xxxx",
                 dbname="textsim_new")



## get the search terms table
## depending on the task, this could also be a query to a table in the database
## search_terms = read_csv("keywords_and_pages.csv")
tmp = dbGetQuery(DB_CONNECTOR,
                 "select name, to_base64(term) as value from senate2022 where in_the_race = 'yes';")

search_terms = tmp
search_terms$person = tmp$name

for (j in 1:nrow(tmp)) {
  search_terms$term[j] = rawToChar(
    base64decode(tmp$value[j])
  )
}

tmp_app_health = list()
token_num = rep(1:length(a_token), length.out = nrow(search_terms)*2)
q_count = 1

for (i in resume_row:nrow(search_terms)) {
  term = search_terms$term[i]
  p_ids = ""
  
  ## update global variables
  PERSON = search_terms$person[i]
  QUERY = search_terms$term[i]
  
  ## function to download hash tables
  download_hash_tables()
  
  ## c("ACTIVE", "INACTIVE")
  for (ad_active_status in c("ALL")) {
    ## get the data for a query and specific ad_active_status
    t = get_page(query_url = query_url,
                 token=a_token[token_num[q_count]], 
                 term=term, delay=3, 
                 ad_active_status = ad_active_status, 
                 app_health = tmp_app_health)
    q_count = q_count + 1
    
    tmp_app_health = t$app_health
    
    ## print a diagnostic message
    stats_app = paste(unlist(tmp_app_health), collapse=" ")
    print(paste0(i, " ", strftime(Sys.time(), "%H:%M:%S"), " ", 
                 PERSON, ": ", stats_app))
    

  } ## end of the loop over ad_active_status
} ## end of the loop over search terms

dbDisconnect(DB_CONNECTOR)
