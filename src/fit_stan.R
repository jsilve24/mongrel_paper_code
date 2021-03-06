require(rstan)
require(mongrel)
require(rlang)
require(stringr)
require(tidyr)
require(purrr)
require(driver)
source("src/fit_methods.R")
source("src/dataset_methods.R")
source("src/utils.R")


# Options for stan - recommended
options(mc.cores = parallel::detectCores())
rstan_options(auto_write = TRUE)



# main multinomial function ---------------------------------------------------

#' Fit multinomial model using stan
#' 
#' WARNING: Req that your current working directory is main folder
#'  "mongrel_paper_code"
#'  
#' WARNING: Currently uses a random seed... 
#' 
#' @param mdataset an mdataset object
#' @param chains number of chains to run
#' @param iter number of samples from each chain (note: includes warmup)
#' @param parameterization which parameterization to use 
#'   ("collapsed":default, "uncollapsed")
#' @param ret_stanfit should stanfit object be returned directly instead of 
#'   mfit object?
#' @param ret_all (if TRUE returns all parameters from stan call)
#' @param ... other parameters passed to function stan
#' @return mfit object (but returns stanfit if ret_stanfit==TRUE)
fit_mstan <- function(mdataset, chains=4, iter=2000, 
                      parameterization="collapsed", ret_stanfit=FALSE, ret_all=FALSE,  
                      ...){
  init <- list()
  for (i in 1:chains){
    init[[i]] <- list(eta=mongrel::random_mongrel_init(mdataset$Y))
    if (parameterization == "uncollapsed"){
      init[[i]]$Sigma = diag(mdataset$D-1)
    }
  }
  modcode <- switch(parameterization, 
                    "collapsed" = "src/rel_lm_collapsed.stan", 
                    "uncollapsed" = "src/rel_lm_uncollapsed.stan")

  if (ret_all){
    fit <- stan(modcode, data=mdataset, chains=chains, 
                init=init, iter=iter,  ...)
  } else {
    fit <- stan(modcode, data=mdataset, chains=chains, 
                init=init, iter=iter, pars=c("B", "Sigma", "eta"),  ...)  
  }

  if (ret_stanfit) return(fit)

  time_stan <- get_elapsed_time(fit)
  max_chain_warmup <- max(time_stan[,"warmup"])
  max_chain_sample <- max(time_stan[,"sample"])

  fit_summary <- summary(fit)
  fit_summary_s2 <- fit_summary$summary
  B_rows <- fit_summary_s2[grep("^B",rownames(fit_summary_s2)),]
  mean_n_eff <- mean(B_rows[,"n_eff"])

  pars <- rstan::extract(fit, c("B", "Sigma", "eta"))
  rm(fit) # free up memory

  # get Lambda MSE
  est_Lambda <- aperm(pars$B, c(2,3,1))
  lambda_RMSE <- get_Lambda_RMSE(mdataset$Lambda_true, est_Lambda)

  outside_percent <- get_95CI(mdataset$Lambda_true, est_Lambda)

  metadata <- metadata(max_chain_warmup, max_chain_sample, mean_n_eff, lambda_RMSE, outside_percent)

  m <- mfit(N=mdataset$N, D=mdataset$D, Q=mdataset$Q, iter=dim(pars$B)[1], 
            Lambda=est_Lambda, 
            Sigma=aperm(pars$Sigma, c(2,3,1)), 
            mdataset=mdataset,
            metadata=metadata)
  m$Eta <- aperm(pars$eta, c(2, 3, 1))
  return(m)
}

#' Fit multinomial model using stan variational inference
#' 
#' WARNING: Req that your current working directory is main folder
#'  "mongrel_paper_code"
#'  
#' WARNING: Currently uses a random seed... 
#' 
#' @param mdataset an mdataset object
#' @param chains number of chains to run
#' @param iter number of samples from each chain (note: includes warmup)
#' @param parameterization which parameterization to use 
#'   ("collapsed":default, "uncollapsed")
#' @param ret_stanfit should stanfit object be returned directly instead of 
#'   mfit object?
#' @param ret_all (if TRUE returns all parameters from stan call)
#' @param algorithm ("meanfield" : default) or "fullrank"
#' @param ... other parameters passed to function stan
#' @return mfit object (but returns stanfit if ret_stanfit==TRUE)
fit_mstan_vb <- function(mdataset, iter=2000, 
                         parameterization="collapsed", ret_stanfit=FALSE, ret_all=FALSE,
                         algorithm="meanfield",
                         ...){
  
  init<- list(eta=mongrel::random_mongrel_init(mdataset$Y))
  
  modcode <- switch(parameterization, 
                    "collapsed" = "src/rel_lm_collapsed.stan", 
                    "uncollapsed" = "src/rel_lm_uncollapsed.stan")
  m <- stan_model(modcode)

  start_time <- Sys.time()
  if (ret_all){
    fit <- vb(m, data=mdataset, 
              init=init, output_samples=iter, algorithm=algorithm, ...)
  } else {
    fit <- vb(m, data=mdataset, 
              init=init, output_samples=iter, pars=c("B", "Sigma", "eta"), algorithm=algorithm, ...)  
  }
  end_time <- Sys.time()

  if (ret_stanfit) return(fit)

  pars <- rstan::extract(fit, c("B", "Sigma", "eta"))
  est_Lambda <- aperm(pars$B, c(2,3,1))
  rm(fit) # free up memory

  total_runtime <- end_time - start_time

  lambda_RMSE <- get_Lambda_RMSE(mdataset$Lambda_true, est_Lambda)

  outside_percent <- get_95CI(mdataset$Lambda_true, est_Lambda)

  metadata <- metadata(0, total_runtime, dim(pars$B)[1], lambda_RMSE, outside_percent)
  
  m <- mfit(N=mdataset$N, D=mdataset$D, Q=mdataset$Q, iter=dim(pars$B)[1], 
            Lambda=est_Lambda, 
            Sigma=aperm(pars$Sigma, c(2,3,1)), 
            mdataset=mdataset,
            metadata=metadata)
  m$Eta <- aperm(pars$eta, c(2, 3, 1))
  return(m)
}


