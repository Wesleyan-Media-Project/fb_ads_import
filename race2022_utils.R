## file with functions supporting the pull of data from Facebook
library(dplyr)
library(httr)
library(jsonlite)
library(RMySQL)
library(readxl)
library(tidyr)
library(digest)
library(base64enc)
library(urltools)
library(stringi)

## function determining the delay between requests
## depending on the API usage metrics
## takes one argument - maximum value among three metrics
get_delay_value = function(m_usage) {
  d = dplyr::case_when(m_usage > 95 ~ 90,
                       m_usage > 90 ~ 30,
                       m_usage > 80 ~ 10,
                       m_usage > 75 ~ 5,
                       m_usage > 50 ~ 3,
                       TRUE ~ 3)
  return(d)
} ## end of function get_delay_value

## the information on the names of columns/JSON-keys
## came from FB ad archive API page
## https://developers.facebook.com/docs/marketing-api/reference/archived-ad/
## input is a list of elements
## each element is a record for an ad
get_info = function(x=list()) {
  n = length(x)
  df_list = list()
  
  for (k in 1:n) {
    list_values = sapply(x[[k]], toJSON, auto_unbox=T, digits=NA)
    tmp_df = tibble(col = names(list_values), value=as.character(list_values)) %>% 
      mutate(value = stri_replace_all(value, "", regex='(^")|("$)')) %>% 
      pivot_wider(names_from = col, values_from = value)
    
    df_list[[ k ]] = tmp_df
  }
  
  all_cols = paste0(INGESTED_FIELDS, collapse=",") %>% 
      stri_split(fixed=",") %>% unlist()
  
  ## template_df is necessary to ensure the unchanged ordering of columns
  ## otherwise, there will be problems with import into MySQL using dbWriteTable()
  template_df = tibble(col = all_cols, value = NA) %>% 
    pivot_wider(names_from = col, values_from = value)
  
  y1 = dplyr::bind_rows(df_list)
  y = bind_rows(template_df, y1) %>% filter(!is.na(id))
  
  return(y)
}

## get a page with records
## p is string with parameters (mostly field names)
## end_point is the endpoint URL
## token is the access token
## term is the search term string
## page_ids is the string with page ids
## usually it's only one page id, but it can be up to 10, separated by commas
## delay is the sleep interval in seconds
##
## function returns a data object, app usage object, and 
## paging_next URL if it was present
get_page = function(query_url = "", 
                    end_point = "", 
                    p="", token="", 
                    term="", delay=3.0, 
                    ad_active_status = "ALL",
                    app_health = list()) {
  
  pages = list()
  num_page = 1
  result = list()
  tmp_data = data.frame()
  
  ## user agent field
  ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36"
  
  ## if there were no search terms and no page ids, exit with empty data
  if (nchar(term) == 0) { 
    return(list(app_health = app_health, data=data.frame()))
  }
  
  ## modify the ad_active_status field
  ## and append search_terms and access_token fields
  url = param_set(query_url, key="ad_active_status", ad_active_status) %>% 
    param_set("search_terms", URLencode(term, reserved=T)) %>% 
    param_set("access_token", token)
  
  ## determine the delay on the basis of the max usage
  ## percentage take from app_health list
  ## case_when exits with a value as soon as a case is matched
  if (length(app_health)  == 3) {
    max_usage = max(sapply(app_health, '[', 1))
    delay = get_delay_value(max_usage)
  } ## end of if(length(app_health) == 3) structure
  
  ## submit the request
  Sys.sleep(delay)
  s = NULL; w = NULL;
  
  tries_left = 7
  while(tries_left > 0) {
    s = GET(url, add_headers("User-agent"=ua, 'Accept'='text/json',
                             "Cache-control"='no-cache'))
    
    if (status_code(s) == 200) {
      tries_left = -1 ## change the value so the loop is not repeated
    } else {
      ## print out the status message and then go to sleep for 30 seconds
      s_message = httr::content(s, as="text")
      try({ w = fromJSON(s_message)
            print(paste("Received status code", status_code(s)))
            print(w)
            print("Sleeping for 30 seconds")
      }, silent=FALSE)
      Sys.sleep(30) ##
      tries_left = tries_left - 1
    } ## end of the if(status_code(s) == 200)
    
    if (tries_left == 1) {
      dbDisconnect(DB_CONNECTOR)
      stop("Persistent API error")
    } ## end of the if (tries_left == 1) clause
  } ## end of the while(tries_left > 0)
  
  ## retrieve JSON content
  w = httr::content(s, as="text")
  
  ## convert to list
  r = list()
  try( { 
          r = fromJSON(w, simplifyDataFrame = F, flatten = F)
          print("got fromJSON data")
        }, 
       silent=FALSE)
  
  ## retrieve the X-App-Usage field from the header
  ## recently it became 'x-business-use-case-usage'
  tmp_app_health = app_health
  try( {
    print(headers(s)$`x-business-use-case-usage`)
    tmp_business_usage = fromJSON(headers(s)$`x-business-use-case-usage`)[[1]]
    tmp_app_health = list(object_count_pct=tmp_business_usage[1, "call_count"], 
        ## object_count_pct=tmp_business_usage[1, "object_count_pct"], - object_count_pct got replaced by call_count on 09/13
                          total_cputime = tmp_business_usage[1, "total_cputime"],
                          total_time = tmp_business_usage[1, "total_time"])
    print("got fromJSON app usage")
  },
  silent=FALSE)
  
  ## if some data was returned
  if (!is.null(r$data) & length(r$data) > 0) {
    tmp_data = get_info(r$data)
    insert_data(tmp_data, ad_active_status)
  } ## end of if not null r$data construct
  
  ## if paging:next is present, iterate
  if (!is.null(r$`paging`$`next`)) {
    more_pages = T
    
    r2 = list(app_health = tmp_app_health, data=NULL,
              next_page = r$`paging`$`next`)
    
    while(more_pages) {
      r2 = get_next_page(next_page = r2$next_page, 
                                     app_health = r2$app_health)
      if (r2$next_page == "") {
        more_pages = F
        tmp_app_health = r2$app_health
      }

      ## the get_next_page returns a dataframe
      ## in the element data?
      ## no need to perform
      if (!is.null(r2$data) & nrow(r2$data) > 0) {
        tmp_data = r2$data
        insert_data(tmp_data, ad_active_status) ## this part is new
      } ## end of if not null r2$data construct
      
    } ## end of while(more_pages) loop
  } ## end of if no null paging:next

  result$data = NULL
  result$app_health = tmp_app_health
  return(result)
} ## end of get_page function


