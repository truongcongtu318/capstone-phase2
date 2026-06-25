locals {
  module_tags = merge(
    {
      Project   = "self-heal-platform"
      TaskForce = "tf-3"
      Team      = "cdo-1"
      Env       = "sandbox"
      ManagedBy = "terraform"
    },
    { Component = "bootstrap" }
  )
}
