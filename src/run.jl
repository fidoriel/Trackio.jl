function default_run_name(space_id)
    prefix =
        space_id === nothing ? "trackio-run" : split(String(space_id), "/"; limit = 2)[1]
    return "$prefix-$(replace(string(uuid4())[1:8], "-" => ""))"
end

function maybe_first(values...)
    for value in values
        value === nothing || return value
    end
    return nothing
end

function init(
    project::AbstractString;
    name = nothing,
    group = nothing,
    space_id = nothing,
    server_url = nothing,
    config = nothing,
    resume = "never",
    webhook_url = nothing,
    webhook_min_level = nothing,
)
    CURRENT_RUN[] === nothing || finish(CURRENT_RUN[])

    resume = String(resume)
    resume in ("never", "allow", "must") ||
        error("resume must be one of \"never\", \"allow\", or \"must\"")

    resolved_space_id = maybe_first(space_id, get(ENV, "TRACKIO_SPACE_ID", nothing))
    resolved_server_url = maybe_first(server_url, get(ENV, "TRACKIO_SERVER_URL", nothing))
    if resolved_space_id !== nothing
        resolved_server_url = nothing
    end

    client = nothing
    server_base_url = nothing
    write_token = nothing
    hf_token = nothing
    source = nothing

    if resolved_space_id !== nothing
        source = String(resolved_space_id)
        hf_token = get(ENV, "HF_TOKEN", nothing)
        client = TrackioClient(source; hf_token = hf_token)
    elseif resolved_server_url !== nothing
        raw_server_url = String(resolved_server_url)
        startswith(raw_server_url, "http://") ||
            startswith(raw_server_url, "https://") ||
            error("server_url must start with http:// or https://")
        server_base_url, parsed_write_token = parse_trackio_server_url(raw_server_url)
        write_token =
            maybe_first(parsed_write_token, get(ENV, "TRACKIO_WRITE_TOKEN", nothing))
        write_token === nothing && error(
            "server_url logging requires a write token in ?write_token=... or TRACKIO_WRITE_TOKEN",
        )
        source = server_base_url
        client = TrackioClient(server_base_url; write_token = write_token)
    else
        error(
            "remote logging requires space_id, server_url, TRACKIO_SPACE_ID, or TRACKIO_SERVER_URL",
        )
    end

    supports_http_api(client) || error(
        "Trackio server '$(client.base_url)' does not support HTTP API version $HTTP_API_VERSION",
    )

    run_name = name === nothing ? default_run_name(resolved_space_id) : String(name)
    run_id = replace(string(uuid4()), "-" => "")
    initial_last_step = nothing

    if name !== nothing && resume != "never"
        existing = latest_matching_run(client, String(project), run_name)
        if existing !== nothing
            run_id = string(get(existing, :id, get(existing, "id", run_id)))
            initial_last_step = remote_last_step(client, String(project), run_name, run_id)
        elseif resume == "must"
            error("resume=\"must\" requires an existing run named '$run_name'")
        end
    elseif resume == "must"
        error("resume=\"must\" requires name")
    end

    run_config = serialize_config(config)
    run_config["_Username"] = get(ENV, "USER", nothing)
    run_config["_Created"] = utc_timestamp()
    run_config["_Group"] = group

    run = Run(
        source,
        String(project),
        run_name,
        run_id,
        group === nothing ? nothing : String(group),
        run_config,
        client,
        nothing,
        initial_last_step === nothing ? 0 : Int(initial_last_step) + 1,
        false,
        false,
        resolved_space_id === nothing ? nothing : String(resolved_space_id),
        server_base_url,
        write_token,
        maybe_first(webhook_url, get(ENV, "TRACKIO_WEBHOOK_URL", nothing)),
        normalize_alert_level(
            maybe_first(
                webhook_min_level,
                get(ENV, "TRACKIO_WEBHOOK_MIN_LEVEL", nothing),
                "warn",
            ),
        ),
    )
    run.queue = start_queue(run)
    CURRENT_RUN[] = run
    CURRENT_PROJECT[] = String(project)
    return run