get_next_page = function(next_page = "", app_health=list()) {
  cat("Running get_next_page\n")
  tmp_data = data.frame()
  
  ## user agent field
  ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36"
  
  ## use next_page as the url with parameters
  url = next_page

  ## determine the delay on the basis of the max usage
  ## percentage take from app_health list
  ## case_when exits with a value as soon as a case is matched
  delay = 0.5 ## default value
  if (length(app_health)  == 3) {
    max_usage = max(sapply(app_health, '[', 1))
    delay = get_delay_value(max_usage) 
  } ## end of if(length(app_health) == 3) structure
  
  ## submit the request
  Sys.sleep(delay)
  s = NULL; w = NULL;
  
  tries_left = 7
  while(tries_left > 0) {
    s = GET(url, add_headers("User-agent"=ua, 'Accept'='text/json',
                             "Cache-control"='no-cache'))
    
    if (status_code(s) == 200) {
      tries_left = -1 ## change the value so the loop is not repeated
    } else {
      ## print out the status message and then go to sleep for 30 seconds
      s_message = httr::content(s, as="text")
      try({ cat("Status code is", status_code(s))
            print(s_message)
            w = fromJSON(s_message)
            print(paste("Received status code", status_code(s)))
            print(w)
            print("Sleeping for 30 seconds")
      }, silent=FALSE)
      Sys.sleep(30) ##
      tries_left = tries_left - 1
    } ## end of the if(status_code(s) == 200)
    
    if (tries_left == 1) {
      dbDisconnect(DB_CONNECTOR)
      stop("Persistent API error")
    }
  } ## end of the while(tries_left > 0)
  
  ## retrieve JSON content
  w = httr::content(s, as="text")
  ## convert to list
  r = list()
  try( { 
    r = fromJSON(w, simplifyDataFrame = F, flatten=F)
    print("got fromJSON data")
  }, 
  silent=FALSE)
  
  ## retrieve the X-App-Usage field from the header
  ## recently it became 'x-business-use-case-usage'
  tmp_app_health = app_health
  try( {
    print(headers(s)$`x-business-use-case-usage`)
    tmp_business_usage = fromJSON(headers(s)$`x-business-use-case-usage`)[[1]]
    tmp_app_health = list(object_count_pct = tmp_business_usage[1, "call_count"], 
      ## object_count_pct=tmp_business_usage[1, "object_count_pct"],
                          total_cputime = tmp_business_usage[1, "total_cputime"],
                          total_time = tmp_business_usage[1, "total_time"])
    print("got fromJSON app usage")
  },
  silent=FALSE)
  
  ## if some data was returned
  if (!is.null(r$data) & length(r$data) > 0) {
    tmp_data = get_info(r$data)
  } ## end of if not null r$data construct
  
  if (!is.null(r$`paging`$`next`)) {
    cat("Paging information\n")
    print(r$`paging`$`next`)
    tmp_next_page = r$`paging`$`next`
  } else {
    tmp_next_page = ""
  }
  
  result = list(data = tmp_data, app_health = tmp_app_health,
                next_page = tmp_next_page)
  return(result)
} ## end of get_next_page function


