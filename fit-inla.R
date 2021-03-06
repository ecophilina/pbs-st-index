fit_inla2 <- function(d, response = "present", n_knots = 50,
                      family = "binomial", max_edge = c(20, 100),
                      kmeans = FALSE,
                      plot = FALSE, fit_model = TRUE,
                      extend = list(n = 8, offset = -0.1),
                      offset = c(5, 25), cutoff = 10,
                      include_depth = TRUE) {

  coords <- as.matrix(unique(d[, c("X", "Y")]))

  # use kmeans() to calculate centers:
  if (kmeans) {
    km <- stats::kmeans(x = coords, centers = n_knots)
    mesh <- INLA::inla.mesh.create(km$centers,
      extend = extend
    )
  } else {
    bnd <- INLA::inla.nonconvex.hull(coords)
    mesh <- INLA::inla.mesh.2d(
      offset = offset,
      boundary = bnd,
      max.edge = max_edge,
      cutoff = cutoff
    )
  }

  message("INLA max_edge = ", "c(", max_edge[[1]], ", ", max_edge[[2]], ")")
  if (plot) {
    graphics::plot(mesh, asp = 1)
    graphics::points(coords, col = "#FF000030")
  }

  spde <- INLA::inla.spde2.matern(mesh, alpha = 3 / 2)

  d$year <- d$year - min(d$year) + 1

  k <- max(d$year)
  dat <- data.frame(
    y = d[, response, drop = TRUE],
    time = d$year,
    xcoo = d$X,
    ycoo = d$Y
  )

  # make a design matrix where the first year is the intercept:
  years_lab <- paste0("Y", seq(1, k))
  dat[years_lab] <- 0
  dat[, years_lab[1]] <- 1
  for (j in seq_along(years_lab)) {
    dat[dat$time == j, years_lab[j]] <- 1
  }

  if (include_depth) {
    dat$depth <- d$depth_scaled
    dat$depth2 <- d$depth_scaled2
  }

  # construct index for ar1 model:
  iset <- INLA::inla.spde.make.index(
    "i2D",
    n.spde = mesh$n,
    n.group = k
  )

  # make the covariates:
  X.1 <- dat[, -c(1:4)]
  covar_names <- colnames(X.1)
  XX.list <- as.list(X.1)
  effect.list <- list()
  effect.list[[1]] <- c(iset)
  for (Z in seq_len(ncol(X.1)))
    effect.list[[Z + 1]] <- XX.list[[Z]]
  names(effect.list) <- c("1", covar_names)

  A <- INLA::inla.spde.make.A(
    mesh = mesh,
    loc = cbind(dat$xcoo, dat$ycoo),
    group = dat$time
  )
  A.list <- list()
  A.list[[1]] <- A
  for (Z in seq_len(ncol(X.1)))
    A.list[[Z + 1]] <- 1

  # make projection points stack:
  sdat <- INLA::inla.stack(
    tag = "stdata",
    data = list(y = dat$y),
    A = A.list,
    effects = effect.list
  )

  formula <- as.formula(paste(
    "y ~ -1 +",
    paste(covar_names, collapse = "+"),
    "+ f(i2D, model=spde, group = i2D.group,",
    "control.group = list(model = 'ar1'))"
  ))

  if (fit_model) {
    model <- INLA::inla(formula,
      family = family,
      data = INLA::inla.stack.data(sdat),
      control.predictor = list(
        compute = TRUE,
        A = INLA::inla.stack.A(sdat)
      ),
      control.fixed = list(
        mean = 0, prec = 1 / (5^2),
        mean.intercept = 0, prec.intercept = 1 / (20^2)
      ),
      control.compute = list(config = TRUE),
      verbose = TRUE,
      debug = FALSE,
      keep = FALSE
    )
  } else {
    model <- NA
  }

  list(
    model = model, mesh = mesh, spde = spde, data = dat,
    formula = formula, iset = iset
  )
}

predict_inla <- function(obj, pred_grid, samples = 100L,
                          include_depth = TRUE) {
  mesh <- obj$mesh
  model <- obj$model
  iset <- obj$iset

  inla.mcmc <- INLA::inla.posterior.sample(n = samples, model)

  # get indices of various effects:
  latent_names <- rownames(inla.mcmc[[1]]$latent)
  re_indx <- grep("^i2D", latent_names)
  yr_fe_indx <- grep("^Y[0-9]+$", latent_names)
  if (include_depth) {
    depth_fe_indx1 <- grep("^depth$", latent_names)
    depth_fe_indx2 <- grep("^depth2$", latent_names)
  }

  # read in locations and knots, form projection matrix
  grid_locs <- pred_grid[, c("X", "Y")]

  # projections will be stored as an array:
  projected_latent_grid <-
    array(0, dim = c(nrow(grid_locs), samples, length(yr_fe_indx)))

  proj_matrix <- INLA::inla.spde.make.A(mesh, loc = as.matrix(grid_locs))

  # loop over all years; do MCMC projections for that year
  for (yr in seq_along(yr_fe_indx)) {
    # random effects from this year:
    indx <- which(iset$i2D.group == yr)
    for (i in seq_len(samples)) {

      if (yr > 1) {
        year_diff <- inla.mcmc[[i]]$latent[yr_fe_indx[[yr]]]
      } else {
        year_diff <- 0
      }

      if (include_depth) {
        depth_effects <-
          pred_grid[, "depth_scaled"] * inla.mcmc[[i]]$latent[depth_fe_indx1] +
          pred_grid[, "depth_scaled2"] * inla.mcmc[[i]]$latent[depth_fe_indx2]
      } else {
        depth_effects <- 0
      }

      projected_latent_grid[, i, yr] <-
        as.numeric(proj_matrix %*% inla.mcmc[[i]]$latent[re_indx][indx]) +
        inla.mcmc[[i]]$latent[yr_fe_indx[[1]]] + # base year
        year_diff + # 0 for the base year, diff otherwise
        depth_effects
    }
  }

  projected_latent_grid
}
