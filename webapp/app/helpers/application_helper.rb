module ApplicationHelper
  def short_date(str)
    Date.parse(str.to_s).strftime("%Y-%m-%d")
  rescue Date::Error
    nil
  end

  def file_icon(kind)
    { "markdown" => "📄", "patch" => "🩹", "text" => "📃" }.fetch(kind, "📦")
  end
end
