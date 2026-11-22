class CostStats
  Group = Struct.new(:count, :total) do
    def self.zero = new(0, 0.0)
    def avg = count > 0 ? total / count : nil
    def +(other) = Group.new(count + other.count, total + other.total)
  end

  Row = Struct.new(:day, :all, :first, :rereview) do
    def +(other) = Row.new(nil, all + other.all, first + other.first, rereview + other.rereview)
  end

  DAY = "date(review_versions.reviewed_at)"
  REREVIEW = <<~SQL.squish
    EXISTS (SELECT 1 FROM review_versions prev
            WHERE prev.project = review_versions.project
              AND prev.topic = review_versions.topic
              AND prev.version < review_versions.version)
  SQL

  def initialize(scope)
    @scope = scope
  end

  # newest first
  def days
    @days ||= grouped.group_by(&:first).map { |day, rows|
      row = Row.new(Date.iso8601(day), Group.zero, Group.zero, Group.zero)
      rows.each do |_, rereview, n, sum|
        g = Group.new(n, sum.to_f)
        row.all += g
        rereview == 1 ? row.rereview += g : row.first += g
      end
      row
    }.sort_by(&:day).reverse
  end

  def totals
    @totals ||= days.reduce(Row.new(nil, Group.zero, Group.zero, Group.zero), :+)
  end

  def skipped
    @scope.count - totals.all.count
  end

  private

  def grouped
    @scope.where.not(cost_usd: nil).where.not(reviewed_at: nil)
          .group(Arel.sql(DAY), Arel.sql(REREVIEW))
          .pluck(Arel.sql(DAY), Arel.sql(REREVIEW), Arel.sql("COUNT(*)"), Arel.sql("SUM(review_versions.cost_usd)"))
  end
end
