### Added
- **sdlc**: `review` PEs apply seven review moves after their five passes: ripple, lifecycle,
  inputs, attack the guard, failure path, falsify the test and fact check. Each finding names
  its move, and each PE accounts for every move in `moves_coverage`. A PE that leaves it
  incomplete is re-dispatched once; a gap that remains is recorded in the review.
