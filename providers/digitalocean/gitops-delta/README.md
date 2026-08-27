# Provider-wide gitops delta slot

The ONE sanctioned escape hatch of the provider layer (design §2 L2): a delta
that applies to ALL of this provider's templates and is genuinely
inexpressible through the provider contract (`P_*` symbols, capabilities).
Before this slot existed, such a delta had to be duplicated into every
capacity template.

Layout mirrors the template and environment layers:

    values/<namespace>/<release>.yaml   # slot 2 of the valuesFrom chain:
                                        #   common -> PROVIDER -> template -> environment
    patches/<kustomization>.yaml        # applied after distribution patches,
                                        #   before template and environment patches

Rules:
- Last resort. Frequent use is the signal to EXTEND THE CONTRACT instead.
- Loud by design: `make check` reports every non-empty delta slot, and a file
  here that binds to no HelmRelease / Kustomization is an error
  (check-values-files.sh + plan-time preconditions).
- DTK-authored: secrets are forbidden; files are templated with the non-secret
  override vars only, and any secret reference hard-fails at plan.
