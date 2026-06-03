const ALERT_LEVELS = Set(["info", "warn", "error"])

function normalize_alert_level(level)
    normalized = lowercase(string(level))
    startswith(normalized, ":") && (normalized = normalized[2:end])
    normalized in ALERT_LEVELS ||
        error("alert level must be one of :info, :warn, or :error")
    return normalized
end

function format_alert_terminal(title::AbstractString, text, level::String)
    message = "Trackio alert [$level]: $title"
    text === nothing || (message *= " - $text")
    return message
end
