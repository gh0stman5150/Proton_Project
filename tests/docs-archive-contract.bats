#!/usr/bin/env bats

@test "README keeps archive analysis conditional" {
  run grep -F 'If `/archive` is absent or empty, note that explicitly and proceed without archive comparison.' README.md
  [ "$status" -eq 0 ]
}

@test "copilot instructions keep archive analysis conditional" {
  run grep -F 'If `/archive` is absent or empty, say so explicitly and proceed without archive-based root-cause claims.' .github/copilot-instructions.md
  [ "$status" -eq 0 ]
}
