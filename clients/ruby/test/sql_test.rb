# frozen_string_literal: true

require_relative "test_helper"

class SqlTest < Minitest::Test
  TABLE = {
    # binds and literals
    %(SELECT "wants".* FROM "wants" WHERE "wants"."household_id" = $1 LIMIT $2) =>
      %(SELECT "wants".* FROM "wants" WHERE "wants"."household_id" = ? LIMIT ?),
    %(SELECT * FROM wants WHERE id = 42 AND title = 'The ''Best'' One' AND ratio > 0.75) =>
      %(SELECT * FROM wants WHERE id = ? AND title = ? AND ratio > ?),
    %(SELECT * FROM t WHERE a = E'it\\'s' AND b = $tag$dollar quoted$tag$) =>
      %(SELECT * FROM t WHERE a = ? AND b = ?),
    %(UPDATE "wants" SET "state" = 'done', "updated_at" = '2026-09-30 10:00:00.123' WHERE "wants"."id" = 7) =>
      %(UPDATE "wants" SET "state" = ?, "updated_at" = ? WHERE "wants"."id" = ?),
    # IN lists collapse, VALUES tuples collapse
    %(SELECT * FROM wants WHERE id IN (1, 2, 3, 4)) => %(SELECT * FROM wants WHERE id IN (?)),
    %(SELECT * FROM wants WHERE id IN ($1, $2)) => %(SELECT * FROM wants WHERE id IN (?)),
    %(INSERT INTO "logs" ("a", "b") VALUES (1, 'x'), (2, 'y'), (3, 'z')) =>
      %(INSERT INTO "logs" ("a", "b") VALUES (?, ?)),
    # identifiers with digits survive; comments and whitespace go
    %(SELECT t1.col_2 FROM "table_2" t1  /* app:hook,controller:wants */ WHERE x = 1\n  -- trailing\n) =>
      %(SELECT t1.col_2 FROM "table_2" t1 WHERE x = ?),
    %(SELECT * FROM x WHERE created_at > NOW() - INTERVAL '7 days' AND n = -5) =>
      %(SELECT * FROM x WHERE created_at > NOW() - INTERVAL ? AND n = ?),
    %(SELECT * FROM x WHERE name = :name AND ts::text = 'a') =>
      %(SELECT * FROM x WHERE name = ? AND ts::text = ?)
  }.freeze

  def test_normalization_table
    TABLE.each do |raw, expected|
      assert_equal expected, Glass::Sql.normalize(raw), "normalizing #{raw.inspect}"
    end
  end

  def test_caps_at_4000_and_cuts_huge_input_before_scanning
    huge = "SELECT * FROM x WHERE id IN (" + (1..50_000).map(&:to_s).join(", ") + ")"
    out = Glass::Sql.normalize(huge)
    assert_operator out.size, :<=, Glass::Sql::MAX_LENGTH
    assert out.start_with?("SELECT * FROM x WHERE id IN (?")
  end

  def test_label_from_verb_and_table
    assert_equal "SELECT wants", Glass::Sql.label(%(SELECT "wants".* FROM "wants" WHERE ...))
    assert_equal "INSERT logs", Glass::Sql.label(%(INSERT INTO "logs" ("a") VALUES (?)))
    assert_equal "UPDATE wants", Glass::Sql.label(%(UPDATE "wants" SET a = ?))
    assert_equal "DELETE wants", Glass::Sql.label(%(DELETE FROM wants WHERE id = ?))
    assert_equal "BEGIN", Glass::Sql.label("BEGIN")
    assert_equal "SQL", Glass::Sql.label("")
  end

  def test_cache_is_bounded
    (Glass::Sql::CACHE_MAX + 10).times { |i| Glass::Sql.normalize("SELECT #{i}") }
    assert_operator Glass::Sql.instance_variable_get(:@cache).size, :<=, Glass::Sql::CACHE_MAX
  end
end
