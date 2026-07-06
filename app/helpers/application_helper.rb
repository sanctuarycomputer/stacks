module ApplicationHelper
  def prettify_datetime(datetime)
    datetime ? datetime.strftime("%B %d, %Y") : "—"
  end
end
