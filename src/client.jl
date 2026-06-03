const HTTP_API_VERSION = 1
const WRITE_TOKEN_HEADER = "x-trackio-write-token"

normalize_src(src::AbstractString) = endswith(src, "/") ? String(src) : String(src) * "/"

function space_id_to_url(space_id::AbstractString)
    parts = split(String(space_id), "/"; limit = 2)
    length(parts) == 2 || error("Space id must be a full 'namespace/name' value")
    subdomain = lowercase(replace(parts[1] * "-" * parts[2], "_" => "-", "." => "-"))
    return "https://$subdomain.hf.space/"
end

function uri_escape(value::AbstractString)
    return replace(HTTP.escapeuri(String(value)), "%2F" => "/")
end

uri_unescape(value::AbstractString) = HTTP.unescapeuri(String(value))

function parse_query(query::AbstractString)
    isempty(query) && return Pair{String,String}[]
    pairs = Pair{String,String}[]
    for part in split(String(query), "&"; keepempty = true)
        isempty(part) && continue
        pieces = split(part, "="; limit = 2)
        key = uri_unescape(pieces[1])
        value = length(pieces) == 2 ? uri_unescape(pieces[2]) : ""
        push!(pairs, key => value)
    end
    return pairs
end

function encode_query(pairs::Vector{Pair{String,String}})
    isempty(pairs) && return ""
    return join((uri_escape(k) * "=" * uri_escape(v) for (k, v) in pairs), "&")
end

function build_url(uri::HTTP.URI, query::String)
    authority = isempty(uri.port) ? uri.host : uri.host * ":" * string(uri.port)
    url = uri.scheme * "://" * authority * uri.path
    isempty(query) || (url *= "?" * query)
    isempty(uri.fragment) || (url *= "#" * uri.fragment)
    return url
end

function parse_trackio_server_url(url::AbstractString)
    stripped = strip(String(url))
    uri = HTTP.URI(stripped)
    if uri.scheme ∉ ("http", "https")
        return stripped, nothing
    end

    write_token = nothing
    rest = Pair{String,String}[]
    for (key, value) in parse_query(uri.query)
        if key == "write_token"
            write_token = value
        else
            push!(rest, key => value)
        end
    end

    base = build_url(uri, encode_query(rest))
    return base, write_token
end

function resolve_src_url(src::AbstractString)
    value = String(src)
    if startswith(value, "http://") || startswith(value, "https://")
        base, _ = parse_trackio_server_url(value)
        return normalize_src(base)
    elseif occursin('/', value)
        return space_id_to_url(value)
    end
    error(
        "Could not resolve Trackio remote source '$value'. Pass a full Space id like 'user/space' or a URL.",
    )
end

function host_is_hf_space(url::AbstractString)
    return endswith(lowercase(HTTP.URI(String(url)).host), ".hf.space")
end

function TrackioClient(
    src::AbstractString;
    hf_token = nothing,
    write_token = nothing,
    timeout_seconds = 60.0,
)
    base_url = resolve_src_url(src)
    headers = Pair{String,String}[]
    if hf_token !== nothing
        push!(headers, "Authorization" => "Bearer $(hf_token)")
    end
    if write_token !== nothing
        push!(headers, WRITE_TOKEN_HEADER => String(write_token))
    end
    return TrackioClient(base_url, hf_token, write_token, headers, Float64(timeout_seconds))
end

function supports_http_api(client::TrackioClient)
    try
        response = HTTP.get(
            join_url(client.base_url, "version");
            headers = client.headers,
            request_timeout = 10,
            status_exception = false,
        )
        response.status == 200 || return false
        body = JSON3.read(String(response.body))
        return get(body, :api_version, nothing) == HTTP_API_VERSION
    catch
        return false
    end
end

function join_url(base::AbstractString, path::AbstractString)
    return normalize_src(base) * lstrip(String(path), '/')
end

function predict(client::TrackioClient, api_name::AbstractString; kwargs...)
    name = lstrip(String(api_name), '/')
    payload = Dict{String,Any}(
        "args" => Any[],
        "kwargs" =>
            Dict{String,Any}(string(k) => serialize_value(v) for (k, v) in kwargs),
    )
    response = HTTP.post(
        join_url(client.base_url, "api/$name");
        headers = [client.headers; "Content-Type" => "application/json"],
        body = JSON3.write(payload),
        request_timeout = round(Int, client.timeout_seconds),
        status_exception = false,
    )
    if response.status == 404
        error(
            "Trackio server '$(client.base_url)' does not support '/$name'. Redeploy or upgrade the server.",
        )
    end
    response.status == 200 ||
        error("Trackio API '/$name' failed with HTTP $(response.status)")
    body = JSON3.read(String(response.body))
    err = get(body, :error, nothing)
    err === nothing || error(String(err))
    return get(body, :data, nothing)
end

function stage_upload(client::TrackioClient, path::AbstractString)
    file = open(String(path), "r")
    try
        form = HTTP.Form(Dict("files" => HTTP.Multipart(basename(String(path)), file)))
        response = HTTP.post(
            join_url(client.base_url, "api/upload"),
            client.headers,
            form;
            request_timeout = round(Int, client.timeout_seconds),
            status_exception = false,
        )
        response.status == 200 ||
            error("Trackio upload failed with HTTP $(response.status)")
        body = JSON3.read(String(response.body))
        err = get(body, :error, nothing)
        err === nothing || error(String(err))
        paths = get(body, :paths, nothing)
        paths !== nothing && !isempty(paths) ||
            error("Trackio upload response did not include a staged path")
        return String(paths[1])
    finally
        close(file)
    end
end