end

function init(; project, kwargs...)
    return init(project; kwargs...)
end

function saved_file_relative_dir(file_path::AbstractString)
    cwd = realpath(pwd())
    absolute = realpath(String(file_path))
    relative = relpath(absolute, cwd)
    startswith(relative, "..") && return "."
    directory = dirname(relative)
    return isempty(directory) ? "." : directory
end

function has_glob_syntax(pattern::AbstractString)
    return occursin(r"[*?\[]", String(pattern))
end

function glob_regex(pattern::AbstractString)
    normalized = replace(abspath(String(pattern)), '\\' => '/')
    io = IOBuffer()
    print(io, '^')
    index = firstindex(normalized)
    while index <= lastindex(normalized)
        char = normalized[index]
        if char == '*'
            next_index = nextind(normalized, index)
            if next_index <= lastindex(normalized) && normalized[next_index] == '*'
                after_next = nextind(normalized, next_index)
                if after_next <= lastindex(normalized) && normalized[after_next] == '/'
                    print(io, "(?:.*/)?")
                    index = nextind(normalized, after_next)
                else
                    print(io, ".*")
                    index = after_next
                end
            else
                print(io, "[^/]*")
                index = next_index
            end
        elseif char == '?'
            print(io, "[^/]")
            index = nextind(normalized, index)
        else
            char in ('.', '+', '(', ')', '|', '^', '$', '{', '}', '[', ']', '\\') &&
                print(io, '\\')
            print(io, char)
            index = nextind(normalized, index)
        end
    end
    print(io, '$')
    return Regex(String(take!(io)))
end

function save_matches(pattern::AbstractString)
    if isfile(pattern)
        return [realpath(String(pattern))]
    end
    has_glob_syntax(pattern) || error("No files found matching pattern: $pattern")

    regex = glob_regex(pattern)
    root = split(String(pattern), r"[*?\[]"; limit = 2)[1]
    search_root = isempty(root) ? pwd() : dirname(abspath(root))
    isdir(search_root) || (search_root = pwd())
    matches = String[]
    for (dir, _, files) in walkdir(search_root)
        for file in files
            path = joinpath(dir, file)
            occursin(regex, replace(abspath(path), '\\' => '/')) &&
                push!(matches, realpath(path))
        end
    end
    sort!(unique(matches))
    isempty(matches) && error("No files found matching pattern: $pattern")
    return matches
end

function save(run::Run, pattern::AbstractString)
    run.client === nothing && error("remote client is not configured")
    ensure_run_registered!(run)
    for path in save_matches(pattern)
        staged_path = stage_upload(run.client, path)
        enqueue(
            run,
            QueueItem(
                :upload,
                Dict{String,Any}(
                    "project" => run.project,
                    "run" => nothing,
                    "run_id" => nothing,
                    "step" => nothing,
                    "relative_path" => saved_file_relative_dir(path),
                    "uploaded_file" => Dict{String,Any}(
                        "path" => staged_path,
                        "orig_name" => basename(path),
                        "meta" => Dict{String,Any}("_type" => "gradio.FileData"),
                    ),
                ),
            ),
        )
    end
    return nothing
end

function save(pattern::AbstractString; project = nothing)
    run = CURRENT_RUN[]
    if run === nothing
        error(
            "No project specified. Call trackio.init() before trackio.save() to configure uploads.",
        )
    end
    if project !== nothing && String(project) != run.project
        error("trackio.save(project=...) must match the current run project")
    end
    return save(run, pattern)
end

function latest_matching_run(client::TrackioClient, project::String, name::String)
    runs = predict(client, "/get_runs_for_project"; project = project)
    runs isa AbstractVector || return nothing
    matches = Any[]
    for run in runs
        run_name =
            run isa AbstractDict ? get(run, :name, get(run, "name", nothing)) : nothing
        run_name == name && push!(matches, run)
    end
    isempty(matches) && return nothing
    sort!(
        matches;
        by = r -> string(get(r, :created_at, get(r, "created_at", ""))),
        rev = true,
    )
    return first(matches)
