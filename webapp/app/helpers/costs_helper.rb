module CostsHelper
  def money(v) = v ? format("$%.2f", v) : "-"
end