## function to insert the data into ADS_TABLE
## argument x is a wide table
insert_data = function(x=data.frame(), is_active="") {
  if (nrow(x) == 0) { return() }
  
  ## retrieve the data element
  ## and add the search term column
  t_wide = x
  t_wide$query = QUERY
  
  ## generate hash values for rows
  h = character(nrow(t_wide))
  for (j in 1:nrow(t_wide)) {
    h[j] = digest(object=paste(as.vector(t_wide[j, ]), collapse=" "), 
                  algo="sha512", serialize=T)
  }
  t_wide$hash = h
  
  ## record the is_active status
  t_wide$is_active = is_active
  
  ## record the date
  t_wide$date = strftime(Sys.time(), "%Y-%m-%d %H:%M:%S")
  
  ## record the person
  t_wide$person = PERSON
  
  ## make a subset for the ADS_LOG table
  ## should include ad_id, page_id, page_name, is_active, query, person, date
  ## funding_entity
  # t_log = t_wide %>% 
  #   select(ad_id, page_id, page_name, funding_entity, 
  #          is_active, date, query, person)
  # dbWriteTable(conn=DB_CONNECTOR, name=ADS_LOG, value=t_log,
  #              row.names=F,
  #              overwrite=F,
  #              append=T)
  
  ## remove the records which are identical to previous ones
  if (nrow(QUERY_HASH) > 0) {
    t_wide = t_wide %>% anti_join(QUERY_HASH, by=c("id", "hash"))
  }
  
  if (nrow(t_wide) > 0) {
    dbWriteTable(conn=DB_CONNECTOR, name=ADS_TABLE, value=t_wide,
                 row.names=F,
                 overwrite=F,
                 append=T)
  }
  
} ## end of function insert_data

## download_hash_tables()
## function to download hash values of previously stored records
## uses global variables: 
## DB_CONNECTOR - database connector
## QUERY - currently executed query
## ADS_TABLE - name of table with ads
## QUERY_HASH - dataframe to store hash values of ads
download_hash_tables = function() {
  
  ## unmatched single quotation marks create problems
  ## encode into base64 and expand after
  b64_query = base64enc::base64encode(charToRaw(QUERY))
  
  q = paste("select id, hash from", 
            ADS_TABLE, 
            "where query = FROM_BASE64('zzz')")
  q = gsub("zzz", b64_query, q)
  
  ## note the use of <<- that's global assignment
  QUERY_HASH <<- dbGetQuery(DB_CONNECTOR, q)
  
}  

