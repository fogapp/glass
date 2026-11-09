# syntax=docker/dockerfile:1
# One image serves web, worker, and the release (migration) phase — fog runs
# them as different commands against the same image.

# ---- Stage 1: build the console SPA -----------------------------------------
FROM node:24-slim AS console_build
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json ./frontend/
RUN cd frontend && npm ci
COPY frontend ./frontend
RUN cd frontend && npm run build

# ---- Stage 2: base runtime ---------------------------------------------------
FROM ruby:3.4.2-slim AS base
WORKDIR /rails

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development

# zstd unpacks the file components of older fog-backup/1 artifacts on restore
# (tar --zstd); fog-backup/2 writes them as plain tars.
#
# postgresql-client comes from PGDG, not Debian's default package: bookworm's
# "postgresql-client" pulls v15, but the fleet standard is Postgres 18
# (fog's managed cluster, internal/pg/pg.go).
# A pg_dump older than the server it's dumping refuses to run at all, which
# silently aborts every pre-update backup (FogBackup::Producer) and the
# update along with it. Bump the pin when the fleet moves majors.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl ca-certificates && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
    echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main' > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libjemalloc2 postgresql-client-18 zstd && \
    rm -rf /var/lib/apt/lists/*

# ---- Stage 3: gems -----------------------------------------------------------
FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config libyaml-dev && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
# Path gems must exist when bundle install resolves the Gemfile: the
# vendored flare gem, and Glass's own agent (clients/ruby — Glass observes
# itself with the same gem every other app vendors). COPY the directories
# themselves, not a glob: `COPY vendor/* ./vendor/` flattens each
# subdirectory's contents.
COPY vendor ./vendor
COPY clients/ruby ./clients/ruby
RUN bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .
COPY --from=console_build /build/public /rails/public
RUN bundle exec bootsnap precompile app/ lib/

# fog stamps the commit via the GIT_REV build arg; GlassVersion falls back to
# this file when GIT_SHA isn't in env (surfaced at /api/v1/about).
ARG GIT_REV=unknown
RUN echo "${GIT_REV}" > /rails/REVISION

# ---- Stage 4: final ----------------------------------------------------------
FROM base
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Non-root; uid 1000 matches the `owner` on fog's managed volumes.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /rails/storage /rails/log /rails/tmp && \
    chown -R rails:rails /rails/log /rails/tmp /rails/storage
USER 1000:1000

EXPOSE 80
# The entrypoint is the restore-on-boot guard (fog-backup/2): a staged, armed
# artifact is restored before any process serves.
ENTRYPOINT ["./bin/docker-entrypoint"]
CMD ["./bin/thrust", "./bin/rails", "server"]
