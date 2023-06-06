# fb_ads_import

# Scripts used by the Wesleyan Media Project to import Facebook political ads

## A word of caution

If you are looking for a way to import a small collection of ads from the Facebook Ad Library API, you are better off with the official R package `Radlibrary` released by the Facebook Research group in 2019: [https://github.com/facebookresearch/Radlibrary](https://github.com/facebookresearch/Radlibrary). 

It is written in R and does not require any databases. For a vignette, please see this [page](https://facebookresearch.github.io/Radlibrary/articles/Radlibrary.html)

As far as we know, the biggest functional distinction between our scripts and the official package is the handling of the API utilization information to make sure that the scripts do not exceed the limits set by the API. Without this feature, the scripts are bound to hit the usage limits when the amount of imported data is large. When that happens, access to the API is revoked for several hours.

Our scripts also implement an additional feature related to data management: exclusion of duplicate records at the time when the data is inserted into the database. This is done to save disk space.

## Access authorization

The API requires that each query must include an access token. This token is obtained from the Facebook Graph API Explorer page [https://developers.facebook.com/tools/explorer/](https://developers.facebook.com/tools/explorer/). Initially, tokens are valid for 60 minutes, but they can be extended using a Token Debugger. An extended-life token can be used for 60 days.

In order to be eligible to run the API, Facebook requires that a user must validate their identity. This involves validating the physical address in the United States (it used to be that Facebook would send a physical letter to the address) and validating the identity, which requires submitting a personal ID (for instance, a state-issued driver's license). After that the user must register as a developer on the platform and create an app.

The scripts import the token from a file named `tokens.txt`, but we are not providing the file in this repository. The token is also used in the FB ad scraper: https://github.com/Wesleyan-Media-Project/fb_ad_scraper

## Keyword search and backpull

For a full documentation on the Facebook Ad Library API ("the API"), please see the documentation page at this [link](https://www.facebook.com/ads/library/api) 

The API supports two types of queries: the keyword search and the retrieval of ads by their page ids. In the latter case, the user can provide up to ten page ids, and the API will return the ads that were launched from these pages.

Compared to Google, Facebook does not provide the Federal Electoral Commission's id number or the Individual Taxpayer Number linked to the advertiser page. As a result, there is no centralized list that would specify which page belongs to which political candidate. Instead, researchers have to discover the pages through their own efforts.

WMP uses two scripts to identify and retrieve all ads that could be related to political and social-issue advertising on Facebook: 

* `race2022.R` - a script that uses keyword search endpoint to find ads, and
* `backpull2022.R` - a script that uses page_id endpoint to retrieve all ads posted from the pages discovered by `race2022.R`

<img width="1169" alt="diagram of the scripts and database tables used to import and store Facebook ads" src="https://github.com/Wesleyan-Media-Project/fb_ads_import/assets/17502191/079eeab3-cd2b-4ff5-a286-79f4c04c9053">

Our database (its name is `textsim_new`) contains a table with the names of political candidates - in the 2022 election cycle, this table was named `senate2022` - and the keywords that are used to find these candidates. The keywords in the table are our educated guesses as to how the candidates are referred to, or described, in political ads. For instance, if there is a candidate `Taylor Swift` (first name is Taylor, last name is Swift) running for the 27th Congressional district in Florida, then we expect to see phrases like "Swift for Congress", "Swift for FL-27", or simply the name of the candidate "Taylor Swift". (As a side note, some of the past candidates' last names are common words, like "House" or "Post", which resulted in a lot of false positive matches.) 

The `race2022.R` script retrieves the contents of the `senate2022` table and then submits a separate request for each keyword. It then identifies which ad records are new and inserts them into the table `race2022` in the database.

As a next step, the `backpull2022.R` script constructs a list page ids from the ads imported into `race2022`. It splits the list into strings containing at most 10 page ids each - the upper limit on the number of page ids that can be submitted to the Ad API. It then iterates through these strings and submits the queries to the page_id endpoint of the API. The new ad records are inserted into the same database. This way WMP collects the ads containing keywords and all other ads that were posted by the same pages. This is done to make sure we do not miss any advertising activity.

The scripts write columns `keyword` and `person` into the table. For the keyword-search script, these columns contain the actual keywrod and person linked to the keyword. For the backpull script, these columns contain the list of page ids. The page ids are entirely numerical and this allows us to identify, post hoc, why each of the ad records was imported into our system.


## API utilization and request slowdown

Requests to the API are subject to rate limits. The app owned by the Wesleyan Media Project has been categorized as a "business use case" (BUC) and is subject to the BUC limits described on this page: https://developers.facebook.com/docs/graph-api/overview/rate-limiting/

Below is an example of the utilization record. This record is included into the header of the request returned by the server. The name of the header field is `X-Business-Use-Case-Usage`. The BUC number of the app has been replaced with `xxxx`.

```
{"xxxx":
  [{"type":"ads_archive",
  "call_count":3,
  "total_cputime":1,
  "total_time":37,
  "estimated_time_to_regain_access":0}]}
```

If a user reaches 100 percent in any of the categories - call count, total cpu time, or total time, - then their access is suspended for as long as 24 hours.

To avoid such situations, our scripts introduce a delay between requests. The delay increases as the utilizaation percentage goes up. When utilization is under 75%, the delay is 3 seconds. When it reaches 95% or higher, the delay is 90 seconds - 1.5 minutes.

```
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
```

When the API returns records, it does so in pages. At the end of each page there is a `next` field that contains the URL of the next page of records. Submitting a request to this URL counts against the rate limits. Thus, it is entirely possible to submit only a single request and then run out of usage quotas.

## Exclusion of duplicate records

Most of the fields in the ad record are permanent and do not change between requests: page id, funding byline, ad creative text, ad links, ad delivery start time, and so on. There are also several fields that get updated and reflect the performance of an ad: the `spend` and `impressions` fields reprot the range of the spend and impressions, respectively. The demographic distribution and regional distribution fields report the percentages of ad views across groupins of users by demographic characteristic (age, sex) or their state of residence.

To save disk space in the database, the scripts will insert an ad record only if the ad is entirely new or the if the ad is already in the database but its record has changed. That means that any of the non-permanent fields - spend, impressions, distributions - have changed.

In order to compare the records, the scripts generate a hash string for each row in the `race2022` table and store it in the database. During the import, the scripts retrieve the hash strings of "old" records and compare the strings aginst the hashes of the "fresh" records that just arrived from the API. If the hash strings match, the scripts "skip" the record and do not insert it into the database.

Usually, hash libraries would generate a string for a single object: a number or a text string. However, R is unique in that it has a package `digest` that can generate hash values from a whole object, be it a vector, a list, or a row of a dataframe. The scripts rely on this package.