## get all ads from a page
## end_point is the endpoint URL
## token is the access token
## page_ids is the string with page ids
## usually it's only one page id, but it can be up to 10, separated by commas
## delay is the sleep interval in seconds
##
## function returns a data object, app usage object, and 
## paging_next URL if it was present
get_page_ads = function(query_url = "", 
                    token="", page_ids = "",
                    delay=3.0, 
                    ad_active_status = "ACTIVE",
                    app_health = list()) {
  
  ## cat("Call of get_page_ads. page ids are", page_ids, '\n')
  
  pages = list()
  num_page = 1
  result = list()
  tmp_data = data.frame()
  
  ## user agent field
  ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36"
  
  ## if there were no search terms and no page ids, exit with empty data
  if (nchar(page_ids) == 0) { 
    return(list(app_health = app_health, data=data.frame()))
  }
  
  ## modify the ad_active_status field
  ## and append search_terms and access_token fields
  url = param_set(query_url, key="ad_active_status", ad_active_status) %>% 
    param_set("access_token", token)
  
  ## determine the delay on the basis of the max usage
  ## percentage take from app_health list
  ## case_when exits with a value as soon as a case is matched
  if (length(app_health)  == 3) {
    max_usage = max(sapply(app_health, '[', 1))
    delay = get_delay_value(max_usage) 
  } ## end of if(length(app_health) == 3) structure
  
  ## submit the request
  Sys.sleep(delay)
  s = NULL; w = NULL;
  
  tries_left = 7
  while(tries_left > 0) {
    s = GET(url, add_headers("User-agent"=ua, 'Accept'='text/json',
                             "Cache-control"='no-cache'))
    
    if (status_code(s) == 200) {
      tries_left = -1 ## change the value so the loop is not repeated
    } else {
      ## print out the status message and then go to sleep for 30 seconds
      s_message = httr::content(s, as="text")
      try({ w = fromJSON(s_message)
      
      if (w$error$error_user_title == 'Invalid Page ID') {
        cat("Inside the if chunk for Invalid Page Id", '\n')
        
        separate_page_ids = unlist(strsplit(page_ids, ','))
        
        for (page_id in separate_page_ids) {
          cat("Inside the for loop for invalid page id", page_id, '\n')
          tmp_app_health = app_health
          
          t = get_single_page_ads(query_url = query_url,
                           token=token, 
                           page_id = page_id,
                           delay=3, 
                           ad_active_status = ad_active_status, 
                           app_health = tmp_app_health)
          
          tmp_app_health = t$app_health
        }
        
        result$data = NULL
        result$app_health = tmp_app_health
        return(result)
        
      }
      
      print(paste("Received status code", status_code(s)))
      print(w)
      print("Sleeping for 30 seconds")
      }, silent=FALSE)
      Sys.sleep(30) ##
      tries_left = tries_left - 1
    } ## end of the if(status_code(s) == 200)
    
    if (tries_left == 1) {
      dbDisconnect(DB_CONNECTOR)
      stop("Persistent API error")
    } ## end of the if (tries_left == 1) clause
  } ## end of the while(tries_left > 0)
  
  ## retrieve JSON content
  w = httr::content(s, as="text")
  
  ## convert to list
  r = list()
  try( { 
    r = fromJSON(w, simplifyDataFrame = F, flatten = F)
    print("got fromJSON data")
  }, 
  silent=FALSE)
  
  ## retrieve the X-App-Usage field from the header
  ## recently it became 'x-business-use-case-usage'
  tmp_app_health = app_health
  try( {
    print(headers(s)$`x-business-use-case-usage`)
    tmp_business_usage = fromJSON(headers(s)$`x-business-use-case-usage`)[[1]]
    tmp_app_health = list(object_count_pct = tmp_business_usage[1, "call_count"], 
      ## object_count_pct=tmp_business_usage[1, "object_count_pct"],
                          total_cputime = tmp_business_usage[1, "total_cputime"],
                          total_time = tmp_business_usage[1, "total_time"])
    print("got fromJSON app usage")
  },
  silent=FALSE)
  
  ## if some data was returned
  if (!is.null(r$data) & length(r$data) > 0) {
    tmp_data = get_info(r$data)
    insert_data(tmp_data, ad_active_status)
  } ## end of if not null r$data construct
  
  ## if paging:next is present, iterate
  if (!is.null(r$`paging`$`next`)) {
    more_pages = T
    
    r2 = list(app_health = tmp_app_health, data=NULL,
              next_page = r$`paging`$`next`)
    
    while(more_pages) {
      r2 = get_next_page(next_page = r2$next_page, 
                         app_health = r2$app_health)
      if (r2$next_page == "") {
        more_pages = F
        tmp_app_health = r2$app_health
      }
      
      ## the get_next_page returns a dataframe
      ## in the element data?
      ## no need to perform
      if (!is.null(r2$data) & nrow(r2$data) > 0) {
        tmp_data = r2$data
        insert_data(tmp_data, ad_active_status) ## this part is new
      } ## end of if not null r2$data construct
      
    } ## end of while(more_pages) loop
  } ## end of if no null paging:next
  
  result$data = NULL
  result$app_health = tmp_app_health
  return(result)
} ## end of get_page_ads function


