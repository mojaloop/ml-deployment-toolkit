terraform {
  required_version = ">= 1.5"

  # Deliberately no required_providers: config-loader uses only the builtin
  # terraform provider (terraform_data), so init works fully offline and the
  # stack can never touch real infrastructure. Plan-only by contract — the
  # Makefile render target never applies it.
  backend "local" {}
}