#' Fit multinomial model using stan MAP optimization and Laplace Approximation
#' 
#' WARNING: Req that your current working directory is main folder
#'  "mongrel_paper_code"
#'  
#' WARNING: Currently uses a random seed... 
#' 
#' @param mdataset an mdataset object
#' @param iter number of samples
#' @param parameterization which parameterization to use 
#'   ("collapsed":default, "uncollapsed")
#' @param ret_stanfit should stan output be returned instead
#' @param hessian (returns hessian if TRUE: default is FALSE for space)
#' @param ... other parameters passed to function stan
#' @return mfit object (but returns stan output if ret_stanfit==TRUE)
fit_mstan_optim <- function(mdataset, iter=2000, 
                      parameterization="collapsed", ret_stanfit=FALSE, 
                      hessian=FALSE, ...){
  
  init <- list()
  init[[1]] <- list(eta=mongrel::random_mongrel_init(mdataset$Y))
  
  modcode <- switch(parameterization, 
                    "collapsed" = "src/rel_lm_collapsed.stan", 
                    "uncollapsed" = "src/rel_lm_uncollapsed.stan")
  m <- rstan::stan_model(file=modcode)
  fit <- optimizing(m, data=mdataset, init=init[[1]], draws=iter, 
                    hessian=hessian, as_vector=FALSE)
  pars <- clean_optimizing(fit$theta_tilde)
  fit$theta_tilde <- pars
  
  if (ret_stanfit) return(fit)
  pars <- pars[c("B", "Sigma", "eta")]
  
  m <- mfit(N=mdataset$N, D=mdataset$D, Q=mdataset$Q, iter=dim(pars$B)[1], 
            Lambda=aperm(pars$B, c(2,3,1)), 
            Sigma=aperm(pars$Sigma, c(2,3,1)), 
            mdataset=mdataset)
  m$Eta <- aperm(pars$eta, c(2, 3, 1))
  if (hessian) m$hessian <- fit$hessian
  return(m)
}


#' Clean Output of Stan Optimizing Samples
#'
#' @param optimfit result of call to rstan::optimizing
#' @param pars optional character vector of parameters to include
#'
#' @return list of arrays
#' @importFrom stringr str_count
#' @importFrom rlang syms
#' @importFrom dplyr matches select mutate separate
#' @importFrom tidyr gather 
#' @importFrom purrr map map2
#' @importFrom driver spread_array
#' @export
clean_optimizing <- function(draws, pars=NULL){
  cl <- draws %>%
    as.data.frame()
  if (!is.null(pars)) cl <- select(cl, dplyr::matches(paste0("^(",paste(pars, collapse = "|"), ")\\["), ignore.case=FALSE))
  cl <- cl %>%
    mutate(dim_1 = 1:n()) %>%
    tidyr::gather(par, val, -dim_1) %>%
    separate(par, c("parameter", "dimensions"), sep="\\[|\\]", extra="drop") %>%
    split(., .$parameter)
  dn <- map(cl, ~str_count(.x$dimensions[1], "\\,")+1) %>%
    map(~paste0("dim", 1:.x))
  cl <- cl %>%
    map2(dn, ~separate(.x, dimensions, .y, "\\,", convert=TRUE)) %>%
    map(~dplyr::select(.x, -parameter)) %>%
    map2(dn, ~spread_array(.x, val, !!!rlang::syms(c("dim_1", .y))))
  return(cl)
}


#' Add 1 dimension to array
#'
#' @param a array object
#' @param d dimension to add (<= length(dim(a))+1)
#'
#' @return
#' @export
#'
#' @examples
#' x <- matrix(1:6, 3, 2)
#' add_array_dim(a, 1)
add_array_dim <- function(a, d){
  dd <- dim(a)
  if (d > length(dd)+1) stop("d must be <= length(dim(a))+1")
  ad <- rep(NA, length(dd)+1)
  passed=FALSE
  for (i in 1:(length(dd)+1)) {
    if (i==d) { ad[i] <- 1; passed <- TRUE }
    else if (passed) { ad[i] <- dd[i-1] }
    else {ad[i] <- dd[i]}
  }
  array(a, dim=ad)
}

