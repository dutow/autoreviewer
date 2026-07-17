class AccessPolicy
  class << self
    attr_writer :config

    def allowed?(email)
      return false if email.blank?
      return false unless email.include?("@")

      auth = config.to_h["auth"] || {}
      domain = email.split("@").last.to_s
      Array(auth["allowed_emails"]).any? { |e| e.casecmp?(email) } ||
        Array(auth["allowed_domains"]).any? { |d| d.casecmp?(domain) }
    end

    def config
      return @config if @config

      path = Rails.root.join("config/access.yaml")
      File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
    end
  end
end
