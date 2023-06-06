
## launch with command: 
## nohup R CMD BATCH --no-save --no-restore backpull2022.R  ./Logs/backpull_log_$(date +%Y-%m-%d).txt &

## Global variables
ADS_TABLE = "race2022_utf8"  ## table for storing ads
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

PAGE_BACKPULL_START_DATE = '2021-09-01'

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

## long-lasting tokens
a = readLines("tokens.txt")
a_token = a

# a_token = c("EAADdgbOPVbgBACH96l2C2t2UXCzT1ICtImFx01mS4nDTxQOdWZClr2ZBHW9wK9MzGfhMXfdkcpiLJZBQV2oLXYY1mUnBsE11elhY0UvjZAz6sUJHkWk51KbggIZAaKMlNzfvCDCmctUdhZADQqG3WKJddOqyPkPWEZD",
#             "EAADdgbOPVbgBABAWd4SlaB2gwy4rU1FXrdjVQnO5ZAi4JdnG1NZBFdRN3TDJCNN87sIJbVQQ9yqgCAXIrM5UzeS5zB3tfZBUc0GCyvUBZAUJFmCewokg0pFtY4vhNRucFac6yOagEdwmXhAe9sTWZAfkI4NXHbPOUOMeRn8ADiYUPd3CeZCmlC5rZC7WjmF7FV7cG3AhpRo0ZC9QwiCyoL0OTi5xUZCqxvuQZD",
#             "EAADdgbOPVbgBAFSIzYcnk0cbuZBXp5m2EupaLdNo8ZBD1zfrXlAVPvxBkrZBStdXkouUhWfqYs8fisOR97LdW3ZA0fXdZA1jdpYplLNhVPmoMj51XshrakZBKq2ZASI21bwrzfWratZC6ezY5KGBzIF15g9P84qe14oZD",
#             "EAADdgbOPVbgBAInZCfKtANsT3NP1ZCG3qsvdumV2DEe00uGqT2PRcCNdwUJiG30avC1A3j96fYZB0UdxnmRluc3k2cXZAZCZANpEmrRnPiXcV7qqbRXZA6sIcbaDRAZAUj0JNTH5wSn41Umo9eYNq8ZA6b52tsw1xSO5d4CtWnnZBVWwZDZD")



## open a connection to the MySQL server
DB_CONNECTOR = dbConnect(RMySQL::MySQL(), host="localhost",
                 user="xxxx", password="xxxx",
                 dbname="textsim_utf8")


## get the table of search_page_ids
## and the values of page ids

## identify the new page ids and insert them into the page_queue table
## get all page ids
all_page_ids = dbGetQuery(DB_CONNECTOR, 
                 'select distinct page_id from textsim_new.race2022')

## get the strings with queued page ids
page_id_queue = dbGetQuery(DB_CONNECTOR,
                           'select * from textsim_utf8.page_queue')

## unpack the strings from the queue
existing_page_ids = page_id_queue %>% select(x=page_id) %>% 
  mutate(page_id = strsplit(x, ',')) %>% 
  unnest(page_id) %>% 
  distinct(page_id)

## find out which page ids are new, pack them into strings
## assign the global backpull start date
new_page_ids = all_page_ids %>% 
  anti_join(existing_page_ids, by='page_id') %>% 
  mutate(r = row_number(),
         tile = r %/% 10) %>% 
  group_by(tile) %>% 
  summarise(page_id = paste0(page_id, collapse=','),
            N = 10, 
            date = PAGE_BACKPULL_START_DATE) %>% 
  select(page_id, N, date)

if (nrow(new_page_ids) > 0) {
  dbWriteTable(DB_CONNECTOR, name = 'page_queue', value=new_page_ids,
               row.names=F,
               append=T,
               overwrite=F)
}

## now that the queue has been updated
## download it and start processing the page_id strings
## in chronological order
page_id_queue = dbGetQuery(DB_CONNECTOR,
                           'select * from textsim_utf8.page_queue')

page_id_queue = page_id_queue %>% 
  group_by(page_id) %>% 
    summarise(date = max(date)) %>% 
  arrange(date)


tmp_app_health = list()
token_num = rep(1:length(a_token), length.out = nrow(page_id_queue)*2)
q_count = 1

## this is the endpoint for the ads_archive API
endpoint_url = 'https://graph.facebook.com/v12.0/ads_archive'

for (i in 1:nrow(page_id_queue)) {
  p_ids = page_id_queue$page_id[i]
  # p_ids = gsub(",105014271681911", "", p_ids, fixed=F)
  min_date = page_id_queue$date[i]
  
  ## step back one day to avoid issues with time zones
  min_date = strftime(as.Date(min_date) - 1, '%Y-%m-%d')
  
  ## update global variables
  PERSON = page_id_queue$page_id[i]
  QUERY = page_id_queue$page_id[i]
  
  query_url = param_set(endpoint_url, key="limit", value="329") %>% 
    param_set(key="ad_delivery_date_min", min_date) %>% 
    param_set("ad_type", "POLITICAL_AND_ISSUE_ADS") %>% 
    param_set("ad_active_status", "ALL") %>% 
    param_set("ad_reached_countries", "%5B%22US%22%5D") %>% 
    param_set(key="fields", value=paste0(INGESTED_FIELDS, collapse=",")) %>% 
    param_set(key="search_page_ids", value=p_ids)
  
  cat("Query url:\n", query_url, "\n")

  ## function to download hash tables
  download_hash_tables()
  
  ## c("ACTIVE", "INACTIVE")
  for (ad_active_status in c("ALL")) {
   cat("Asking for ads from page id", p_ids, "\n")

    ## get the data for a query and specific ad_active_status
    t = get_page_ads(query_url = query_url,
                 token=a_token[token_num[q_count]], 
                 page_ids = p_ids,
                 delay=3, 
                 ad_active_status = ad_active_status, 
                 app_health = tmp_app_health)
    q_count = q_count + 1
    
    tmp_app_health = t$app_health
    
    ## print a diagnostic message
    stats_app = paste(unlist(tmp_app_health), collapse=" ")
    print(paste0(i, " ", strftime(Sys.time(), "%H:%M:%S"), " ", 
                 PERSON, ": ", stats_app))
    
    ## update the record in the queue
    tmp_queue_df = tibble(page_id = p_ids, N=10,
                          date = strftime(Sys.Date(), "%Y-%m-%d"))
    
    ## this will write into the DB_CONNECTOR db, which should be texsim_utf8
    dbWriteTable(DB_CONNECTOR, name = 'page_queue',
                 value=tmp_queue_df,
                 row.names=F,
                 append=T,
                 overwrite=F)
    
  } ## end of the loop over ad_active_status
  
  ## terminate at 3 AM
  current_hour = as.numeric(strftime(Sys.time(), "%H"))
  if (current_hour == 3) {
    print("Current time is 3 AM. Time to give API some rest.")
    break
  }
} ## end of the loop over page_ids

dbDisconnect(DB_CONNECTOR)
