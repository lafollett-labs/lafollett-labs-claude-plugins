### Fixed
- **sdlc**: `review` PEs stop talking real bugs out of the report. A suspected bug
  is demoted to a non-gating receipt only after the PE runs the code on the input
  that should trigger it. Agent output and other model-written data count as
  untrusted input. The lifecycle move covers every invocation mode and history
  rewrites, and passing suites no longer end the review.
