library(testthat)
library(FeatureExtraction)
options(dbms = "oracle")
options(test = "spotChecks")
test_check("FeatureExtraction")