get_single_page_ads = function(query_url = "", 
                        token="", page_id = "",
                        delay=3.0, 
                        ad_active_status = "ACTIVE",
                        app_health = list()) {
  
  cat("Call of get_single_page_ads. page id is", page_id, '\n')
  
  pages = list()
  num_page = 1
  result = list()
  tmp_data = data.frame()
  
  ## user agent field
  ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36"
  
  ## if there were no search terms and no page ids, exit with empty data
  if (nchar(page_id) == 0) { 
    return(list(app_health = app_health, data=data.frame()))
  }
  
  ## modify the ad_active_status field
  ## and append search_terms and access_token fields
  url = param_set(query_url, key="ad_active_status", ad_active_status) %>% 
    param_set("access_token", token) %>% 
    param_set("search_page_ids", page_id)
  
  ## determine the delay on the basis of the max usage
  ## percentage take from app_health list
  ## case_when exits with a value as soon as a case is matched
  if (length(app_health)  == 3) {
    max_usage = max(sapply(app_health, '[', 1))
    delay = get_delay_value(max_usage)
  } ## end of if(length(app_health) == 3) structure
  
  ## submit the request
  Sys.sleep(delay)
  s = NULL; w = NULL;
  
  tries_left = 7
  while(tries_left > 0) {
    s = GET(url, add_headers("User-agent"=ua, 'Accept'='text/json',
                             "Cache-control"='no-cache'))
    
    if (status_code(s) == 200) {
      tries_left = -1 ## change the value so the loop is not repeated
    } else {
      ## print out the status message and then go to sleep for 30 seconds
      
      s_message = httr::content(s, as="text")
      try({ w = fromJSON(s_message) 
      
      
      if (w$error$error_user_title == 'Invalid Page ID') {

        cat("Page", page_id, "triggers invalid page id error", '\n')
        
        result$data = NULL
        result$app_health = app_health
        return(result)
      }
      
      print(paste("Received status code", status_code(s)))
      print(w)
      print("Sleeping for 30 seconds")
      }, silent=FALSE)
      Sys.sleep(30) ##
      tries_left = tries_left - 1
    } ## end of the if(status_code(s) == 200)
    
    if (tries_left == 1) {
      dbDisconnect(DB_CONNECTOR)
      stop("Persistent API error")
    } ## end of the if (tries_left == 1) clause
  } ## end of the while(tries_left > 0)
  
  ## retrieve JSON content
  w = httr::content(s, as="text")
  
  ## convert to list
  r = list()
  try( { 
    r = fromJSON(w, simplifyDataFrame = F, flatten = F)
    print("got fromJSON data")
  }, 
  silent=FALSE)
  
  ## retrieve the X-App-Usage field from the header
  ## recently it became 'x-business-use-case-usage'
  tmp_app_health = app_health
  try( {
    print(headers(s)$`x-business-use-case-usage`)
    tmp_business_usage = fromJSON(headers(s)$`x-business-use-case-usage`)[[1]]
    tmp_app_health = list(object_count_pct = tmp_business_usage[1, "call_count"], 
      ## object_count_pct=tmp_business_usage[1, "object_count_pct"],
                          total_cputime = tmp_business_usage[1, "total_cputime"],
                          total_time = tmp_business_usage[1, "total_time"])
    print("got fromJSON app usage")
  },
  silent=FALSE)
  
  ## if some data was returned
  if (!is.null(r$data) & length(r$data) > 0) {
    tmp_data = get_info(r$data)
    insert_data(tmp_data, ad_active_status)
  } ## end of if not null r$data construct
  
  ## if paging:next is present, iterate
  if (!is.null(r$`paging`$`next`)) {
    more_pages = T
    
    r2 = list(app_health = tmp_app_health, data=NULL,
              next_page = r$`paging`$`next`)
    
    while(more_pages) {
      r2 = get_next_page(next_page = r2$next_page, 
                         app_health = r2$app_health)
      if (r2$next_page == "") {
        more_pages = F
        tmp_app_health = r2$app_health
      }
      
      ## the get_next_page returns a dataframe
      ## in the element data?
      ## no need to perform
      if (!is.null(r2$data) & nrow(r2$data) > 0) {
        tmp_data = r2$data
        insert_data(tmp_data, ad_active_status) ## this part is new
      } ## end of if not null r2$data construct
      
    } ## end of while(more_pages) loop
  } ## end of if no null paging:next
  
  result$data = NULL
  result$app_health = tmp_app_health
  return(result)
} ## end of get_page_ads function





