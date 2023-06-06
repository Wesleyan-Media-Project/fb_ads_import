#!/bin/bash

cd /data/1/wesmediafowler/projects/FB
R CMD BATCH --no-save --no-restore '--args resume=1' race2022.R ./Logs/race22_log_$(date +%Y-%m-%d).txt 
R CMD BATCH --no-save --no-restore backpull2022.R  ./Logs/backpull_log_$(date +%Y-%m-%d).txt 
