# The google-apis-core client logs full HTTP request/response BODIES at DEBUG level via its
# own Google::Apis.logger. Our production log level is :debug, so a bulk Gmail crawl (the
# Google Groups ETL) would otherwise dump every fetched email body into the logs — enormous
# volume, and a real throughput drag. Cap the Google client's own logger at WARN so the rest
# of the app's :debug logging is untouched but API request/response bodies stay out of the log.
require 'google/apis'
Google::Apis.logger.level = Logger::WARN