end

function remote_last_step(
    client::TrackioClient,
    project::String,
    name::String,
    run_id::String,
)
    summary =
        predict(client, "/get_run_summary"; project = project, run = name, run_id = run_id)
    summary isa AbstractDict || return nothing
    last_step = get(summary, :last_step, get(summary, "last_step", nothing))
    return last_step isa Integer ? last_step : nothing
end

function log(run::Run, metrics::AbstractDict; step = nothing)
    actual_step = step === nothing ? run.next_step : Int(step)
    metrics = Dict{String,Any}(
        string(k) => media_aware_value(run, v, actual_step) for (k, v) in metrics
    )
    serialized_metrics = serialize_metrics(metrics)
    run.next_step = max(run.next_step, actual_step + 1)
    entry = Dict{String,Any}(
        "project" => run.project,
        "run" => run.name,
        "run_id" => run.id,
        "metrics" => serialized_metrics,
        "step" => actual_step,
        "log_id" => replace(string(uuid4()), "-" => ""),
    )
    if !run.config_logged
        entry["config"] = run.config
        run.config_logged = true
    end
    enqueue(run, QueueItem(:log, entry))
    return nothing
end

function ensure_run_registered!(run::Run)
    run.config_logged && return nothing
    entry = Dict{String,Any}(
        "project" => run.project,
        "run" => run.name,
        "run_id" => run.id,
        "metrics" => Dict{String,Any}(),
        "step" => nothing,
        "log_id" => replace(string(uuid4()), "-" => ""),
        "config" => run.config,
    )
    run.config_logged = true
    enqueue(run, QueueItem(:log, entry))
    return nothing
end

function log(metrics::AbstractDict; step = nothing)
    run = CURRENT_RUN[]
    run === nothing && error("trackio.init() must be called before trackio.log()")
    return log(run, metrics; step = step)
end

function log_system(run::Run, metrics::AbstractDict)
    entry = Dict{String,Any}(
        "project" => run.project,
        "run" => run.name,
        "run_id" => run.id,
        "metrics" => serialize_metrics(metrics),
        "timestamp" => utc_timestamp(),
        "log_id" => replace(string(uuid4()), "-" => ""),
    )
    enqueue(run, QueueItem(:system_log, entry))
    return nothing
end

function log_system(metrics::AbstractDict)
    run = CURRENT_RUN[]
    run === nothing && error("trackio.init() must be called before trackio.log_system()")
    return log_system(run, metrics)
end

function alert(
    run::Run,
    title::AbstractString;
    text = nothing,
    level = :warn,
    step = nothing,
    webhook_url = nothing,
)
    normalized_level = normalize_alert_level(level)
    actual_step = step === nothing ? max(run.next_step - 1, 0) : Int(step)
    println(format_alert_terminal(title, text, normalized_level))
    entry = Dict{String,Any}(
        "project" => run.project,
        "run" => run.name,
        "run_id" => run.id,
        "title" => String(title),
        "text" => text,
        "level" => normalized_level,
        "step" => actual_step,
        "timestamp" => utc_timestamp(),
        "alert_id" => replace(string(uuid4()), "-" => ""),
    )
    enqueue(run, QueueItem(:alert, entry))
    return nothing
end

function alert(
    title::AbstractString;
    text = nothing,
    level = :warn,
    step = nothing,
    webhook_url = nothing,
)
    run = CURRENT_RUN[]
    run === nothing && error("trackio.init() must be called before trackio.alert()")
    return alert(
        run,
        title;
        text = text,
        level = level,
        step = step,
        webhook_url = webhook_url,
    )
end

function finish(run::Run)
    run.closed && return nothing
    run.closed = true
    finish_queue!(run)
    CURRENT_RUN[] === run && (CURRENT_RUN[] = nothing)
    return nothing
end

function finish()
    run = CURRENT_RUN[]
    run === nothing && return nothing
    return finish(run)
end
