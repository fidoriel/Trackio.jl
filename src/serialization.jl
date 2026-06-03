const RESERVED_METRIC_KEYS = Set(["project", "run", "timestamp", "step", "time", "metrics"])

function serialize_value(value)
    if value === nothing
        return nothing
    elseif value isa AbstractFloat
        if isnan(value)
            return "NaN"
        elseif isinf(value)
            return value > 0 ? "Infinity" : "-Infinity"
        end
        return value
    elseif value isa Integer || value isa Bool || value isa AbstractString
        return value
    elseif value isa Symbol
        return String(value)
    elseif value isa AbstractDict
        out = Dict{String,Any}()
        for (k, v) in value
            out[string(k)] = serialize_value(v)
        end
        return out
    elseif value isa Tuple || value isa AbstractVector || value isa Set
        return Any[serialize_value(v) for v in value]
    elseif value isa Date || value isa DateTime
        return string(value)
    else
        return string(value)
    end
end

function serialize_metrics(metrics::AbstractDict)
    out = Dict{String,Any}()
    for (key, value) in metrics
        metric_key = string(key)
        if metric_key in RESERVED_METRIC_KEYS || startswith(metric_key, "__")
            metric_key = "__" * metric_key
        end
        out[metric_key] = serialize_value(value)
    end
    return out
end

function serialize_config(config)
    serialized = serialize_value(config === nothing ? Dict{String,Any}() : config)
    serialized isa Dict || error("config must serialize to a dictionary")
    for key in keys(serialized)
        startswith(key, "_") && error(
            "Config key '$key' is reserved (keys starting with '_' are reserved for internal use)",
        )
    end
    return Dict{String,Any}(serialized)
end

function utc_timestamp()
    return Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "+00:00"
end
