module ApplicationHelper
  def player_time(seconds)
    total_seconds = seconds.to_f
    return "0:00" unless total_seconds.finite? && total_seconds.positive?

    total_seconds = total_seconds.floor
    hours = total_seconds / 3600
    minutes = (total_seconds % 3600) / 60
    seconds = total_seconds % 60

    if hours.positive?
      "#{hours}:#{minutes.to_s.rjust(2, '0')}:#{seconds.to_s.rjust(2, '0')}"
    else
      "#{minutes}:#{seconds.to_s.rjust(2, '0')}"
    end
  end
end
