# Decisions

No resort needs a file here: the pipeline builds every resort unattended from its
sources. Add `<resort_id>.yaml` only to correct what the sources say about one
mountain (merge two names, exclude a way, join a gap the build would not, reject a
meeting point). The keys are documented at the top of
`powdermeet_pipeline/reconcile/decisions.py`.
