# CREATIVE --- fb_ad_import

Welcome! The purpose of this repo is to import Facebook political ads.

This repo is part of the [Cross-platform Election Advertising Transparency Initiative (CREATIVE)](https://www.creativewmp.com/). CREATIVE has the goal of providing the public with analysis tools for more transparency of political ads across online platforms. In particular, CREATIVE provides cross-platform integration and standardization of political ads collected from Google and Facebook. CREATIVE is a joint project of the [Wesleyan Media Project (WMP)](https://mediaproject.wesleyan.edu/) and the [privacy-tech-lab](https://privacytechlab.org/) at [Wesleyan University](https://www.wesleyan.edu).

To analyze the different dimensions of political ad transparency we have developed an analysis pipeline. The scripts in this repo are part of the Data Collection step in our pipeline.

![A picture of the repo pipeline with this repo highlighted](Creative_Pipelines.png)

## Table of Contents

- [1. Introduction](#1-introduction)

  - [A word of caution](#a-word-of-caution)
  - [Access authorization](#access-authorization)
  - [Keyword search and backpull](#keyword-search-and-backpull)
  - [API utilization and request slowdown](#api-utilization-and-request-slowdown)
  - [Exclusion of duplicate records](#exclusion-of-duplicate-records)
  - [Retries on API errors](#retries-on-api-errors)
  - [Management of the queue of requests](#management-of-the-queue-of-requests)

- [2. Data](#2-data)

  - [What can you do with this data?](#what-can-you-do-with-this-data)

- [3. Setup](#3-setup)

  - [Access Token](#access-token)
  - [R packages](#r-packages)
  - [SQL backend](#sql-backend)
  - [Running the scripts](#running-the-scripts)

- [4. Thank You](#4-thank-you)

## 1. Introduction

The purpose of this repository is to provide scripts for importing Facebook political ads. The following content in this section highlights the unique features of our scripts in handling the large volume of data compared with the official R package `Radlibrary`.

### A word of caution

If you are looking for a way to import a small collection of ads from the Facebook Ad Library API ("the API"),, you are better off with the official R package `Radlibrary` released by the Facebook Research group in 2019: [https://github.com/facebookresearch/Radlibrary](https://github.com/facebookresearch/Radlibrary).

It is written in R and does not require any databases. For a vignette, please see [Facebook's `Radlibrary` page](https://facebookresearch.github.io/Radlibrary/articles/Radlibrary.html).

As far as we know, the biggest functional difference between our scripts and the official package is the handling of the API utilization information to make sure that the scripts do not exceed the limits set by the API. Without this feature, the scripts are bound to hit the usage limits when the amount of imported data is large. When that happens, access to the API is revoked for several hours.

Our scripts also implement an additional feature related to data management: exclusion of duplicate records at the time when the data is inserted into the database. This is done to save disk space.

If you are not interested in the background covering the authorization and the data, please proceed to the [Setup](#4-setup) section at the end of this document.

### Access authorization

The API requires that each query must include an access token. This token is obtained from the Facebook Graph API Explorer page [https://developers.facebook.com/tools/explorer/](https://developers.facebook.com/tools/explorer/). Initially, tokens are valid for 60 minutes, but they can be extended using a Token Debugger. An extended-life token can be used for 60 days. If you want to run the scripts in this repo, it is essential to obtain an extended token. Without extending the token, the script will stop collecting data after 60 minutes since the token would expire and the API would reject the calls. However, since our keyword search script takes about 2 hours to complete, the script would break without the extended token, resulting in only partial data collection.

In order to be eligible to run the API, Facebook requires that a user must validate their identity and that is a rigorous process. It is equivalent to being approved to run political ads on Facebook. The process involves validating the physical address in the United States (it used to be that Facebook would send a physical letter to the address) and validating the identity, which requires submitting a personal ID (for instance, a state-issued driver's license). After that the user must register as a developer on the platform and create an app. If you want to use our script to replicate the ads collection, you must also go through this process to obtain the access token.

The scripts import the token from a file named `tokens.txt`, but we are not providing the file in this repository. The token is also used in the FB ad scraper: <https://github.com/Wesleyan-Media-Project/fb_ad_scraper>

### Keyword search and backpull

For a full documentation on the API, please see the [official documentation page](https://www.facebook.com/ads/library/api).

The API supports two types of queries: the keyword search and the retrieval of ads by their page ids. In the latter case, the user can provide up to ten page ids, and the API will return the ads that were launched from these pages.

Compared to Google, Facebook does not provide the Federal Electoral Commission's id number or the Individual Taxpayer Number linked to the advertiser page. As a result, there is no centralized list that would specify which page belongs to which political candidate. Instead, researchers have to discover the pages through their own efforts.

We use two scripts, available here in this repo, to identify and retrieve all ads that could be related to political and social-issue advertising on Facebook:

- `race2022.R` - a script that uses a keyword search endpoint to find ads, and
- `backpull2022.R` - a script that uses a page_id endpoint to retrieve all ads posted from the pages discovered by `race2022.R`

  <img width="1169" alt="diagram of the scripts and database tables used to import and store Facebook ads" src="https://github.com/Wesleyan-Media-Project/fb_ads_import/assets/17502191/079eeab3-cd2b-4ff5-a286-79f4c04c9053">

Our database (its name is `dbase1`) contains a table with the names of political candidates --- in the 2022 election cycle, this table was named `senate2022` --- and the keywords that are used to find these candidates. The keywords in the table are our educated guesses as to how the candidates are referred to, or described, in political ads. For instance, if there is a candidate `Taylor Swift` (first name is Taylor, last name is Swift) running for the 27th Congressional district in Florida, then we expect to see phrases like "Swift for Congress", "Swift for FL-27", or simply the name of the candidate "Taylor Swift". (As a side note, some of the past candidates' last names are common words, like "House" or "Post", which resulted in a lot of false positive matches.)

The `race2022.R` script retrieves the contents of the `senate2022` table and then submits a separate request for each keyword. It then identifies which ad records are new and inserts them into the table `race2022` in the database.

As a next step, the `backpull2022.R` script constructs a list of page ids from the ads imported into `race2022`. It splits the list into strings containing at most 10 page ids each --- the upper limit on the number of page ids that can be submitted to the Ad API. It then iterates through these strings and submits the queries to the page_id endpoint of the API. The new ad records are inserted into the same database. This way we collect the ads containing keywords and all other ads that were posted by the same pages. This is done to make sure we do not miss any advertising activity.

The scripts write columns `keyword` and `person` into the table. For the keyword-search script, these columns contain the actual keyword and person linked to the keyword. For the `backpull2022.R` script, these columns contain the list of page ids. The page ids are entirely numerical and this allows us to identify, post-hoc, why each of the ad records was imported into our system.

### API utilization and request slowdown

Requests to the API are subject to rate limits. The app owned by the Wesleyan Media Project has been categorized as a "business use case" (BUC) and is subject to the BUC limits described on this page: <https://developers.facebook.com/docs/graph-api/overview/rate-limiting/>. The rate limits may be different for other types of users, you can check the unitilization record described below to see the keep track of your utilization record.

Below is an example of the utilization record. This record is included into the header of the request returned by the server. The name of the header field is `X-Business-Use-Case-Usage`. The BUC number of the app has been replaced with `xxxx`.

```
{"xxxx":
  [{"type":"ads_archive",
  "call_count":3,
  "total_cputime":1,
  "total_time":37,
  "estimated_time_to_regain_access":0}]}
```

If a user reaches 100 percent in any of the categories --- call count, total cpu time, or total time, --- then their access is suspended for as long as 24 hours.

To avoid such situations, our scripts introduce a delay between requests. The delay increases as the utilization percentage goes up. When utilization is under 75%, the delay is 3 seconds. When it reaches 95% or higher, the delay is 90 seconds.

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

### Exclusion of duplicate records

Most of the fields in an ad record get their values at the time the ad is created and do not change between API requests: page id, funding byline, ad creative text, ad links, ad delivery start time, and so on. There are also several fields that get updated and reflect the performance of an ad: the `spend` and `impressions` fields report the ranges of the spend and impressions, respectively. The demographic distribution and regional distribution fields report the percentages of ad views across groupings of users by demographic characteristics (age, sex) or their state of residence.

To save disk space in the database, the scripts will insert an ad record only if the ad is entirely new or the if the ad is already in the database but its record has changed. That means that any of the non-permanent fields --- spend, impressions, distributions --- have changed.

In order to compare the records, the scripts generate a hash string for each row in the `race2022` table and store it in the database. During the import, the scripts retrieve the hash strings of "old" records and compare the strings against the hashes of the "fresh" records that just arrived from the API. If the hash strings match, the scripts "skip" the record and do not insert it into the database.

Usually, hash libraries would generate a string for a single object: a number or a text string. However, R is unique in that it has a package `digest` that can generate hash values from a whole object, be it a vector, a list, or a row of a dataframe. The scripts rely on this package.

### Retries on API errors

Occasionally, the API will return an error. The error can be caused by problems with authentication (e.g., the access token has expired) or usage limits (e.g., despite the slowdown, the script has hit the 100% utilization and has been cut off). It can also mean that the amount of data served in a single page of results is too large and the server issues a 500 error code.

When the error occurs, the script tries to repeat the request: it waits 30 seconds and then resubmits the request. If, after seven attempts, the error did not go away, the script terminates.

Termination is important because, if the error was caused by exceeding the usage limits, hitting the endpoint with more requests will aggravate the situation and will prolong the "cool off" period when the API will block requests from our access token.

### Management of the queue of requests

The two scripts --- `race2022.R` and `backpull2022.R` --- operate under different assumptions regarding the data input. The keyword-search script `race2022.R` imports a list of keywords and goes through it "in a single sitting." The script does have the capability to start from a user-specified row in the list. To do so, the user needs to provide `--args resume=N` string in the command line invoking the script, where `N` is the row number.

This functionality was put in place because in 2020 there often would be a situation that the script would "choke" on a particular keyword. This would happen because the amount of data returned by the API would cause errors (e.g., the code 500) errors. There were also situations where a script would go into an infinite loop - the server would lose track the pages of data and would serve the same URL in the `next` field over and over. (Both problems occurred when searching for ads that would have keyword `Trump` in them.) Because we know the ordering of the keywords, the `resume=N` option allowed us to skip the problematic request and instead continue with the keywords immediately after. This way we could salvage the remaining hours in a day by collecting some data and hoping that the problems with the difficult keyword will go away (as they eventually did).

The `backpull2022.R` script is designed to operate only a few hours a day. It is impossible to perform the "back-pull" for all pages in the list, and the script uses a table (its name is `page_queue`) where it records the last time specific collection of page-ids was queried. At launch time, the script retrieves the list sorted in chronological order, with oldest timestamps coming first.

Both scripts are launched daily. We leave several idle hours to "cool off" the utilization metrics. The keyword-search script is launched at 8 am and runs first, until completion. Then, the backpull script is launched afterwards and runs until 3 am. The period between 3 am and 8 am is the "quiet time". We do know from experience that it is counter-productive to have the two scripts run in parallel because they consume the same rate limits.

We have included the bash file `race_2022.sh` that is launched via crontab to run the scripts. We recommand that you use the same approach to run the ads collection. In this way, data will be collected on a daily basis without involvement from a user. You can also use RStudio to execute the ads collection scripts, but RStudio does not support scheduled invocations. A user would have to launch the script manually every day and that can be tedious, or impossible.

## 2. Data

The data gathered by the scripts is stored in a MySQL database.
The script expects you to have a database named `dbase1` and a table named `race2022` in it. The table `race2022` is created by the script `table_setup.sql` in this repo. column names in table `race2022` reflect the ad record fields as they are available in the API version 17.0 (the documentation is [here](https://developers.facebook.com/docs/graph-api/reference/archived-ad/)). For more information on the database and tables, please see the [SQL backend](#sql-backend) section below.

### What can you do with this data?

We believe that the data collected by the scripts can be used as a basis for political ads research. It has the potential to be used in research, database creation, monitoring, and other applications.

## 3. Setup

### Access Token

In order to use the scripts you MUST have the access token from the [Facebook Graph API Explorer tool](https://developers.facebook.com/tools/explorer). Without the token, the code will not work --- you will receive API errors. The token must be saved in a file named `tokens.txt` and it must be in the working directory used by the script.

### R packages

The scripts are written in R.

First, make sure you have R installed. While R can be run from the terminal, many people find it easier to use RStudio along with R. Here is a [tutorial for setting up R and RStudio](https://rstudio-education.github.io/hopr/starting.html).

Then, make sure that you have the following packages installed in the R instance you are using:

- dplyr
- httr
- jsonlite
- RMySQL
- tidyr
- readr
- base64enc
- digest
- urltools

You can install them with a single command in R:

```{R}
install.packages(c("dplyr", "httr", "jsonlite", "RMySQL", "tidyr", "readr", "base64enc", "digest", "urltools"))
```

Depending on what machine and operating system you are using, package `RMySQL` may require installation of system level utilities or libraries. Make sure to read the diagnostic messages, as they will contain additional instructions. This process will take a minute. When using the given command line in R, you will be prompted with this question: Would you like to use a personal library instead? (yes/No/cancel). Enter yes.

In order to execute an R script you can run the following command from your terminal from within the directory of the script replacing `file.R` with the file name of the script you want to run:

```bash
Rscript file.R
```

### SQL backend

The scripts will store data in an instance of MySQL (or MariaDB) that needs to be installed and running on your machine. In order to run the scripts, you will need to create the tables in a database in MySQL/MariaDB and enter some keyword values.

The required commands for the MySQL/MariaDB backend are provided in the file `table_setup.sql` in this repo. Several points are worth special attention:

- the script expects to have a database named `dbase1`. You can change this to your liking, but if you do, please also update the R scripts - they use this database name to connect to the database server.
- column names in table `race2022` reflect the ad record fields as they are available in the API version 17.0 (the documentation is [here](https://developers.facebook.com/docs/graph-api/reference/archived-ad/)). This is the latest API version at the time this repo is prepared and our hope is that this version will remain valid for several years. The scripts have a variable `INGESTED_FIELDS` that contains the column names. These must match the names of columns in the tables and in the API.

This statement in the script inserts the phrases that will be used to search the ads via keywords. Essentially, they represent the "seed" records:

```{sql}
INSERT INTO senate2022
(name, state, party, term, in_the_race)
VALUES
("Fetterman, John", "PA", "DEM", "Fetterman Senate", "yes"),
("Fetterman, John", "PA", "DEM", "John Fetterman", "yes"),
("Vance, J.D.", "OH", "GOP", "Vance Senate", "yes"),
("Vance, J.D.", "OH", "GOP", "JD Vance", "yes");
```

As you can see, the keywords are related to John Fetterman and JD Vance. In a real application, this is the part of the script that you would modify to suit your needs. When a candidate drops out of a race, we would update the `in_the_race` column so it would no longer contain "yes". That way, we can keep track of all keywords and search terms, but don't have to spend the FB API requests on candidates who are no longer active.

Check out `table_setup.sql` to learn more about how to setup tables and use databases.

### Running the scripts

We use command-line method of running R. The following code block illustrates how to run the scripts as background processes in a Linux-like operating system. The `nohup` command instructs the operating system that the process should not be terminated ("no hung up - nohup") when the user terminal is closed. The ampersand `&` at the end of the line instructs the operating system to run the process in the background.

The `R CMD BATCH` is the actual command that runs R in command-line mode. The `./Logs/backpull_log_$(date +%Y-%m-%d).txt` string will be evaluated by the operating system and will generate a filename containing the date in it. The `$(date +%Y-%m-%d)` will insert the current date in the format `YYYY-mm-dd`. Thus, the log file will have a date in its name and will not overwrite log files from previous days. These command lines can be found in `race_2022.sh`, as well.

```{bash}
nohup R CMD BATCH --no-save --no-restore '--args resume=1' race2022.R  ./Logs/race_log_$(date +%Y-%m-%d).txt &
```

```{bash}
nohup R CMD BATCH --no-save --no-restore backpull2022.R  ./Logs/backpull_log_$(date +%Y-%m-%d).txt &
```

## 4. Thank You

<p align="center"><strong>We would like to thank our supporters!</strong></p><br>

<p align="center">This material is based upon work supported by the National Science Foundation under Grant Numbers 2235006, 2235007, and 2235008.</p>

<p align="center" style="display: flex; justify-content: center; align-items: center;">
  <a href="https://www.nsf.gov/awardsearch/showAward?AWD_ID=2235006">
    <img class="img-fluid" src="nsf.png" height="150px" alt="National Science Foundation Logo">
  </a>
</p>

<p align="center">The Cross-Platform Election Advertising Transparency Initiative (CREATIVE) is a joint infrastructure project of the Wesleyan Media Project and privacy-tech-lab at Wesleyan University in Connecticut.

<p align="center" style="display: flex; justify-content: center; align-items: center;">
  <a href="https://www.creativewmp.com/">
    <img class="img-fluid" src="CREATIVE_logo.png"  width="220px" alt="CREATIVE Logo">
  </a>
</p>

<p align="center" style="display: flex; justify-content: center; align-items: center;">
  <a href="https://mediaproject.wesleyan.edu/">
    <img src="wmp-logo.png" width="218px" height="100px" alt="Wesleyan Media Project logo">
  </a>
</p>

<p align="center" style="display: flex; justify-content: center; align-items: center;">
  <a href="https://privacytechlab.org/" style="margin-right: 20px;">
    <img src="./plt_logo.png" width="200px" alt="privacy-tech-lab logo">
  </a>
</p>
