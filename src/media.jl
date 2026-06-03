abstract type TrackioMedia end

struct Image <: TrackioMedia
    path::String
    caption::Union{String,Nothing}
end

Image(path::AbstractString; caption = nothing) = Image(String(path), caption)

struct Video <: TrackioMedia
    path::String
    caption::Union{String,Nothing}
end

Video(path::AbstractString; caption = nothing, fps = nothing, format = nothing) =
    Video(String(path), caption)

struct Audio <: TrackioMedia
    path::String
    caption::Union{String,Nothing}
end

Audio(path::AbstractString; caption = nothing, sample_rate = nothing, format = nothing) =
    Audio(String(path), caption)

struct Table
    rows::Vector{Dict{String,Any}}
end

function Table(;
    columns = nothing,
    data = nothing,
    dataframe = nothing,
    rows = nothing,
    kwargs...,
)
    return Table(normalize_table_rows(columns, data, dataframe, rows))
end

struct Trace
    messages::Vector{Dict{String,Any}}
    metadata::Dict{String,Any}
end

function Trace(messages; metadata = nothing)
    message_rows = Dict{String,Any}[]
    for message in messages
        message isa AbstractDict || error("Trace messages must be dictionaries")
        push!(message_rows, Dict{String,Any}(string(k) => v for (k, v) in message))
    end
    trace_metadata =
        metadata === nothing ? Dict{String,Any}() :
        Dict{String,Any}(string(k) => v for (k, v) in metadata)
    return Trace(message_rows, trace_metadata)
end

function media_type(::Image)
    return "trackio.image"
end

function media_type(::Video)
    return "trackio.video"
end

function media_type(::Audio)
    return "trackio.audio"
end

function media_path(media::TrackioMedia)
    return media.path
end

function media_caption(media::TrackioMedia)
    return media.caption
end

function ensure_file_exists(path::AbstractString)
    isfile(path) || error("File not found: $path")
    return String(path)
end

function media_extension(path::AbstractString)
    extension = splitext(String(path))[2]
    isempty(extension) && return "unknown"
    return lowercase(extension[2:end])
end

function remote_media_dict(run::Run, media::TrackioMedia, step::Int)
    path = ensure_file_exists(media_path(media))
    staged_path = stage_upload(run.client, path)
    relative_file_path =
        joinpath(run.project, run.name, string(step), basename(staged_path))
    enqueue(
        run,
        QueueItem(
            :upload,
            Dict{String,Any}(
                "project" => run.project,
                "run" => run.name,
                "run_id" => run.id,
                "step" => step,
                "relative_path" => nothing,
                "uploaded_file" => Dict{String,Any}(
                    "path" => staged_path,
                    "orig_name" => basename(path),
                    "meta" => Dict{String,Any}("_type" => "gradio.FileData"),
                ),
            ),
        ),
    )
    return Dict{String,Any}(
        "_type" => media_type(media),
        "file_path" => relative_file_path,
        "caption" => media_caption(media),
    )
end

function normalize_table_rows(columns, data, dataframe, rows)
    source = dataframe !== nothing ? dataframe : (data !== nothing ? data : rows)
    source === nothing && return Dict{String,Any}[]

    if source isa AbstractVector
        isempty(source) && return Dict{String,Any}[]
        if first(source) isa AbstractDict
            return [Dict{String,Any}(string(k) => v for (k, v) in row) for row in source]
        end
        normalized = Dict{String,Any}[]
        for row in source
            row_values = collect(row)
            row_dict = Dict{String,Any}()
            if columns === nothing
                for (index, value) in enumerate(row_values)
                    row_dict[string(index - 1)] = value
                end
            else
                for (index, column) in enumerate(columns)
                    row_dict[string(column)] =
                        index <= length(row_values) ? row_values[index] : nothing
                end
            end
            push!(normalized, row_dict)
        end
        return normalized
    end

    try
        names = collect(propertynames(source))
        if !isempty(names)
            first_column = getproperty(source, first(names))
            return [
                Dict{String,Any}(
                    string(name) => getproperty(source, name)[i] for name in names
                ) for i in eachindex(first_column)
            ]
        end
    catch
    end

    if source isa AbstractDict
        names = collect(keys(source))
        isempty(names) && return Dict{String,Any}[]
        first_column = source[first(names)]
        return [
            Dict{String,Any}(string(name) => source[name][i] for name in names) for
            i in eachindex(first_column)
        ]
    end

    error(
        "Table data must be a vector of dictionaries, row arrays, or a simple table-like object",
    )
end

function media_aware_value(run::Run, value, step::Int)
    if value isa TrackioMedia
        return remote_media_dict(run, value, step)
    elseif value isa Table
        return Dict{String,Any}(
            "_type" => "trackio.table",
            "_value" => [
                Dict{String,Any}(
                    string(k) => media_aware_value(run, v, step) for (k, v) in row
                ) for row in value.rows
            ],
        )
    elseif value isa Trace
        return Dict{String,Any}(
            "_type" => "trackio.trace",
            "messages" => media_aware_value(run, value.messages, step),
            "metadata" => media_aware_value(run, value.metadata, step),
        )
    elseif value isa AbstractDict
        return Dict{String,Any}(
            string(k) => media_aware_value(run, v, step) for (k, v) in value
        )
    elseif value isa AbstractVector || value isa Tuple
        return Any[media_aware_value(run, item, step) for item in value]
    end
    return value
end
