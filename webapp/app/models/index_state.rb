class IndexState < ApplicationRecord
  def self.get(key) = find_by(key: key)&.value

  def self.set(key, value)
    find_or_initialize_by(key: key).update!(value: value)
  end
end
