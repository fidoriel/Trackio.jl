mutable struct TrackioClient
    base_url::String
    hf_token::Union{String,Nothing}
    write_token::Union{String,Nothing}
    headers::Vector{Pair{String,String}}
    timeout_seconds::Float64
end

struct QueueItem
    kind::Symbol
    payload::Dict{String,Any}
end

mutable struct LogQueue
    channel::Channel{QueueItem}
    task::Task
    stop_requested::Base.RefValue{Bool}
    pending::Vector{QueueItem}
    warned_failures::Set{String}
end

mutable struct Run
    url::Union{String,Nothing}
    project::String
    name::String
    id::String
    group::Union{String,Nothing}
    config::Dict{String,Any}
    client::Union{TrackioClient,Nothing}
    queue::Union{LogQueue,Nothing}
    next_step::Int
    config_logged::Bool
    closed::Bool
    space_id::Union{String,Nothing}
    server_base_url::Union{String,Nothing}
    write_token::Union{String,Nothing}
    webhook_url::Union{String,Nothing}
    webhook_min_level::String
end

const CURRENT_RUN = Ref{Union{Run,Nothing}}(nothing)
const CURRENT_PROJECT = Ref{Union{String,Nothing}}(nothing)
