# typed: false

# Run using bin/ci — the local mirror of the deploy gate. A push to main is a
# production deploy, so this must be green before pushing.

CI.run do
  # Cheapest check we have, and it catches the one class of bug every other
  # check misses: files that exist locally but were never committed.
  step "Build inputs: tracked", "bin/check-tracked"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  # A gate that silently skips is worse than no gate: a checkout without RBIs
  # or node_modules would report green while typecheck and the design guard
  # never ran. Fail with instructions instead.
  # Generated RBIs (sorbet/rbi/dsl) must match what the app would generate
  # now — a stale one lets Sorbet check against methods that no longer
  # exist, or miss ones that do. Tapioca boots the app in development and
  # reads column types from the database (the three dev databases: queue's
  # models go untyped without theirs), so prepare them first; on a fresh
  # checkout that creates them from the schema files. One worker: tapioca's
  # forked workers segfault in libpq's connect on macOS when launched under
  # bin/ci, and a single process is no slower at this size.
  step "Types: generated RBIs current", "bin/rails db:prepare && bin/tapioca dsl --verify --workers=1"

  step "Types: Sorbet",
    File.directory?("sorbet/rbi") ? "bundle exec srb tc" : "echo 'sorbet/rbi missing — run bin/tapioca gem' && false"

  step "Tests: RSpec", "bundle exec rspec --format progress"
  step "Tests: agent gem", "cd clients/ruby && BUNDLE_GEMFILE=../../Gemfile bundle exec rake"

  step "Frontend: install check",
    File.directory?("frontend/node_modules") ? "true" : "echo 'frontend/node_modules missing — run npm --prefix frontend ci' && false"
  # The Node client is its own project (clients/node), with no dependencies
  # of its own: Node runs its TypeScript as it is, and the console's
  # compiler checks its types.
  step "Tests: node client", %(node --test "clients/node/test/*.test.ts")
  step "Types: node client", "frontend/node_modules/.bin/tsc -p clients/node"
  # The Go client (clients/go) is its own module too. Without a Go toolchain
  # its conformance tests would never run, so that is a failure, not a skip.
  step "Tests: go client",
    "if ! command -v go >/dev/null; then echo 'go missing — install the Go toolchain (brew install go)'; false; " \
    "else cd clients/go && go vet ./... && go test ./...; fi"

  step "Frontend: lint", "npm --prefix frontend run lint"
  step "Frontend: typecheck + build", "npm --prefix frontend run build"
  step "Frontend: tests", "npm --prefix frontend test -- --run"
  step "Frontend: design guard", "bin/design-guard"
  step "Frontend: generated vocabularies current", "bin/check-types"
end
